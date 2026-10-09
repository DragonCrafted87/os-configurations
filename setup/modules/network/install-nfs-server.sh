#!/usr/bin/env bash
# NFS server subrole. Exports /srv/data to 192.168.0.0/20 with the
# options the cluster already mounts from castellan. The managed
# exports file is rewritten when it drifts. This module does not
# partition disks or copy the castellan tree.
#
#   ~/machine-setup/setup/role.sh --enable-subrole nfs-server

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

allow_nfs_firewall() {
    local available service
    local -a services=(nfs mountd rpc-bind)
    local needed=0

    if ! command -v firewall-cmd >/dev/null; then
        return 0
    fi
    if ! systemctl is-active --quiet firewalld; then
        return 0
    fi

    available="$(sudo firewall-cmd --get-services 2>/dev/null || true)"
    for service in "${services[@]}"; do
        if ! grep -Eq "(^|[[:space:]])${service}([[:space:]]|$)" <<<"$available"; then
            continue
        fi
        if sudo firewall-cmd --query-service="$service" >/dev/null 2>&1; then
            continue
        fi
        log "firewalld allow ${service}"
        run sudo firewall-cmd --permanent --add-service="$service"
        needed=1
    done
    if [[ "$needed" -eq 1 ]]; then
        run sudo firewall-cmd --reload
    fi
}

install_exports() {
    local src="${SETUP_DIR}/files/network/nfs-server.exports"
    local dest="/etc/exports.d/dot-files.exports"

    [[ -f "$src" ]] || die "missing ${src}"
    run sudo mkdir -p /etc/exports.d
    if [[ -f "$dest" ]] && sudo cmp -s "$src" "$dest"; then
        return 0
    fi
    log "write ${dest}"
    run sudo install -m 0644 "$src" "$dest"
}

pkg="$(pick_pkg nfs-utils nfs-kernel-server nfs-server || true)"
if [[ -z "$pkg" ]]; then
    die "no nfs server package found (tried nfs-utils nfs-kernel-server nfs-server)"
fi
ensure_packages "$pkg"

if pick_pkg rpcbind >/dev/null 2>&1; then
    ensure_packages rpcbind
    enable_service rpcbind.service
fi

if [[ -e /srv/data && ! -d /srv/data ]]; then
    die "/srv/data exists and is not a directory"
fi
run sudo mkdir -p /srv/data

install_exports
allow_nfs_firewall

unit=""
for candidate in nfs-server.service nfs-kernel-server.service nfs.service; do
    if systemctl cat "$candidate" >/dev/null 2>&1; then
        unit="$candidate"
        break
    fi
done
[[ -n "$unit" ]] || die "nfs server unit not found after installing ${pkg}"
enable_service "$unit"
if [[ "${DOTFILES_DRY_RUN:-0}" != "1" ]]; then
    sudo systemctl start "$unit" || die "could not start ${unit}"
    sudo exportfs -ra || die "exportfs -ra failed"
else
    log "dry-run: start ${unit} and exportfs -ra"
fi
