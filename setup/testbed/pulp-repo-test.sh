#!/usr/bin/env bash
# enable-pulp-repo writes the homelab Pulp dnf repo. A dry run leaves
# the file alone. A second run does not rewrite a matching file.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repo="$(realpath "$repo")"
module="${repo}/setup/modules/common/enable-pulp-repo.sh"
roles="${repo}/setup/roles.conf"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

home="${work}/home"
dots="${work}/dots"
mkdir -p "${dots}/bashrc.d" "${home}/.config/dot-files"
printf 'dot-files=%s\nmachine-setup=%s\n' "$(realpath "$dots")" "$repo" \
    >"${home}/.config/dot-files/checkouts"
export DOTFILES_HOME="$home"
export DOTFILES_USER="$(id -un)"
export HOME="$home"
export DOTFILES_TEST_SOURCE=1
unset DOTFILES_LIB_LOADED
unset DOTFILES_DRY_RUN

# shellcheck disable=SC1090
. "$module"

dest="${work}/homelab-pulp.repo"
expected="$(pulp_repo_body)"

DOTFILES_DRY_RUN=1
write_pulp_repo "$dest"
[[ ! -e "$dest" ]] || fail "dry-run created the repo file"

DOTFILES_DRY_RUN=0
write_pulp_repo "$dest"
[[ "$(cat "$dest")" == "$expected" ]] || fail "repo file body drifted"
grep -F 'baseurl=https://pulp.stealthdragonland.net/pulp/content/homelab/' "$dest" >/dev/null \
    || fail "baseurl is missing"
grep -F 'gpgcheck=0' "$dest" >/dev/null || fail "gpgcheck was left on"
grep -F 'skip_if_unavailable=1' "$dest" >/dev/null || fail "skip_if_unavailable is missing"

before="$(stat -c '%Y' "$dest")"
sleep 1
write_pulp_repo "$dest"
[[ "$(stat -c '%Y' "$dest")" == "$before" ]] || fail "second run rewrote a matching file"

printf '[homelab]\nname=old\n' >"$dest"
write_pulp_repo "$dest"
[[ "$(cat "$dest")" == "$expected" ]] || fail "drifted repo file was left in place"

awk '
    /^\[common\]/ { in_common=1; next }
    /^\[/ { in_common=0 }
    in_common && $0 == "enable-pulp-repo" { found=1 }
    END { exit !found }
' "$roles" || fail "common role does not run enable-pulp-repo"

printf 'pulp repo ok.\n'
