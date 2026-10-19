#!/usr/bin/env bash
# Fixture for lowercase XDG dirs and Dolphin Places. Does not touch the live home.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
module="${HERE}/../modules/common/configure-xdg-user-dirs.sh"
repo="$(cd "${HERE}/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export DOTFILES_USER
DOTFILES_USER="$(id -un)"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

# lib.sh refuses to start unless this home names the running checkout.
# The dot-files side only has to be a directory; this module does not read it.
dots="${work}/dot-files"
mkdir -p "$dots"

seed_checkouts() {
    local home="$1"
    mkdir -p "${home}/.config/dot-files"
    printf 'dot-files=%s\nmachine-setup=%s\n' \
        "$(realpath "$dots")" "$(realpath "$repo")" \
        >"${home}/.config/dot-files/checkouts"
}

run_module() {
    local home="$1"
    local rc=0
    shift
    set +e
    env DOTFILES_HOME="$home" DOTFILES_USER="$DOTFILES_USER" "$@" bash "$module" \
        >"${home}/module.out" 2>"${home}/module.err"
    rc=$?
    set -e
    printf '%s\n' "$rc"
}

resolve_dir() {
    local href="$1"
    local path="${href#file://}"
    path="${path#localhost}"
    path="${path%%\?*}"
    path="${path%%#*}"
    path="${path%/}"
    [[ -d "$path" ]] || fail "shortcut does not resolve: ${href} -> ${path}"
}

# CamelCase dirs move, and Places hrefs follow. Other bookmarks stay.
home="${work}/home"
mkdir -p "${home}/.local/share"
seed_checkouts "$home"
for old in Desktop Downloads Templates Public Documents Music Pictures Videos; do
    mkdir -p "${home}/${old}"
    printf 'marker\n' >"${home}/${old}/marker"
done

cat >"${home}/.local/share/user-places.xbel" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<xbel>
 <bookmark href="file://${home}">
  <title>Home</title>
 </bookmark>
 <bookmark href="file://${home}/Desktop">
  <title>Desktop</title>
 </bookmark>
 <bookmark href="file://${home}/Desktop/">
  <title>Desktop slash</title>
 </bookmark>
 <bookmark href="file://${home}/Documents/notes.txt">
  <title>Notes</title>
 </bookmark>
 <bookmark href="file://${home}/%44ownloads">
  <title>Downloads</title>
 </bookmark>
 <bookmark href="file://${home}/Templates#section">
  <title>Templates</title>
 </bookmark>
 <bookmark href="file://${home}/Public?share=1">
  <title>Public</title>
 </bookmark>
 <bookmark href="file://localhost${home}/Music">
  <title>Music</title>
 </bookmark>
 <bookmark href="file://${home}/pictures">
  <title>Pictures</title>
 </bookmark>
 <bookmark href='file://${home}/Videos'>
  <title>Videos</title>
 </bookmark>
 <bookmark href="file://${home}/DesktopStuff">
  <title>Not a user dir</title>
 </bookmark>
 <bookmark href="file:///tmp/Desktop">
  <title>Elsewhere</title>
 </bookmark>
 <bookmark href="file://${home}/Network/Storage">
  <title>Storage</title>
 </bookmark>
 <bookmark href="trash:/">
  <title>Trash</title>
 </bookmark>
 <bookmark href="remote:/">
  <title>Network</title>
 </bookmark>
 <bookmark href="recentlyused:/files">
  <title>Recent Files</title>
 </bookmark>
 <separator>
  <info>
   <metadata owner="http://www.kde.org">
    <UDI>/org/kde/fstab///host/Storage:${home}/Network/Backups</UDI>
   </metadata>
  </info>
 </separator>
</xbel>
EOF
cp "${home}/.local/share/user-places.xbel" "${work}/places-before"

rc="$(run_module "$home")"
[[ "$rc" -eq 0 ]] || fail "first run exited ${rc}: $(cat "${home}/module.err")"

places="${home}/.local/share/user-places.xbel"
for href in \
    "file://${home}" \
    "file://${home}/desktop" \
    "file://${home}/desktop/" \
    "file://${home}/documents/notes.txt" \
    "file://${home}/downloads" \
    "file://${home}/templates#section" \
    "file://${home}/public?share=1" \
    "file://localhost${home}/music" \
    "file://${home}/pictures" \
    "file://${home}/DesktopStuff" \
    "file:///tmp/Desktop" \
    "file://${home}/Network/Storage" \
    "trash:/" \
    "remote:/" \
    "recentlyused:/files"
do
    grep -F "href=\"${href}\"" "$places" >/dev/null \
        || fail "missing href ${href}"
done
grep -F "href='file://${home}/videos'" "$places" >/dev/null \
    || fail "single-quoted Videos href was not rewritten"
grep -F "<title>Desktop</title>" "$places" >/dev/null \
    || fail "place title was rewritten"
grep -F "${home}/Network/Backups" "$places" >/dev/null \
    || fail "network UDI was rewritten"
grep -F "href=\"file://${home}/Desktop\"" "$places" >/dev/null \
    && fail "CamelCase Desktop href remains"
grep -F "href=\"file://${home}/Documents/notes.txt\"" "$places" >/dev/null \
    && fail "nested Documents href remains"

for href in \
    "file://${home}/desktop" \
    "file://${home}/desktop/" \
    "file://${home}/downloads" \
    "file://${home}/templates#section" \
    "file://${home}/public?share=1" \
    "file://localhost${home}/music" \
    "file://${home}/pictures" \
    "file://${home}/videos"
do
    resolve_dir "$href"
done
for name in desktop downloads templates public documents music pictures videos; do
    [[ -f "${home}/${name}/marker" ]] || fail "marker missing from ${name}"
    [[ ! -e "${home}/${name^}" ]] || fail "CamelCase ${name^} still exists"
done

cmp -s "${repo}/setup/files/xdg/user-dirs.dirs" "${home}/.config/user-dirs.dirs" \
    || fail "user-dirs.dirs does not match the pinned file"
cmp -s "${repo}/setup/files/xdg/user-dirs.conf" "${home}/.config/user-dirs.conf" \
    || fail "user-dirs.conf does not match the pinned file"
grep -F 'enabled=False' "${home}/.config/user-dirs.conf" >/dev/null \
    || fail "enabled=False was not pinned"
grep -F 'XDG_DESKTOP_DIR="$HOME/desktop"' "${home}/.config/user-dirs.dirs" >/dev/null \
    || fail "desktop dir is not lowercase"

# A finished Places file keeps its inode. The pinned dir files do too.
places_inode="$(stat -c '%i' "$places")"
dirs_inode="$(stat -c '%i' "${home}/.config/user-dirs.dirs")"
conf_inode="$(stat -c '%i' "${home}/.config/user-dirs.conf")"
rc="$(run_module "$home")"
[[ "$rc" -eq 0 ]] || fail "second run exited ${rc}: $(cat "${home}/module.err")"
[[ "$(stat -c '%i' "$places")" == "$places_inode" ]] \
    || fail "second run rewrote user-places.xbel"
[[ "$(stat -c '%i' "${home}/.config/user-dirs.dirs")" == "$dirs_inode" ]] \
    || fail "second run rewrote user-dirs.dirs"
[[ "$(stat -c '%i' "${home}/.config/user-dirs.conf")" == "$conf_inode" ]] \
    || fail "second run rewrote user-dirs.conf"
grep -F 'user-places.xbel' "${home}/module.out" >/dev/null \
    && fail "second run logged a places write"
grep -F 'user-dirs.dirs' "${home}/module.out" >/dev/null \
    && fail "second run logged a user-dirs write"

# Dry-run logs the write and leaves the CamelCase href in place.
cp "${work}/places-before" "$places"
printf 'XDG_DESKTOP_DIR="$HOME/Desktop"\n' >"${home}/.config/user-dirs.dirs"
printf 'enabled=True\n' >"${home}/.config/user-dirs.conf"
places_inode="$(stat -c '%i' "$places")"
rc="$(run_module "$home" DOTFILES_DRY_RUN=1)"
[[ "$rc" -eq 0 ]] || fail "dry-run exited ${rc}: $(cat "${home}/module.err")"
cmp -s "${work}/places-before" "$places" || fail "dry-run rewrote places"
[[ "$(stat -c '%i' "$places")" == "$places_inode" ]] || fail "dry-run replaced places"
grep -F 'XDG_DESKTOP_DIR="$HOME/Desktop"' "${home}/.config/user-dirs.dirs" >/dev/null \
    || fail "dry-run rewrote user-dirs.dirs"
grep -F 'enabled=True' "${home}/.config/user-dirs.conf" >/dev/null \
    || fail "dry-run rewrote user-dirs.conf"
grep -F "write ${places}" "${home}/module.out" >/dev/null \
    || fail "dry-run did not log the places write"
grep -F "dry-run: install" "${home}/module.out" >/dev/null \
    || fail "dry-run did not log install"

# No places file: do not invent one.
rm -f "$places"
rc="$(run_module "$home")"
[[ "$rc" -eq 0 ]] || fail "missing places file exited ${rc}: $(cat "${home}/module.err")"
[[ ! -e "$places" ]] || fail "missing places file was created"

# Dry-run does not rename a CamelCase directory.
fresh="${work}/fresh"
mkdir -p "${fresh}/Desktop" "${fresh}/.local/share"
seed_checkouts "$fresh"
printf 'keep\n' >"${fresh}/Desktop/keep"
printf '%s\n' "<bookmark href=\"file://${fresh}/Desktop\"><title>Desktop</title></bookmark>" \
    >"${fresh}/.local/share/user-places.xbel"
rc="$(run_module "$fresh" DOTFILES_DRY_RUN=1)"
[[ "$rc" -eq 0 ]] || fail "fresh dry-run exited ${rc}: $(cat "${fresh}/module.err")"
[[ -f "${fresh}/Desktop/keep" ]] || fail "dry-run moved Desktop"
[[ ! -e "${fresh}/desktop" ]] || fail "dry-run created desktop"
[[ ! -e "${fresh}/.config/user-dirs.dirs" ]] || fail "dry-run created user-dirs.dirs"
grep -F "href=\"file://${fresh}/Desktop\"" "${fresh}/.local/share/user-places.xbel" >/dev/null \
    || fail "fresh dry-run rewrote the Desktop href"

# Both names exist and the old one still has a file: leave it, retarget Places.
both="${work}/both"
mkdir -p "${both}/Desktop" "${both}/desktop" "${both}/.local/share"
seed_checkouts "$both"
printf 'old\n' >"${both}/Desktop/old"
printf '%s\n' "<bookmark href=\"file://${both}/Desktop\"><title>Desktop</title></bookmark>" \
    >"${both}/.local/share/user-places.xbel"
rc="$(run_module "$both")"
[[ "$rc" -eq 0 ]] || fail "both dirs exited ${rc}: $(cat "${both}/module.err")"
[[ -f "${both}/Desktop/old" ]] || fail "non-empty Desktop was removed"
grep -F "leave ${both}/Desktop" "${both}/module.err" >/dev/null \
    || fail "non-empty Desktop was not left in place"
grep -F "href=\"file://${both}/desktop\"" "${both}/.local/share/user-places.xbel" >/dev/null \
    || fail "Places still points at Desktop"
resolve_dir "file://${both}/desktop"

printf 'xdg user dirs ok\n'
