#!/usr/bin/env bash
# Grok Bot lands as a hashed AppImage, a launcher that selects
# gnome-libsecret, and desktop/MIME entries for the login callback.
# A dry run does not download or write. A second run leaves a match in place.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repo="$(realpath "$repo")"
module="${repo}/setup/modules/desktop/install-grok-bot.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

home="${work}/home"
dots="${work}/dots"
mkdir -p "${dots}/bashrc.d" "${home}/.config/dot-files" "${home}/downloads" "${work}/bin"
printf 'dot-files=%s\nmachine-setup=%s\n' "$(realpath "$dots")" "$repo" \
    >"${home}/.config/dot-files/checkouts"
cat >"${work}/bin/sudo" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"${work}/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${CURL_LOG}"
exit 1
EOF
chmod 0755 "${work}/bin/sudo" "${work}/bin/curl"
: >"${work}/curl.log"

fixture="${home}/downloads/Grok_Bot_9.9.9.AppImage"
cat >"$fixture" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--appimage-extract" ]; then
    mkdir -p squashfs-root
    cat >squashfs-root/grok-bot <<'INNER'
#!/bin/sh
printf 'via=payload\n' >>"${GROK_LAUNCH_LOG}"
printf 'APPIMAGE=%s\n' "${APPIMAGE-unset}" >>"${GROK_LAUNCH_LOG}"
printf '%s\n' "$*" >>"${GROK_LAUNCH_LOG}"
exit 0
INNER
    chmod 0755 squashfs-root/grok-bot
    exit 0
fi
printf 'via=appimage\n' >>"${GROK_LAUNCH_LOG}"
printf '%s\n' "$*" >>"${GROK_LAUNCH_LOG}"
exit 0
EOF
chmod 0755 "$fixture"
sha="$(sha256sum -- "$fixture" | awk '{print $1}')"

export DOTFILES_HOME="$home"
export DOTFILES_USER="$(id -un)"
export HOME="$home"
export XDG_DESKTOP_DIR="${home}/desktop"
export XDG_DATA_HOME="${home}/.local/share"
export GROK_LAUNCH_LOG="${work}/launch.log"
export CURL_LOG="${work}/curl.log"
export GROK_BOT_VERSION=9.9.9
export GROK_BOT_SHA256="$sha"
export GROK_BOT_URL="http://127.0.0.1/unused"
export DOTFILES_DESK_RESTART_FLAG="${work}/need-desk-restart"
export PATH="${work}/bin:${PATH}"
unset DOTFILES_LIB_LOADED
export DOTFILES_DRY_RUN=1

# shellcheck disable=SC1090
. "$module"

dest="${home}/.local/share/grok-bot/Grok_Bot.AppImage"
wrapper="${home}/.local/bin/grok-bot"
[[ ! -e "$dest" ]] || fail "dry-run installed the AppImage"
[[ ! -e "$wrapper" ]] || fail "dry-run installed the launcher"
[[ ! -s "${work}/curl.log" ]] || fail "dry-run downloaded: $(cat "${work}/curl.log")"

DOTFILES_DRY_RUN=0
install_grok_bot
[[ -f "$dest" ]] || fail "AppImage was not installed"
[[ "$(sha256sum -- "$dest" | awk '{print $1}')" == "$sha" ]] || fail "installed AppImage hash drifted"
[[ ! -e "${home}/.local/share/grok-bot/appimage" ]] || fail "downloads symlink remains"
[[ -x "$wrapper" ]] || fail "launcher is not executable"
[[ -x "${home}/.local/share/grok-bot/payload/grok-bot" ]] || fail "payload was not extracted"
[[ -f "${home}/.local/share/icons/hicolor/512x512/apps/grok-bot.png" ]] || fail "icon was not installed"
desk="${home}/.local/share/applications/grok-bot.desktop"
[[ -f "$desk" ]] || fail "desktop file was not installed"
grep -F "Exec=${wrapper} %U" "$desk" >/dev/null || fail "desktop Exec is not the launcher"
grep -F "x-scheme-handler/grokbot" "$desk" >/dev/null || fail "desktop file dropped grokbot"
grep -F "x-scheme-handler/sand" "$desk" >/dev/null || fail "desktop file dropped sand"
grep -F "X-GrokBot-Integrator" "$desk" && fail "desktop file kept the AppImage integrator"
mime="${home}/.config/mimeapps.list"
grep -qxF "x-scheme-handler/grokbot=grok-bot.desktop" "$mime" || fail "grokbot scheme was not registered"
grep -qxF "x-scheme-handler/sand=grok-bot.desktop" "$mime" || fail "sand scheme was not registered"
[[ ! -s "${work}/curl.log" ]] || fail "matching download was fetched again"

"$wrapper" --help >/dev/null
[[ ! -e "${work}/launch.log" ]] || fail "--help launched the AppImage"
"$wrapper" --class probe
grep -qxF 'via=payload' "${work}/launch.log" || fail "launcher did not start the payload: $(cat "${work}/launch.log")"
grep -qxF 'via=appimage' "${work}/launch.log" && fail "launcher started the AppImage"
grep -qxF 'APPIMAGE=unset' "${work}/launch.log" || fail "APPIMAGE was set: $(cat "${work}/launch.log")"
if unshare -Ur true >/dev/null 2>&1; then
    probe_args="--password-store=gnome-libsecret --class probe"
else
    probe_args="--password-store=gnome-libsecret --no-sandbox --class probe"
fi
grep -qxF -- "$probe_args" "${work}/launch.log" \
    || fail "launcher args: $(cat "${work}/launch.log")"

sleep 1
payload="${home}/.local/share/grok-bot/payload/grok-bot"
before="$(stat -c %Y "$dest" "$wrapper" "$desk" "$payload" | sha256sum)"
: >"${work}/launch.log"
install_grok_bot
after="$(stat -c %Y "$dest" "$wrapper" "$desk" "$payload" | sha256sum)"
[[ "$before" == "$after" ]] || fail "second run rewrote an installed Grok Bot"
[[ ! -s "${work}/launch.log" ]] || fail "second run launched Grok Bot"

printf 'other=keep.desktop\n' >"$mime"
printf '[Default Applications]\ntext/plain=code.desktop\nx-scheme-handler/grokbot=old.desktop\n' >>"$mime"
install_grok_launcher
grep -qxF "text/plain=code.desktop" "$mime" || fail "MIME merge dropped an existing handler"
grep -qxF "x-scheme-handler/grokbot=grok-bot.desktop" "$mime" || fail "MIME merge left the old grokbot handler"
grep -qxF "x-scheme-handler/sand=grok-bot.desktop" "$mime" || fail "MIME merge missed sand"

ln -sfn "${home}/downloads/Grok_Bot_9.9.9.AppImage" "${home}/.local/share/grok-bot/appimage"
install_grok_launcher
[[ ! -e "${home}/.local/share/grok-bot/appimage" ]] || fail "downloads symlink was not removed"

rm -f "$dest"
printf 'not-the-app\n' >"${home}/downloads/Grok_Bot_9.9.9.AppImage"
if (install_grok_appimage); then
    fail "a hash miss returned 0"
fi
[[ -s "${work}/curl.log" ]] || fail "a hash miss did not try the pinned URL"
