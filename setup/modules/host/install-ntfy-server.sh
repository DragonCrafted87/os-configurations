#!/usr/bin/env bash
# ntfy on Home Assistant OS. The haos role sets HAOS_TARGET.
# Passwords are generated once on that host. This machine gets a
# subscriber config when it does not already have one.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

target="${HAOS_TARGET:-}"
port="${HAOS_SSH_PORT:-22222}"
remote="${SETUP_FILES_DIR}/ntfy/haos-serve.sh"
client="${DOTFILES_HOME}/.config/ntfy/client.yml"
host_name="ward-drake.stealthdragonland.net"

[[ -n "$target" ]] || die "HAOS_TARGET is required (user@host)"
[[ -f "$remote" ]] || die "missing ${remote}"

ssh_ha() {
    # shellcheck disable=SC2086
    ssh -p "$port" \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        -o ForwardX11=no \
        -o ForwardAgent=no \
        "$target" "$@"
}

if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
    log "dry-run: install ntfy server on ${target}"
    exit 0
fi

ssh_ha 'mkdir -p /mnt/data/ntfy/data/attachments && chmod 700 /mnt/data/ntfy'

if ! ssh_ha 'test -f /mnt/data/ntfy/credentials'; then
    ha_pass="$(openssl rand -hex 24)"
    ws_pass="$(openssl rand -hex 24)"
    umask 077
    tmp="$(mktemp)"
    printf 'ha_password=%s\nworkstation_password=%s\n' "$ha_pass" "$ws_pass" >"$tmp"
    ssh_ha 'umask 077; cat > /mnt/data/ntfy/credentials && chmod 600 /mnt/data/ntfy/credentials' <"$tmp"
    rm -f "$tmp"
    unset ha_pass ws_pass
    log "generated ntfy credentials on ${target}"
fi

ssh_ha 'cat > /mnt/data/ntfy/haos-serve.sh && chmod 700 /mnt/data/ntfy/haos-serve.sh && /mnt/data/ntfy/haos-serve.sh' <"$remote"

# Publish has to answer before Home Assistant is pointed at it.
ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 3 "http://${host_name}:2586/v1/health" >/dev/null; then
        ok=1
        break
    fi
    sleep 1
done
[[ "$ok" -eq 1 ]] || die "ntfy on ${host_name}:2586 did not answer /v1/health"

if [[ -f "$client" ]]; then
    log "subscriber config already at ${client}"
    exit 0
fi

ws_pass="$(ssh_ha "awk -F= '/^workstation_password=/{print \$2}' /mnt/data/ntfy/credentials")"
[[ -n "$ws_pass" ]] || die "workstation password missing on ${target}"
ensure_dir "$(dirname "$client")"
umask 077
cat >"$client" <<EOF
default-host: http://${host_name}:2586
default-user: workstation
default-password: ${ws_pass}
EOF
chmod 600 "$client"
unset ws_pass
log "wrote ${client}"
