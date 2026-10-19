#!/usr/bin/env bash
# Lowercase the eight XDG user dirs and pin them so login does not
# recreate Desktop/Downloads. Point Dolphin Places at those directories.
# ~/network is owned by mount-network.sh.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

src_dirs="${SETUP_FILES_DIR}/xdg/user-dirs.dirs"
src_conf="${SETUP_FILES_DIR}/xdg/user-dirs.conf"
dest_dirs="${CONFIG_TARGET_DIR}/user-dirs.dirs"
dest_conf="${CONFIG_TARGET_DIR}/user-dirs.conf"

[[ -f "$src_dirs" ]] || die "missing ${src_dirs}"
[[ -f "$src_conf" ]] || die "missing ${src_conf}"

write_if_changed() {
    local src="$1"
    local dest="$2"

    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        return 0
    fi
    log "write ${dest}"
    run install -m 0644 "$src" "$dest"
}

# Move CamelCase XDG dirs to lowercase. Leave a leftover if both exist
# and the old one still has files.
migrate_user_dir() {
    local old="${DOTFILES_HOME}/$1"
    local new="${DOTFILES_HOME}/$2"

    if [[ -e "$old" || -L "$old" ]]; then
        if [[ ! -e "$new" && ! -L "$new" ]]; then
            log "rename ${old} -> ${new}"
            run mv "$old" "$new"
            return 0
        fi
        if [[ -d "$old" && -z "$(find "$old" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            log "remove empty ${old}"
            run rmdir "$old"
            return 0
        fi
        warn "leave ${old}; ${new} already exists"
        return 0
    fi
    ensure_dir "$new"
}

rewrite_user_places() {
    local places="${DOTFILES_HOME}/.local/share/user-places.xbel"
    local tmp mode

    [[ -f "$places" ]] || return 0

    tmp="$(mktemp)"
    if ! python3 - "$places" "$tmp" "$DOTFILES_HOME" <<'PY'
from pathlib import Path
from urllib.parse import unquote
import re
import sys

src = Path(sys.argv[1])
dest = Path(sys.argv[2])
home = sys.argv[3]
names = {
    "Desktop": "desktop",
    "Documents": "documents",
    "Downloads": "downloads",
    "Music": "music",
    "Pictures": "pictures",
    "Public": "public",
    "Templates": "templates",
    "Videos": "videos",
}

if home.startswith("/") and home != "/":
    base = home[:-1] if home.endswith("/") else home
    prefixes = (
        "file://" + base + "/",
        "file://localhost" + base + "/",
    )
else:
    prefixes = ()

def rewrite_url(url):
    matched = None
    for prefix in prefixes:
        if url.startswith(prefix):
            matched = prefix
            break
    if matched is None:
        return url
    rest = url[len(matched):]
    cut = len(rest)
    for index, char in enumerate(rest):
        if char in "/?#":
            cut = index
            break
    new = names.get(unquote(rest[:cut]))
    if new is None:
        return url
    return matched + new + rest[cut:]

pattern = re.compile(r"""href=(["'])([^"']*)\1""")

def repl(match):
    quote = match.group(1)
    url = match.group(2)
    new = rewrite_url(url)
    if new == url:
        return match.group(0)
    return "href=" + quote + new + quote

raw = src.read_bytes()
text = raw.decode("utf-8", "surrogateescape")
out = pattern.sub(repl, text)
dest.write_bytes(out.encode("utf-8", "surrogateescape"))
PY
    then
        rm -f "$tmp"
        die "could not rewrite ${places}"
    fi

    if cmp -s "$places" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi

    log "write ${places}"
    mode="$(stat -c '%a' "$places")"
    run install -m "$mode" "$tmp" "$places"
    rm -f "$tmp"
}

ensure_dir "$CONFIG_TARGET_DIR"
write_if_changed "$src_dirs" "$dest_dirs"
write_if_changed "$src_conf" "$dest_conf"

migrate_user_dir Desktop desktop
migrate_user_dir Documents documents
migrate_user_dir Downloads downloads
migrate_user_dir Templates templates
migrate_user_dir Public public
migrate_user_dir Music music
migrate_user_dir Pictures pictures
migrate_user_dir Videos videos

rewrite_user_places
