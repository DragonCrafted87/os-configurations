# shellcheck shell=bash
# Sourced by setup/lib/lib.sh. Not an entry point.

enable_service() {
    local unit="$1"
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        return 0
    fi
    log "enable ${unit}"
    run sudo systemctl enable "$unit"
}

enable_user_service() {
    local unit="$1"
    if systemctl --user is-enabled --quiet "$unit" 2>/dev/null; then
        return 0
    fi
    if ! systemctl --user list-unit-files "$unit" >/dev/null 2>&1; then
        warn "user unit ${unit} is not installed yet"
        return 0
    fi
    log "enable --user ${unit}"
    run systemctl --user enable "$unit"
}

disable_user_service() {
    local unit="$1"
    if ! systemctl --user list-unit-files "$unit" >/dev/null 2>&1; then
        return 0
    fi
    if systemctl --user is-enabled --quiet "$unit" 2>/dev/null; then
        log "disable --user ${unit}"
        run systemctl --user disable "$unit"
    fi
}

# Copy a user unit from setup/files into ~/.config/systemd/user.
install_user_unit() {
    local src="$1"
    local dest
    [[ -f "$src" ]] || die "missing ${src}"
    dest="${DOTFILES_HOME}/.config/systemd/user/$(basename "$src")"
    ensure_dir "$(dirname "$dest")"
    if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
        log "user unit ${dest}"
        run install -m 0644 "$src" "$dest"
    fi
}

# Copy a user drop-in from setup/files into ~/.config/systemd/user/<unit>.d/.
install_user_dropin() {
    local unit="$1"
    local src="$2"
    local dest
    [[ -f "$src" ]] || die "missing ${src}"
    dest="${DOTFILES_HOME}/.config/systemd/user/${unit}.d/$(basename "$src")"
    ensure_dir "$(dirname "$dest")"
    if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
        log "user drop-in ${dest}"
        run install -m 0644 "$src" "$dest"
    fi
}

disable_service() {
    local unit="$1"
    if ! systemctl list-unit-files "$unit" >/dev/null 2>&1; then
        return 0
    fi
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        log "disable ${unit}"
        run sudo systemctl disable "$unit"
    fi
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        log "stop ${unit}"
        run sudo systemctl stop "$unit"
    fi
}

ensure_timezone() {
    local tz="$1"
    local current
    current="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [[ "$current" == "$tz" ]]; then
        return 0
    fi
    log "timezone ${tz}"
    run sudo timedatectl set-timezone "$tz"
}

ntp_server() {
    local server="${DOTFILES_NTP_SERVER:-192.168.0.1}"
    [[ "$server" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad DOTFILES_NTP_SERVER ${server}"
    printf '%s\n' "$server"
}

timesyncd_ntp_body() {
    printf '[Time]\nNTP=%s\n' "$(ntp_server)"
}

# Replace every server and pool line with one server. Other lines stay.
rewrite_chrony_sources() {
    local server="$1" line replaced=0
    local -a out=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^(server|pool)[[:space:]] ]]; then
            if [[ "$replaced" -eq 0 ]]; then
                out+=("server ${server} iburst")
                replaced=1
            fi
            continue
        fi
        out+=("$line")
    done
    if [[ "$replaced" -eq 0 ]]; then
        out=("server ${server} iburst" "${out[@]}")
    fi
    local item
    for item in "${out[@]}"; do
        printf '%s\n' "$item"
    done
}

install_text_file() {
    local dest="$1"
    local contents="$2"
    local staged
    staged="$(mktemp)"
    printf '%s\n' "$contents" >"$staged"
    if [[ -f "$dest" ]] && cmp -s "$dest" "$staged"; then
        rm -f "$staged"
        return 1
    fi
    log "ntp ${dest}"
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        rm -f "$staged"
        return 0
    fi
    if [[ -w "$(dirname "$dest")" ]]; then
        mv "$staged" "$dest"
        return 0
    fi
    sudo mkdir -p "$(dirname "$dest")"
    sudo cp "$staged" "$dest"
    sudo chmod 0644 "$dest"
    rm -f "$staged"
}

timesyncd_unit_present() {
    [[ -f /usr/lib/systemd/system/systemd-timesyncd.service ]] && return 0
    [[ -f /lib/systemd/system/systemd-timesyncd.service ]] && return 0
    return 1
}

ensure_timesyncd_ntp() {
    local dest="${TIMESYNCD_DROPIN:-/etc/systemd/timesyncd.conf.d/mist-dragon.conf}"
    local real="/etc/systemd/timesyncd.conf.d/mist-dragon.conf"
    if [[ "$dest" == "$real" ]] && ! timesyncd_unit_present; then
        return 0
    fi
    install_text_file "$dest" "$(timesyncd_ntp_body)" || return 0
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" || "$dest" != "$real" ]]; then
        return 0
    fi
    if systemctl is-active --quiet systemd-timesyncd.service; then
        log "restart systemd-timesyncd"
        sudo systemctl try-restart systemd-timesyncd.service
    fi
}

ensure_chrony_ntp() {
    local conf="${CHRONY_CONF:-/etc/chrony.conf}"
    local body
    [[ -f "$conf" ]] || return 0
    body="$(rewrite_chrony_sources "$(ntp_server)" <"$conf")"
    install_text_file "$conf" "$body" || return 0
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" || "$conf" != /etc/chrony.conf ]]; then
        return 0
    fi
    if systemctl is-active --quiet chronyd.service; then
        log "restart chronyd"
        sudo systemctl try-restart chronyd.service
    fi
}

# The installer records a short name. The static hostname is the flight
# FQDN. 127.0.1.1 keeps only that short name, so the FQDN still resolves
# through DNS instead of loopback.
DOTFILES_DOMAIN="${DOTFILES_DOMAIN:-stealthdragonland.net}"

read_static_hostname() {
    local name=""
    if command -v hostnamectl >/dev/null 2>&1; then
        name="$(hostnamectl --static 2>/dev/null || true)"
    fi
    if [[ -z "$name" ]]; then
        name="$(hostname 2>/dev/null || true)"
    fi
    printf '%s\n' "$name"
}

# Print NAME.DOTFILES_DOMAIN. NAME may be a short name, a .lan name, or
# the flight FQDN. An installer default is an error.
flight_fqdn() {
    local raw="${1:-}"
    local domain short fqdn
    domain="${DOTFILES_DOMAIN:-stealthdragonland.net}"
    domain="${domain,,}"
    domain="${domain%.}"
    raw="${raw,,}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    raw="${raw%.}"
    [[ -n "$raw" ]] || die "hostname is empty; pass --hostname NAME"
    [[ "$raw" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "bad hostname ${raw}"
    [[ "$domain" == *.* ]] || die "bad domain ${domain}"
    [[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "bad domain ${domain}"
    short="${raw%%.*}"
    case "$short" in
        localhost | openmandriva | omv | omv-live | livecd | live)
            die "hostname ${raw} is an installer default; pass --hostname NAME"
            ;;
    esac
    [[ "$short" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "bad hostname ${raw}"
    fqdn="${short}.${domain}"
    if ((${#fqdn} > 64)); then
        die "hostname ${fqdn} is longer than 64 characters"
    fi
    printf '%s\n' "$fqdn"
}

hosts_with_short_name() {
    local short="$1"
    local file="$2"
    local line found=0
    local -a tokens=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^127\.0\.1\.1[[:space:]] ]]; then
            if [[ "$found" -eq 0 ]]; then
                read -r -a tokens <<<"$line"
                if [[ "${#tokens[@]}" -eq 2 && "${tokens[1]}" == "$short" ]]; then
                    printf '%s\n' "$line"
                else
                    printf '127.0.1.1  %s\n' "$short"
                fi
                found=1
            fi
            continue
        fi
        printf '%s\n' "$line"
    done <"$file"
    if [[ "$found" -eq 0 ]]; then
        printf '127.0.1.1  %s\n' "$short"
    fi
}

ensure_hosts_short_name() {
    local short="$1"
    local file="${HOSTS_FILE:-/etc/hosts}"
    local tmp current staged
    [[ -f "$file" ]] || die "missing ${file}"
    # mktemp is 0600, and cp keeps that mode. A root-owned 0600 hosts
    # file cannot be read on the next run, so the installed mode is 0644.
    current="$(mktemp)"
    tmp="$(mktemp)"
    if [[ -r "$file" ]]; then
        cat "$file" >"$current"
    else
        sudo cat "$file" >"$current"
    fi
    hosts_with_short_name "$short" "$current" >"$tmp"
    if cmp -s "$current" "$tmp"; then
        rm -f "$tmp" "$current"
        if [[ -r "$file" ]]; then
            return 0
        fi
        log "hosts ${file} mode 0644"
        if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
            return 0
        fi
        sudo chmod 0644 "$file"
        return 0
    fi
    rm -f "$current"
    log "hosts ${file} short name ${short}"
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        rm -f "$tmp"
        return 0
    fi
    staged="$(dirname "$file")/.$(basename "$file").dotfiles-tmp"
    if [[ -w "$file" && -w "$(dirname "$file")" ]]; then
        rm -f "$staged"
        cp "$tmp" "$staged"
        chmod 0644 "$staged"
        mv "$staged" "$file"
    else
        sudo rm -f "$staged"
        sudo cp "$tmp" "$staged"
        sudo chmod 0644 "$staged"
        sudo mv "$staged" "$file"
    fi
    rm -f "$tmp"
}

ensure_hostname() {
    local requested="${1:-}"
    local source static short fqdn
    static="$(read_static_hostname)"
    if [[ -n "$requested" ]]; then
        source="$requested"
    else
        source="$static"
    fi
    fqdn="$(flight_fqdn "$source")"
    short="${fqdn%%.*}"
    if [[ "$static" != "$fqdn" ]]; then
        log "hostname ${fqdn}"
        run sudo hostnamectl set-hostname "$fqdn"
    fi
    ensure_hosts_short_name "$short"
}

ensure_systemd_dropin() {
    local unit="$1"
    local name="$2"
    local contents="$3"
    local dest="/etc/systemd/system/${unit}.d/${name}.conf"
    local current=""

    if [[ -f "$dest" ]]; then
        current="$(cat "$dest")"
        if [[ "$current" == "$contents" ]]; then
            return 0
        fi
    fi
    log "systemd drop-in ${dest}"
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    sudo mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$contents" | sudo tee "$dest" >/dev/null
    run sudo systemctl daemon-reload
}
