#!/usr/bin/env bash
# Point the Secret portal at gnome-keyring.
# Hyprland's XDG_CURRENT_DESKTOP includes KDE, and the portal's UseIn
# fallback then selects kwallet.portal. Nothing provides that name, so
# Chromium's encryption key is not stored and a login does not survive.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

install_secret_portal() {
    local src="${SETUP_FILES_DIR}/xdg-desktop-portal/hyprland-portals.conf"
    local dest="${CONFIG_TARGET_DIR}/xdg-desktop-portal/hyprland-portals.conf"

    [[ -f "$src" ]] || die "missing ${src}"

    if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
        return 0
    fi

    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        log "dry-run: secret portal ${dest}"
        return 0
    fi

    ensure_dir "$(dirname "$dest")"
    if [[ -f "$dest" && ! -L "$dest" ]] && cmp -s "$src" "$dest"; then
        rm -f "$dest"
    fi
    ensure_symlink "$src" "$dest"

    if systemctl --user is-active --quiet xdg-desktop-portal.service 2>/dev/null; then
        log "restart xdg-desktop-portal"
        systemctl --user restart xdg-desktop-portal.service
    fi
}

install_secret_portal
