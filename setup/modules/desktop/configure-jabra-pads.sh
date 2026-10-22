#!/usr/bin/env bash
# Let the session read Jabra Speak 710 hidraw for the mute pad.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

src="${SETUP_FILES_DIR}/jabra/99-jabra-speak-710.rules"
dest="/etc/udev/rules.d/99-jabra-speak-710.rules"

if [[ ! -f "$src" ]]; then
    warn "missing ${src}"
    exit 0
fi

if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    :
else
    log "udev ${dest}"
    run sudo install -m 0644 "$src" "$dest"
    run sudo udevadm control --reload-rules
    run sudo udevadm trigger --subsystem-match=hidraw || true
fi
