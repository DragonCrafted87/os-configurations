#!/usr/bin/env bash
# The Secret portal config is a symlink to the shipped file.
# A dry run leaves the home alone. A second run does not restart the portal.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repo="$(realpath "$repo")"
module="${repo}/setup/modules/desktop/configure-secret-portal.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

home="${work}/home"
dots="${work}/dots"
mkdir -p "${dots}/bashrc.d" "${home}/.config/dot-files" "${work}/bin"
printf 'dot-files=%s\nmachine-setup=%s\n' "$(realpath "$dots")" "$repo" \
    >"${home}/.config/dot-files/checkouts"
cat >"${work}/bin/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${SYSTEMD_LOG}"
exit 0
EOF
chmod 0755 "${work}/bin/systemctl"
: >"${work}/systemd.log"

export DOTFILES_HOME="$home"
export DOTFILES_USER="$(id -un)"
export HOME="$home"
export SYSTEMD_LOG="${work}/systemd.log"
export PATH="${work}/bin:${PATH}"
unset DOTFILES_LIB_LOADED
export DOTFILES_DRY_RUN=1

# shellcheck disable=SC1090
. "$module"

src="${repo}/setup/files/xdg-desktop-portal/hyprland-portals.conf"
dest="${home}/.config/xdg-desktop-portal/hyprland-portals.conf"
[[ ! -e "$dest" ]] || fail "dry-run created ${dest}"
[[ ! -s "${work}/systemd.log" ]] || fail "dry-run called systemctl: $(cat "${work}/systemd.log")"

DOTFILES_DRY_RUN=0
install_secret_portal
[[ -L "$dest" ]] || fail "portal config is not a symlink"
[[ "$(readlink "$dest")" == "$src" ]] || fail "portal config does not point at the shipped file"
grep -F "org.freedesktop.impl.portal.Secret=gnome-keyring" "$dest" >/dev/null \
    || fail "shipped portal config does not select gnome-keyring"
grep -F "default=hyprland;gtk" "$dest" >/dev/null || fail "shipped portal config dropped the Hyprland default"
grep -c "restart xdg-desktop-portal.service" "${work}/systemd.log" >/dev/null \
    || fail "active portal was not restarted"
[[ "$(grep -c "restart xdg-desktop-portal.service" "${work}/systemd.log")" == "1" ]] \
    || fail "portal restart count: $(cat "${work}/systemd.log")"

: >"${work}/systemd.log"
install_secret_portal
[[ ! -s "${work}/systemd.log" ]] || fail "second run called systemctl: $(cat "${work}/systemd.log")"

rm -f "$dest"
printf '[preferred]\ndefault=hyprland;gtk\norg.freedesktop.impl.portal.Secret=gnome-keyring\n' >"${work}/same.conf"
# A regular file with different bytes is moved aside, not left as the config.
printf '[preferred]\ndefault=old\n' >"$dest"
install_secret_portal
[[ -L "$dest" ]] || fail "a regular portal config was not replaced"
bak="$(find "$(dirname "$dest")" -maxdepth 1 -name 'hyprland-portals.conf.bak.*' -print -quit)"
[[ -n "$bak" ]] || fail "the previous portal config was not kept"
grep -F "default=old" "$bak" >/dev/null || fail "the kept portal config lost its contents"
