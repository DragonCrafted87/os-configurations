#!/usr/bin/env bash
# write_saved_role records the role init-remote.sh was given.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/../init-remote.sh"
# shellcheck disable=SC1091
. "${HERE}/../subroles.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export HOME="$work"
export CONFIG_TARGET_DIR="${work}/.config"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

write_saved_role server
[[ -f "${HOME}/.config/dot-files/role" ]] || fail "server did not create the role file"
[[ "$(tr -d '[:space:]' <"${HOME}/.config/dot-files/role")" == "server" ]] || fail "server role was not written"

write_saved_role server
[[ "$(tr -d '[:space:]' <"${HOME}/.config/dot-files/role")" == "server" ]] || fail "second server write changed the role"

write_saved_role htpc
[[ "$(tr -d '[:space:]' <"${HOME}/.config/dot-files/role")" == "htpc" ]] || fail "htpc did not replace the role"
[[ "$(read_saved_role)" == "htpc" ]] || fail "read_saved_role did not return htpc"

printf 'init-remote role file ok\n'
