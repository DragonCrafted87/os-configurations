#!/usr/bin/env bash
# Install pinned k3s, join the registration address, and reconcile
# labels, taints, slices, and the workstation kubeconfig.
# roost-drake is the only node that bootstraps. A joiner needs
# /etc/rancher/k3s/cluster-token. The token is never printed.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

K3S_SERVERS=()
K3S_BOOTSTRAP=""
K3S_REGISTRATION=""
K3S_VIP=""

syspath() {
    printf '%s%s\n' "${K3S_SYSROOT:-}" "$1"
}

as_root() {
    if [[ -n "${K3S_SYSROOT:-}" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

write_root_file() {
    local dest="$1" mode="$2" tmp
    tmp="$(mktemp)"
    cat >"$tmp"
    as_root mkdir -p "$(dirname "$dest")"
    as_root install -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
}

load_cluster() {
    local file="${SETUP_DIR}/files/k3s/cluster.conf"
    local line key value
    [[ -f "$file" ]] || die "missing ${file}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" != *=* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            bootstrap) K3S_BOOTSTRAP="$value" ;;
            registration) K3S_REGISTRATION="$value" ;;
            vip) K3S_VIP="$value" ;;
            server) K3S_SERVERS+=("$value") ;;
            *) die "unknown cluster.conf key ${key}" ;;
        esac
    done <"$file"
    [[ -n "$K3S_BOOTSTRAP" && -n "$K3S_REGISTRATION" && -n "$K3S_VIP" ]] \
        || die "cluster.conf is incomplete"
    [[ "$K3S_VERSION" == v*+k3s* ]] || die "set K3S_VERSION in setup/versions.conf"
}

node_is_server() {
    local name="$1" item
    for item in "${K3S_SERVERS[@]}"; do
        [[ "$item" == "$name" ]] && return 0
    done
    return 1
}

saved_machine_role() {
    local file="${CONFIG_TARGET_DIR}/dot-files/role"
    [[ -f "$file" ]] || die "missing ${file}"
    tr -d '[:space:]' <"$file"
}

node_name() {
    if [[ -n "${K3S_NODE_NAME:-}" ]]; then
        printf '%s\n' "$K3S_NODE_NAME"
        return 0
    fi
    hostname -s
}

copy_remote() {
    local remote_path="$1" dest="$2" tmp
    tmp="$(mktemp)"
    chmod 600 "$tmp"
    if ! ssh -o BatchMode=yes -o ForwardX11=no \
        "dragon@${K3S_BOOTSTRAP}.${DOTFILES_DOMAIN}" \
        "sudo cat ${remote_path}" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        return 1
    fi
    write_root_file "$dest" 600 <"$tmp"
    rm -f "$tmp"
}

ensure_join_token() {
    local dest
    dest="$(syspath /etc/rancher/k3s/cluster-token)"
    [[ -s "$dest" ]] && return 0
    copy_remote /var/lib/rancher/k3s/server/node-token "$dest" || true
    [[ -s "$dest" ]] || die "missing /etc/rancher/k3s/cluster-token"
}

write_config() {
    local dest kind="$1" node="$2" role="$3"
    dest="$(syspath /etc/rancher/k3s/config.yaml)"
    {
        printf 'node-name: %s\n' "$node"
        printf 'resolv-conf: /run/systemd/resolve/resolv.conf\n'
        if [[ "$kind" == "server" ]]; then
            printf 'write-kubeconfig-mode: "644"\n'
            printf 'disable:\n- traefik\n- servicelb\n'
            printf 'tls-san:\n- %s.%s\n- %s\n- %s\n' \
                "$node" "$DOTFILES_DOMAIN" "$K3S_REGISTRATION" "$K3S_VIP"
            if [[ "$node" == "$K3S_BOOTSTRAP" ]]; then
                printf 'cluster-init: true\n'
            else
                printf 'server: https://%s:6443\n' "$K3S_REGISTRATION"
                printf 'token-file: /etc/rancher/k3s/cluster-token\n'
            fi
        else
            printf 'server: https://%s:6443\n' "$K3S_REGISTRATION"
            printf 'token-file: /etc/rancher/k3s/cluster-token\n'
        fi
        # Labels and taints are only in this file. The installer also
        # accepts them as flags, and k3s rejects the taint when both
        # sources carry it.
        printf 'node-label:\n- homelab.stealthdragonland.net/role=%s\n' "$role"
        while IFS= read -r sub; do
            [[ -n "$sub" ]] || continue
            printf -- '- homelab.stealthdragonland.net/subrole-%s=true\n' "$sub"
        done < <(read_saved_subroles)
        case "$role" in
            workstation)
                printf 'node-taint:\n- purpose=workstation:NoSchedule\n'
                ;;
            htpc)
                printf 'node-taint:\n- purpose=htpc:NoSchedule\n'
                ;;
        esac
    } | write_root_file "$dest" 644
}

install_needed() {
    local etcd active_server active_agent
    etcd="$(syspath /var/lib/rancher/k3s/server/db/etcd)"
    [[ -d "$etcd" ]] && return 1
    active_server=1
    active_agent=1
    systemctl is-active --quiet k3s || active_server=0
    systemctl is-active --quiet k3s-agent || active_agent=0
    [[ "$active_server" -eq 1 || "$active_agent" -eq 1 ]] && return 1
    return 0
}

run_installer() {
    local token_file="$1"
    shift
    if [[ -n "$token_file" ]]; then
        export K3S_TOKEN_FILE="$token_file"
        export INSTALL_K3S_VERSION="$K3S_VERSION"
        curl -sfL https://get.k3s.io | sh -s - "$@"
        unset K3S_TOKEN_FILE
    else
        export INSTALL_K3S_VERSION="$K3S_VERSION"
        curl -sfL https://get.k3s.io | sh -s - "$@"
    fi
}

ensure_symlinks() {
    local bin name
    bin="$(syspath /usr/local/bin)"
    [[ -e "${bin}/k3s" ]] || return 0
    for name in kubectl crictl ctr; do
        as_root ln -sfn k3s "${bin}/${name}"
    done
}

remove_distro_kubectl() {
    if rpm -q kubernetes-client >/dev/null 2>&1; then
        log "remove kubernetes-client"
        as_root dnf remove -y kubernetes-client
    fi
}

slice_weights() {
    local role="$1"
    local cpu="100" io="100" memory=""
    if has_subrole nfs-server; then
        cpu="20"
        io="100"
    elif [[ "$role" == "workstation" || "$role" == "htpc" ]]; then
        cpu="100"
        io="50"
        local kb="${K3S_MEMTOTAL_KB:-}"
        if [[ -z "$kb" ]]; then
            kb="$(awk '/MemTotal/ {print $2; exit}' /proc/meminfo)"
        fi
        memory="MemoryHigh=$((kb / 2))K"
    fi
    {
        printf '[Slice]\nCPUWeight=%s\nIOWeight=%s\n' "$cpu" "$io"
        if [[ -n "$memory" ]]; then
            printf '%s\n' "$memory"
        fi
    } | write_root_file "$(syspath /etc/systemd/system/k3s.slice)" 644
    printf '[Slice]\nCPUWeight=10\nIOWeight=10\nMemoryHigh=4G\n' \
        | write_root_file "$(syspath /etc/systemd/system/boinc.slice)" 644
    printf '[Slice]\nCPUWeight=1000\nIOWeight=1000\n' \
        | write_root_file "$(syspath /etc/systemd/system/user.slice.d/priority.conf)" 644
    printf '[Service]\nSlice=k3s.slice\n' \
        | write_root_file "$(syspath /etc/systemd/system/k3s.service.d/slice.conf)" 644
    printf '[Service]\nSlice=k3s.slice\n' \
        | write_root_file "$(syspath /etc/systemd/system/k3s-agent.service.d/slice.conf)" 644
    as_root systemctl daemon-reload || true
}

install_priority_helper() {
    local src="${SETUP_DIR}/files/k3s/workload-priority.sh"
    local dest
    dest="$(syspath /usr/local/sbin/workload-priority)"
    as_root mkdir -p "$(dirname "$dest")"
    as_root install -m 0755 "$src" "$dest"
}

install_htpc_cordon() {
    local src="${SETUP_DIR}/files/k3s"
    local bin unit
    bin="$(syspath /usr/local/sbin/htpc-cordon)"
    as_root mkdir -p "$(dirname "$bin")" "$(syspath /etc/systemd/system)"
    as_root install -m 0755 "${src}/htpc-cordon.sh" "$bin"
    as_root install -m 0644 "${src}/htpc-cordon.service" \
        "$(syspath /etc/systemd/system/htpc-cordon.service)"
    as_root install -m 0644 "${src}/htpc-cordon.timer" \
        "$(syspath /etc/systemd/system/htpc-cordon.timer)"
    unit="htpc-cordon.timer"
    if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        log "enable ${unit}"
        as_root systemctl enable "$unit"
    fi
}

refresh_kubeconfig() {
    local role="$1" remote tmp dest
    remote="/etc/rancher/k3s/k3s.yaml"
    tmp="$(mktemp)"
    chmod 600 "$tmp"
    if ! ssh -o BatchMode=yes -o ForwardX11=no \
        "dragon@${K3S_BOOTSTRAP}.${DOTFILES_DOMAIN}" \
        "sudo cat ${remote}" >"$tmp"; then
        rm -f "$tmp"
        if [[ "$role" == "workstation" && -s "${DOTFILES_HOME}/.kube/config" ]]; then
            warn "left the existing kubeconfig; ${K3S_BOOTSTRAP} did not answer"
            return 0
        fi
        if [[ "$role" == "htpc" && -s "$(syspath /etc/rancher/k3s/htpc.kubeconfig)" ]]; then
            warn "left the existing htpc kubeconfig; ${K3S_BOOTSTRAP} did not answer"
            return 0
        fi
        die "missing kubeconfig from ${K3S_BOOTSTRAP}"
    fi
    if [[ "$role" == "workstation" ]]; then
        dest="${DOTFILES_HOME}/.kube/config"
    else
        dest="$(syspath /etc/rancher/k3s/htpc.kubeconfig)"
    fi
    python3 "${SETUP_DIR}/files/k3s/merge-kubeconfig.py" \
        --server "$tmp" \
        --dest "$dest" \
        --server-url "https://${K3S_REGISTRATION}:6443"
    rm -f "$tmp"
}

vip_priority() {
    case "$1" in
        roost-drake) printf '100\n' ;;
        hoard-drake) printf '90\n' ;;
        brood-drake) printf '80\n' ;;
        *) printf '70\n' ;;
    esac
}

install_keepalived() {
    local node="$1" iface pass dest priority vip_pass
    iface="${K3S_VIP_IFACE:-}"
    if [[ -z "$iface" ]]; then
        iface="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    fi
    [[ -n "$iface" ]] || die "keepalived needs a default-route interface"
    if [[ -z "${K3S_SYSROOT:-}" ]]; then
        ensure_packages keepalived
    else
        log "install packages: keepalived"
    fi
    pass="$(syspath /etc/keepalived/k3s-vip.pass)"
    if [[ ! -s "$pass" ]]; then
        if [[ "$node" == "$K3S_BOOTSTRAP" ]]; then
            vip_pass="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
            printf '%s\n' "$vip_pass" | write_root_file "$pass" 600
        else
            copy_remote /etc/keepalived/k3s-vip.pass "$pass" \
                || die "missing /etc/keepalived/k3s-vip.pass"
        fi
    fi
    priority="$(vip_priority "$node")"
    vip_pass="$(tr -d '[:space:]' <"$pass")"
    dest="$(syspath /etc/keepalived/keepalived.conf)"
    {
        printf 'vrrp_instance k3s_api {\n'
        printf '    state BACKUP\n'
        printf '    interface %s\n' "$iface"
        printf '    virtual_router_id 52\n'
        printf '    priority %s\n' "$priority"
        printf '    advert_int 1\n'
        printf '    authentication {\n'
        printf '        auth_type PASS\n'
        printf '        auth_pass %s\n' "$vip_pass"
        printf '    }\n'
        printf '    virtual_ipaddress {\n'
        printf '        %s/16\n' "$K3S_VIP"
        printf '    }\n'
        printf '}\n'
    } | write_root_file "$dest" 600
    if ! systemctl is-enabled --quiet keepalived 2>/dev/null; then
        log "enable keepalived"
        as_root systemctl enable keepalived
    fi
}

load_cluster
node="$(node_name)"
role="$(saved_machine_role)"
kind="agent"
token_file=""
if node_is_server "$node"; then
    kind="server"
fi

slice_weights "$role"
install_priority_helper
if [[ "$role" == "htpc" ]]; then
    install_htpc_cordon
fi

if [[ "$node" != "$K3S_BOOTSTRAP" ]]; then
    ensure_join_token
    token_file="/etc/rancher/k3s/cluster-token"
fi

write_config "$kind" "$node" "$role"

if install_needed; then
    log "install k3s ${K3S_VERSION} as ${kind}"
    args=(
        "$kind"
        --node-name "$node"
        --resolv-conf /run/systemd/resolve/resolv.conf
    )
    if [[ "$kind" == "server" ]]; then
        args+=(
            --disable traefik
            --disable servicelb
            --tls-san "${node}.${DOTFILES_DOMAIN}"
            --tls-san "$K3S_REGISTRATION"
            --tls-san "$K3S_VIP"
            --write-kubeconfig-mode 644
        )
        if [[ "$node" == "$K3S_BOOTSTRAP" ]]; then
            args+=(--cluster-init)
        else
            args+=(--server "https://${K3S_REGISTRATION}:6443")
        fi
    else
        args+=(--server "https://${K3S_REGISTRATION}:6443")
    fi
    run_installer "$token_file" "${args[@]}"
fi

ensure_symlinks
remove_distro_kubectl

if [[ "$role" == "workstation" || "$role" == "htpc" ]]; then
    refresh_kubeconfig "$role"
fi
if [[ "$kind" == "server" ]]; then
    install_keepalived "$node"
fi
