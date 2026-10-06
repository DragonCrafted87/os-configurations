#!/usr/bin/env bash
# Fixture for the workstation symlink. Does not touch the live ~/dot-files.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
module="${HERE}/../modules/common/link-homelab-dotfiles.sh"
real_setup="$(cd "${HERE}/../.." && pwd)"
real_dots="$(cd "${real_setup}/../dot-files" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[[ -d "${real_dots}/bashrc.d" ]] || {
    printf 'missing homelab dot-files checkout %s\n' "$real_dots" >&2
    exit 1
}

export GIT_AUTHOR_NAME=fixture
export GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture
export GIT_COMMITTER_EMAIL=fixture@example.com

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

seed() {
    local home="$1"
    mkdir -p "${home}/.config/dot-files"
    printf 'dot-files=%s\nmachine-setup=%s\n' \
        "$(realpath "$real_dots")" "$(realpath "$real_setup")" \
        >"${home}/.config/dot-files/checkouts"
}

run_module() {
    local home="$1"
    local rc=0
    set +e
    DOTFILES_HOME="$home" bash "$module" >"${home}/module.out" 2>"${home}/module.err"
    rc=$?
    set -e
    printf '%s\n' "$rc"
}

# Same commit, both trees clean: the real directory moves aside.
origin="${work}/origin"
git init -b main "$origin" >/dev/null
printf 'same\n' >"${origin}/marker"
git -C "$origin" add marker
git -C "$origin" commit -m same >/dev/null

same="${work}/home-same"
seed "$same"
mkdir -p "${same}/git-workspace/homelab/machine-setup"
git clone "$origin" "${same}/dot-files" >/dev/null
git clone "$origin" "${same}/git-workspace/homelab/dot-files" >/dev/null
rc="$(run_module "$same")"
[[ "$rc" -eq 0 ]] || fail "matching trees exited ${rc}: $(cat "${same}/module.err")"
[[ -L "${same}/dot-files" ]] || fail "matching trees left a real directory"
[[ "$(readlink -f "${same}/dot-files")" == "$(readlink -f "${same}/git-workspace/homelab/dot-files")" ]] \
    || fail "symlink does not point at the homelab checkout"
[[ -d "${same}/dot-files.before-symlink" && ! -L "${same}/dot-files.before-symlink" ]] \
    || fail "the previous directory was not kept"
grep -F "dot-files=$(realpath "${same}/git-workspace/homelab/dot-files")" \
    "${same}/.config/dot-files/checkouts" >/dev/null \
    || fail "checkouts file omitted the homelab dot-files path"
grep -F "machine-setup=$(realpath "${same}/git-workspace/homelab/machine-setup")" \
    "${same}/.config/dot-files/checkouts" >/dev/null \
    || fail "checkouts file omitted the homelab machine-setup path"

# Already the symlink: a second run leaves the backup where it is.
# The checkouts file is put back to this checkout first. lib.sh rejects
# a machine-setup path that is not the running tree, and a live
# workstation records that same tree.
backup_marker="${same}/dot-files.before-symlink/marker"
before="$(cksum "$backup_marker")"
seed "$same"
rc="$(run_module "$same")"
[[ "$rc" -eq 0 ]] || fail "second symlink run exited ${rc}: $(cat "${same}/module.err")"
[[ "$(cksum "$backup_marker")" == "$before" ]] || fail "second run moved the backup"

# Different commits: both directories stay, and the error names both heads.
diverged="${work}/home-diverged"
seed "$diverged"
mkdir -p "${diverged}/git-workspace/homelab"
git clone "$origin" "${diverged}/dot-files" >/dev/null
git clone "$origin" "${diverged}/git-workspace/homelab/dot-files" >/dev/null
git -C "${diverged}/dot-files" commit --allow-empty -m diverge >/dev/null
live_head="$(git -C "${diverged}/dot-files" rev-parse HEAD)"
home_head="$(git -C "${diverged}/git-workspace/homelab/dot-files" rev-parse HEAD)"
rc="$(run_module "$diverged")"
[[ "$rc" -ne 0 ]] || fail "different commits were accepted"
[[ -d "${diverged}/dot-files" && ! -L "${diverged}/dot-files" ]] \
    || fail "different commits removed ~/dot-files"
[[ -d "${diverged}/git-workspace/homelab/dot-files" ]] \
    || fail "different commits removed the homelab checkout"
[[ ! -e "${diverged}/dot-files.before-symlink" ]] \
    || fail "different commits moved the directory aside"
grep -F "$live_head" "${diverged}/module.err" >/dev/null \
    || fail "mismatch error omitted the live head"
grep -F "$home_head" "${diverged}/module.err" >/dev/null \
    || fail "mismatch error omitted the homelab head"

# No homelab dot-files checkout: an htpc or server tree stays a directory.
plain="${work}/home-plain"
seed "$plain"
mkdir -p "${plain}/dot-files"
printf 'keep\n' >"${plain}/dot-files/marker"
rc="$(run_module "$plain")"
[[ "$rc" -eq 0 ]] || fail "absent homelab checkout exited ${rc}: $(cat "${plain}/module.err")"
[[ -d "${plain}/dot-files" && ! -L "${plain}/dot-files" ]] \
    || fail "absent homelab checkout replaced ~/dot-files"
[[ -f "${plain}/dot-files/marker" ]] || fail "absent homelab checkout edited ~/dot-files"

printf 'link homelab dotfiles ok\n'
