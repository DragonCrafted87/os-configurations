#!/usr/bin/env bash
# Install the homelab MakeMKV RPM and one Desktop launcher. Skip the whole
# module when this machine has no DVD/Blu-ray device.
#
# Version comes from setup/versions.conf. The RPM is built by rpms/build.sh.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

MAKEMKV_VERSION="${MAKEMKV_VERSION:?set MAKEMKV_VERSION in setup/versions.conf}"

optical_drives() {
    local node real seen=""
    shopt -s nullglob
    for node in /dev/sr[0-9]* /dev/cdrom /dev/dvd /dev/bd /dev/bluray; do
        [[ -b "$node" || -L "$node" ]] || continue
        real="$(readlink -f "$node" 2>/dev/null || printf '%s' "$node")"
        [[ -b "$real" ]] || continue
        case " $seen " in
            *" $real "*) continue ;;
        esac
        if command -v udevadm >/dev/null 2>&1; then
            if ! udevadm info --query=property --name="$real" 2>/dev/null \
                | grep -q '^ID_CDROM=1$'; then
                continue
            fi
        fi
        printf '%s\n' "$real"
        seen="$seen $real"
    done
}

makemkv_installed() {
    local query
    query="$(rpm -q --queryformat '%{VERSION} %{VENDOR}' makemkv 2>/dev/null)" || return 1
    [[ "$query" == "${MAKEMKV_VERSION} homelab" ]]
}

# The old role build installed into /usr and is not owned by an RPM.
# Those files sit ahead of /usr/local/bin on PATH.
remove_unmanaged_makemkv() {
    local path
    for path in /usr/bin/makemkv /usr/bin/makemkvcon /usr/bin/sdftool \
        /usr/lib/libmakemkv.so.1 /usr/lib/libdriveio.so.0 \
        /usr/share/makemkv/.dotfiles-version; do
        [[ -e "$path" || -L "$path" ]] || continue
        if rpm -qf "$path" >/dev/null 2>&1; then
            continue
        fi
        run sudo rm -f "$path"
    done
    if [[ -d /usr/share/MakeMKV ]] && ! rpm -qf /usr/share/MakeMKV >/dev/null 2>&1; then
        run sudo rm -rf /usr/share/MakeMKV
    fi
}

drives="$(optical_drives || true)"
if [[ -z "$drives" ]]; then
    log "no DVD/Blu-ray drive attached; skip MakeMKV"
    exit 0
fi
log "optical drives: $(printf '%s' "$drives" | tr '\n' ' ')"

if getent group cdrom >/dev/null 2>&1; then
    if ! id -nG "$DOTFILES_USER" | grep -qw cdrom; then
        log "add ${DOTFILES_USER} to cdrom"
        run sudo usermod -aG cdrom "$DOTFILES_USER"
    fi
fi

if makemkv_installed; then
    log "MakeMKV ${MAKEMKV_VERSION} already installed"
elif [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
    log "dnf install -y makemkv"
else
    install_homelab_rpms makemkv
fi
remove_unmanaged_makemkv

sync_src="${SETUP_FILES_DIR}/makemkv/sync-makemkv-desktops.sh"
[[ -f "$sync_src" ]] || die "missing ${sync_src}"

ensure_dir "${DOTFILES_HOME}/bin"
run install -m 0755 "$sync_src" "${DOTFILES_HOME}/bin/sync-makemkv-desktops.sh"

if [[ -f "${DOTFILES_HOME}/.config/autostart/makemkv-sync-desktops.desktop" ]]; then
    run rm -f "${DOTFILES_HOME}/.config/autostart/makemkv-sync-desktops.desktop"
fi

if [[ "${DOTFILES_DRY_RUN:-0}" != "1" ]]; then
    "${DOTFILES_HOME}/bin/sync-makemkv-desktops.sh"
fi
