#!/usr/bin/env bash
# One BOINC Manager desktop id. make install's boinc.desktop is replaced.
# The old boincmgr.desktop copies are removed. A dry run leaves both.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repo="$(realpath "$repo")"
module="${repo}/setup/modules/compute/install-boinc-manager.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

home="${work}/home"
prefix="${work}/prefix"
dots="${work}/dots"
apps="${prefix}/share/applications"
user_apps="${home}/.local/share/applications"
src="${repo}/setup/files/boinc/boinc.desktop"
empty="${work}/empty-files"

mkdir -p "${dots}/bashrc.d" "${home}/.config/dot-files" "$apps" "$user_apps" "$empty" "${work}/bin"
printf '# fixture\n' >"${dots}/bashrc.d/compiler.bashrc"
printf 'dot-files=%s\nmachine-setup=%s\n' "$(realpath "$dots")" "$repo" \
    >"${home}/.config/dot-files/checkouts"
cat >"${work}/bin/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${SUDO_LOG}"
exec "$@"
EOF
chmod 0755 "${work}/bin/sudo"
: >"${work}/sudo.log"

export DOTFILES_HOME="$home"
export DOTFILES_USER="$(id -un)"
export BOINC_PREFIX="$prefix"
export SUDO_LOG="${work}/sudo.log"
export PATH="${work}/bin:${PATH}"
unset DOTFILES_LIB_LOADED
# shellcheck disable=SC1090
. "$module"

[[ -f "$src" ]] || fail "missing ${src}"

printf 'upstream\n' >"${apps}/boinc.desktop"
printf 'user-stale\n' >"${user_apps}/boincmgr.desktop"
printf 'sys-stale\n' >"${apps}/boincmgr.desktop"

saved_files="$SETUP_FILES_DIR"
SETUP_FILES_DIR="$empty"
install_manager_desktop
SETUP_FILES_DIR="$saved_files"
[[ "$(cat "${apps}/boinc.desktop")" == "upstream" ]] || fail "missing source replaced boinc.desktop"
[[ -f "${user_apps}/boincmgr.desktop" ]] || fail "missing source removed the user launcher"
[[ -f "${apps}/boincmgr.desktop" ]] || fail "missing source removed the system launcher"

DOTFILES_DRY_RUN=1
install_manager_desktop
DOTFILES_DRY_RUN=0
[[ "$(cat "${apps}/boinc.desktop")" == "upstream" ]] || fail "dry-run replaced boinc.desktop"
[[ -f "${user_apps}/boincmgr.desktop" && -f "${apps}/boincmgr.desktop" ]] || fail "dry-run removed a stale launcher"
[[ ! -s "${work}/sudo.log" ]] || fail "dry-run called sudo: $(cat "${work}/sudo.log")"

install_manager_desktop
cmp -s "$src" "${apps}/boinc.desktop" || fail "boinc.desktop is not the shipped launcher"
[[ ! -e "${user_apps}/boincmgr.desktop" ]] || fail "user boincmgr.desktop remains"
[[ ! -e "${apps}/boincmgr.desktop" ]] || fail "system boincmgr.desktop remains"
[[ "$(stat -c %a "${apps}/boinc.desktop")" == "644" ]] || fail "boinc.desktop mode is not 644"
grep -F "rm -f ${user_apps}/boincmgr.desktop" "${work}/sudo.log" && fail "user launcher was removed with sudo"
grep -F "rm -f ${apps}/boincmgr.desktop" "${work}/sudo.log" >/dev/null || fail "system launcher was not removed with sudo"

sleep 1
before="$(stat -c %Y "${apps}/boinc.desktop")"
: >"${work}/sudo.log"
install_manager_desktop
after="$(stat -c %Y "${apps}/boinc.desktop")"
[[ "$before" == "$after" ]] || fail "second run rewrote a matching boinc.desktop"
grep -F "install -m 0644" "${work}/sudo.log" && fail "second run installed again"

printf 'user-stale\n' >"${user_apps}/boincmgr.desktop"
: >"${work}/sudo.log"
install_manager_desktop
[[ ! -e "${user_apps}/boincmgr.desktop" ]] || fail "user stale survived a later run"
[[ -f "${apps}/boincmgr.desktop" ]] && fail "system stale reappeared"
grep -F "rm -f ${user_apps}/boincmgr.desktop" "${work}/sudo.log" && fail "later user removal used sudo"

printf 'sys-stale\n' >"${apps}/boincmgr.desktop"
: >"${work}/sudo.log"
install_manager_desktop
[[ ! -e "${apps}/boincmgr.desktop" ]] || fail "system stale survived a later run"
grep -F "rm -f ${apps}/boincmgr.desktop" "${work}/sudo.log" >/dev/null || fail "later system removal skipped sudo"

printf 'boinc desktop id ok\n'
