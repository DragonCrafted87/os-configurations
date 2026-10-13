#!/usr/bin/env bash
# Pinned Grok Bot AppImage, desktop file, and launcher.
# configure-secret-portal selects the keyring. This launcher tells
# Chromium to use it, because a bare AppImage still probes KWallet.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

file_sha256() {
    sha256sum -- "$1" | awk '{print $1}'
}

install_grok_appimage() {
    local share dest candidate
    share="${DOTFILES_HOME}/.local/share/grok-bot"
    dest="${share}/Grok_Bot.AppImage"

    [[ -n "${GROK_BOT_VERSION:-}" && -n "${GROK_BOT_SHA256:-}" && -n "${GROK_BOT_URL:-}" ]] \
        || die "set GROK_BOT_VERSION, GROK_BOT_SHA256, and GROK_BOT_URL"
    [[ "$(uname -m)" == "x86_64" ]] || die "Grok Bot AppImage is pinned for x86_64"

    ensure_packages fuse2
    ensure_dir "$share"

    if [[ -f "$dest" && "$(file_sha256 "$dest")" == "$GROK_BOT_SHA256" ]]; then
        return 0
    fi

    for candidate in \
        "${DOTFILES_HOME}/downloads/Grok_Bot_${GROK_BOT_VERSION}.AppImage" \
        "${DOTFILES_HOME}/Downloads/Grok_Bot_${GROK_BOT_VERSION}.AppImage"; do
        if [[ -f "$candidate" && "$(file_sha256 "$candidate")" == "$GROK_BOT_SHA256" ]]; then
            log "install Grok Bot ${GROK_BOT_VERSION} from ${candidate}"
            run install -m 0755 "$candidate" "$dest"
            return 0
        fi
    done

    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        log "dry-run: download Grok Bot ${GROK_BOT_VERSION}"
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    log "download Grok Bot ${GROK_BOT_VERSION}"
    if ! curl -fsSL --max-time 180 -o "$tmp" "$GROK_BOT_URL"; then
        rm -f "$tmp"
        die "download of Grok Bot ${GROK_BOT_VERSION} failed"
    fi
    if ! echo "${GROK_BOT_SHA256}  ${tmp}" | sha256sum -c -; then
        rm -f "$tmp"
        die "Grok Bot ${GROK_BOT_VERSION} hash mismatch"
    fi
    install -m 0755 "$tmp" "$dest"
    rm -f "$tmp"
}

install_grok_launcher() {
    local share wrapper_src wrapper_dest icon_src icon_dest desk legacy
    share="${DOTFILES_HOME}/.local/share/grok-bot"
    wrapper_src="${SETUP_FILES_DIR}/grok-bot/grok-bot"
    wrapper_dest="${DOTFILES_HOME}/.local/bin/grok-bot"
    icon_src="${SETUP_FILES_DIR}/grok-bot/grok-bot.png"
    icon_dest="${DOTFILES_HOME}/.local/share/icons/hicolor/512x512/apps/grok-bot.png"
    legacy="${share}/appimage"

    [[ -f "$wrapper_src" && -f "$icon_src" ]] || die "missing Grok Bot launcher files"

    if [[ -L "$legacy" ]]; then
        log "remove ${legacy}"
        run rm -f "$legacy"
    fi

    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        log "dry-run: install grok-bot launcher"
        return 0
    fi

    ensure_dir "$(dirname "$wrapper_dest")"
    ensure_dir "$(dirname "$icon_dest")"
    if [[ ! -f "$wrapper_dest" ]] || ! cmp -s "$wrapper_src" "$wrapper_dest"; then
        install -m 0755 "$wrapper_src" "$wrapper_dest"
        log "install ${wrapper_dest}"
    fi
    if [[ ! -f "$icon_dest" ]] || ! cmp -s "$icon_src" "$icon_dest"; then
        install -m 0644 "$icon_src" "$icon_dest"
        log "install ${icon_dest}"
    fi

    local desk_dir
    desk_dir="$(mktemp -d)"
    desk="${desk_dir}/grok-bot.desktop"
    cat >"$desk" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Grok Bot
Comment=Grok Bot desktop agent
Exec=${wrapper_dest} %U
Icon=${icon_dest}
Terminal=false
StartupWMClass=grok-bot
StartupNotify=true
Categories=Development;
MimeType=x-scheme-handler/grokbot;x-scheme-handler/sand;
EOF
    install_user_desktop "$desk"
    rm -rf "$desk_dir"

    python3 - "${CONFIG_TARGET_DIR}/mimeapps.list" <<'PY'
import pathlib
import sys

dest = pathlib.Path(sys.argv[1])
wanted = {
    "x-scheme-handler/grokbot": "grok-bot.desktop",
    "x-scheme-handler/sand": "grok-bot.desktop",
}
text = dest.read_text() if dest.is_file() else ""
lines = text.splitlines()
out = []
in_section = False
seen_section = False
done = set()
for raw in lines:
    stripped = raw.strip()
    if stripped == "[Default Applications]":
        in_section = True
        seen_section = True
        out.append(raw)
        continue
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_section:
            for mime, desktop in wanted.items():
                if mime not in done:
                    out.append(f"{mime}={desktop}")
                    done.add(mime)
        in_section = False
        out.append(raw)
        continue
    if in_section:
        key = stripped.split("=", 1)[0]
        if key in wanted:
            if key not in done:
                out.append(f"{key}={wanted[key]}")
                done.add(key)
            continue
    out.append(raw)
if not seen_section:
    if out and out[-1] != "":
        out.append("")
    out.append("[Default Applications]")
if in_section or not seen_section:
    for mime, desktop in wanted.items():
        if mime not in done:
            out.append(f"{mime}={desktop}")
body = "\n".join(out).rstrip("\n") + "\n"
dest.parent.mkdir(parents=True, exist_ok=True)
if not dest.is_file() or dest.read_text() != body:
    dest.write_text(body)
PY
}

install_grok_bot() {
    install_grok_appimage
    install_grok_launcher
}

install_grok_bot
