#!/usr/bin/env bash
# Bluetooth Xbox pad. hid-xpadneo is the controller interface.
# The wireless dongle stays in configure-xbox-controller.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

XPADNEO_DIR="${XPADNEO_DIR:-${DOTFILES_HOME}/src/xpadneo}"
XPADNEO_URL="${XPADNEO_URL:-https://github.com/atar-axis/xpadneo.git}"
KERNEL="$(uname -r)"

# uname -r looks like 6.14.2-desktop-3omv2590 or 6.15.0-desktop-0.rc2.3omv2590.
# DKMS needs kernel-<flavor>-devel, not kernel-headers (those are glibc only).
running_kernel_devel_packages() {
    local rel flavor pkg
    rel="$(uname -r)"
    flavor="${rel#*-}"
    flavor="${flavor%%-*}"
    if [[ "$rel" == *desktop-gcc* ]]; then
        flavor="desktop-gcc"
    fi
    for pkg in \
        "kernel-${flavor}-devel" \
        "kernel-rc-${flavor}-devel" \
        kernel-devel; do
        if rpm -q "$pkg" >/dev/null 2>&1 || dnf list --available "$pkg" >/dev/null 2>&1; then
            printf '%s\n' "$pkg"
        fi
    done
}

install_build_deps() {
    local pkgs=(dkms git gcc make)
    local extra=()
    mapfile -t extra < <(running_kernel_devel_packages)
    if dnf list --available steam-devices >/dev/null 2>&1 || rpm -q steam-devices >/dev/null 2>&1; then
        extra+=(steam-devices)
    fi
    ensure_packages "${pkgs[@]}" "${extra[@]}"
    if [[ ! -e "/lib/modules/${KERNEL}/build" ]]; then
        die "DKMS headers missing for ${KERNEL}. Install kernel-desktop-devel or kernel-rc-desktop-devel."
    fi
}

ensure_input_groups() {
    local grp
    for grp in input plugdev; do
        getent group "$grp" >/dev/null || continue
        if ! id -nG "${DOTFILES_USER}" | grep -qw "$grp"; then
            log "add ${DOTFILES_USER} to ${grp}"
            run sudo usermod -aG "$grp" "${DOTFILES_USER}"
        fi
    done
}

dkms_module_version() {
    local name="$1"
    dkms status "$name" 2>/dev/null | awk -F'[,/ ]+' '
        $1 == name && $2 != "unknown" { print $2; exit }
    ' name="$name"
}

dkms_has_kernel() {
    local name="$1"
    dkms status "$name" 2>/dev/null | grep -F "$KERNEL" | grep -qi installed
}

ensure_dkms_for_running_kernel() {
    local name="$1"
    local ver
    ver="$(dkms_module_version "$name" || true)"
    [[ -n "$ver" ]] || return 0
    if dkms_has_kernel "$name"; then
        log "${name} already built for ${KERNEL}"
        return 0
    fi
    log "dkms install ${name}/${ver} for ${KERNEL}"
    run sudo dkms install -m "$name" -v "$ver" -k "$KERNEL"
}

install_helper() {
    local src="${SETUP_FILES_DIR}/xbox/xbox-controller.sh"
    [[ -f "$src" ]] || return 0
    log "install /usr/local/bin/xbox-controller"
    run sudo install -m 0755 "$src" /usr/local/bin/xbox-controller
}

install_xpadneo() {
    ensure_dir "$(dirname "$XPADNEO_DIR")"
    ensure_repo "$XPADNEO_URL" "$XPADNEO_DIR"
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    local neo_name=""
    if dkms status hid-xpadneo >/dev/null 2>&1 && [[ -n "$(dkms_module_version hid-xpadneo || true)" ]]; then
        neo_name=hid-xpadneo
    elif dkms status xpadneo >/dev/null 2>&1 && [[ -n "$(dkms_module_version xpadneo || true)" ]]; then
        neo_name=xpadneo
    fi
    if [[ -z "$neo_name" && -x "${XPADNEO_DIR}/install.sh" ]]; then
        log "install xpadneo (Bluetooth pad)"
        run sudo bash -lc "cd $(printf '%q' "$XPADNEO_DIR") && ./install.sh"
        if [[ -n "$(dkms_module_version hid-xpadneo || true)" ]]; then
            neo_name=hid-xpadneo
        else
            neo_name=xpadneo
        fi
    fi
    [[ -n "$neo_name" ]] && ensure_dkms_for_running_kernel "$neo_name"
    run sudo modprobe hid-xpadneo || true
}

[[ "${XBOX_INSTALL_XPADNEO:-1}" == "1" ]] || exit 0

install_build_deps
ensure_input_groups
install_xpadneo
install_helper

log "Xbox Bluetooth: hid-xpadneo   (xbox-controller status)"
