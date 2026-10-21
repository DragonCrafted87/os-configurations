#!/usr/bin/env bash
# Install the homelab Hyprland RPMs into /usr/local.
# Pins live in setup/versions.conf. Skip while a distro hyprland rpm
# is still present (role reset is what removes it). Vendor homelab is
# our package, so a matching version is left in place.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

HYPRLAND_TAG="${HYPRLAND_TAG:?set HYPRLAND_TAG in setup/versions.conf}"
HYPRLAND_SOURCE_VERSION="${HYPRLAND_SOURCE_VERSION:-${HYPRLAND_TAG#v}}"
PREFIX="${HYPRLAND_SOURCE_PREFIX:-/usr/local}"

# Libraries arrive through Requires. These are the packages a role asks
# dnf for by name.
HYPRLAND_TOP_LEVEL=(
    hyprland
    hyprdesk
    hyprcapture
    hypridle
    hyprlock
    hyprpaper
    hyprpicker
    hyprpolkitagent
    hyprpwcenter
    hyprsunset
    hyprsysteminfo
    hyprshutdown
    hyprland-guiutils
    hyprland-qt-support
    hyprqt6engine
    xdg-desktop-portal-hyprland
)

# Role reset removes the distro package. Our RPM uses Vendor homelab,
# so an installed homelab package is not a reason to skip.
skip_if_distro_hyprland() {
    local query vendor
    query="$(rpm -q --queryformat '%{VENDOR} %{VERSION}' hyprland 2>/dev/null)" || return 0
    vendor="${query%% *}"
    if [[ "$vendor" == "homelab" ]]; then
        return 0
    fi
    log "skip Hyprland source: distro package still installed: ${query}"
    exit 0
}

# A previous prefix build may already have dropped that unit into /usr.
# Move a prefix ExecStart under ${PREFIX}. Delete a unit that still
# execs the old /opt/hyprland tree.
relocate_prefix_user_units() {
    local src dest base was_enabled
    [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]] && return 0
    shopt -s nullglob
    for src in /usr/lib/systemd/user/hypr*.service \
        /usr/lib/systemd/user/xdg-desktop-portal-hyprland.service; do
        [[ -f "$src" ]] || continue
        base="$(basename "$src")"
        dest="${PREFIX}/lib/systemd/user/${base}"
        if grep -qF "ExecStart=/opt/hyprland/" "$src"; then
            log "remove leftover ${src}"
            systemctl --user disable "$base" || true
            sudo rm -f "$src"
            systemctl --user daemon-reload || true
            continue
        fi
        grep -qE "ExecStart=${PREFIX}/(bin|libexec)/" "$src" || continue
        was_enabled=0
        if systemctl --user is-enabled --quiet "$base" 2>/dev/null; then
            was_enabled=1
        fi
        log "move ${src} to ${dest}"
        if [[ ! -f "$dest" ]]; then
            sudo install -d "$(dirname "$dest")"
            sudo install -m 0644 "$src" "$dest"
        fi
        sudo rm -f "$src"
        systemctl --user daemon-reload || true
        if [[ "$was_enabled" == "1" ]]; then
            systemctl --user reenable "$base"
        fi
    done
    shopt -u nullglob
    heal_prefix_unit_enables
}

# enable leaves an existing wants symlink alone, even after the unit file
# moves from /usr/lib to ${PREFIX}. reenable rewrites that link.
heal_prefix_unit_enables() {
    local link target base
    [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]] && return 0
    shopt -s nullglob
    for link in "${DOTFILES_HOME}/.config/systemd/user/"*.wants/hypr*.service \
        "${DOTFILES_HOME}/.config/systemd/user/"*.wants/xdg-desktop-portal-hyprland.service; do
        target="$(readlink "$link" 2>/dev/null || true)"
        case "$target" in
            /usr/lib/systemd/user/* | /opt/hyprland/*) ;;
            *) continue ;;
        esac
        base="$(basename "$link")"
        [[ -f "${PREFIX}/lib/systemd/user/${base}" ]] || continue
        log "reenable ${base}"
        systemctl --user reenable "$base"
    done
    shopt -u nullglob
}

# /usr/local is the install. /opt/hyprland is the previous prefix.
# Stray /usr/bin copies are removed only when no rpm owns them.
remove_cutover_leftovers() {
    local bin
    [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]] && return 0
    [[ -x "${PREFIX}/bin/Hyprland" ]] || return 0
    if [[ -d /opt/hyprland ]] && ! mountpoint -q /opt/hyprland; then
        log "remove leftover /opt/hyprland"
        sudo rm -rf /opt/hyprland
    fi
    for bin in /usr/bin/Hyprland /usr/bin/hyprctl; do
        [[ -e "$bin" ]] || continue
        if rpm -qf "$bin" >/dev/null 2>&1; then
            warn "leave ${bin}; an rpm still owns it"
            continue
        fi
        log "remove leftover ${bin}"
        sudo rm -f "$bin"
    done
}

# The RPMs drop hypridle and hyprpolkitagent units into
# /usr/local/lib/systemd/user without an enable symlink. A role that
# reboots at the end of this module never reaches enable-session-units,
# so the next login's graphical-session.target does not start them.
enable_source_session_units() {
    [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]] && return 0
    systemctl --user daemon-reload || true
    if [[ -x "${PREFIX}/bin/hypridle" ]]; then
        enable_user_service hypridle.service
    fi
    if [[ -x "${PREFIX}/bin/hyprpolkitagent" ]]; then
        enable_user_service hyprpolkitagent.service
    fi
}

# libxkbcommon built with --prefix=/usr/local looks in
# /usr/local/share/X11/xkb. The xkeyboard-config files stay in
# /usr/share/X11/xkb; without this link Hyprland aborts in
# CKeybindManager::updateXKBTranslationState.
ensure_xkb_data() {
    local dest="${PREFIX}/share/X11/xkb" src="/usr/share/X11/xkb"
    [[ -d "$src" ]] || die "missing ${src}"
    if [[ -L "$dest" || -d "$dest" ]]; then
        return 0
    fi
    log "link ${src} -> ${dest}"
    [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]] && return 0
    sudo mkdir -p "$(dirname "$dest")"
    sudo ln -sfn "$src" "$dest"
}

installed_homelab_version() {
    local query vendor version
    query="$(rpm -q --queryformat '%{VENDOR} %{VERSION}' hyprland 2>/dev/null)" || return 1
    vendor="${query%% *}"
    version="${query#* }"
    [[ "$vendor" == "homelab" ]] || return 1
    printf '%s\n' "$version"
}

install_source_rpms() {
    log "dnf install -y ${HYPRLAND_TOP_LEVEL[*]}"
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        ensure_xkb_data
        exit 0
    fi
    sudo dnf install -y "${HYPRLAND_TOP_LEVEL[@]}"
    relocate_prefix_user_units
    remove_cutover_leftovers
    ensure_xkb_data
    enable_source_session_units
}

skip_if_distro_hyprland

if version="$(installed_homelab_version)" && [[ "$version" == "$HYPRLAND_SOURCE_VERSION" ]]; then
    log "Hyprland ${version} prefix already current at ${PREFIX}"
    ensure_xkb_data
    relocate_prefix_user_units
    remove_cutover_leftovers
    enable_source_session_units
    exit 0
fi

install_source_rpms
