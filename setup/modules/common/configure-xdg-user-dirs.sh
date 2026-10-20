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
    local tmp mode kept="" old

    [[ -f "$places" ]] || return 0

    # migrate_user_dir leaves the CamelCase directory when the lowercase
    # one already exists and the old one still has files. Those bookmarks
    # still resolve, so they stay.
    for old in Desktop Documents Downloads Music Pictures Public Templates Videos; do
        if [[ -d "${DOTFILES_HOME}/${old}" ]]; then
            kept="${kept} ${old}"
        fi
    done

    tmp="$(mktemp)"
    if ! python3 - "$places" "$tmp" "$DOTFILES_HOME" "$kept" <<'PY'
from pathlib import Path
from urllib.parse import unquote
import re
import sys

src = Path(sys.argv[1])
dest = Path(sys.argv[2])
home = sys.argv[3]
kept = set(sys.argv[4].split()) if len(sys.argv) > 4 else set()
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
hexdigits = "0123456789abcdefABCDEF"

def encoded_end(encoded, decoded_target):
    index = 0
    length = len(encoded)
    while index <= length:
        if unquote(encoded[:index]) == decoded_target:
            return index
        if index == length:
            return None
        if (
            encoded[index] == "%"
            and index + 2 < length
            and encoded[index + 1] in hexdigits
            and encoded[index + 2] in hexdigits
        ):
            index += 3
        else:
            index += 1
    return None

def split_file(url):
    if url.startswith("file://localhost/"):
        scheme = "file://localhost"
    elif url.startswith("file:///"):
        scheme = "file://"
    else:
        return None
    rest = url[len(scheme):]
    cut = len(rest)
    for index, char in enumerate(rest):
        if char in "?#":
            cut = index
            break
    return scheme, rest[:cut], rest[cut:]

def rewrite_url(url):
    parts = split_file(url)
    if parts is None:
        return url
    scheme, path, suffix = parts
    base = home[:-1] if home.endswith("/") and home != "/" else home
    if not base.startswith("/") or base == "/":
        return url
    decoded = unquote(path)
    if decoded != base and not decoded.startswith(base + "/"):
        return url
    if decoded == base:
        return url
    segment = decoded[len(base) + 1:].partition("/")[0]
    new = names.get(segment)
    if new is None or segment in kept:
        return url
    start = encoded_end(path, base + "/")
    end = encoded_end(path, base + "/" + segment)
    if start is None or end is None:
        return url
    return scheme + path[:start] + new + path[end:] + suffix

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
