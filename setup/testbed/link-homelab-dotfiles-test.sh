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
[[ -L "${same}/machine-setup" ]] || fail "matching trees left machine-setup unlinked"
[[ "$(readlink -f "${same}/machine-setup")" == "$(readlink -f "${same}/git-workspace/homelab/machine-setup")" ]] \
    || fail "machine-setup symlink does not point at the homelab checkout"
[[ ! -e "${same}/machine-setup.before-symlink" ]] \
    || fail "absent machine-setup was moved aside"
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
[[ -L "${same}/machine-setup" ]] || fail "second run removed the machine-setup symlink"

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
mkdir -p "${plain}/dot-files" "${plain}/machine-setup"
printf 'keep\n' >"${plain}/dot-files/marker"
printf 'keep\n' >"${plain}/machine-setup/marker"
rc="$(run_module "$plain")"
[[ "$rc" -eq 0 ]] || fail "absent homelab checkout exited ${rc}: $(cat "${plain}/module.err")"
[[ -d "${plain}/dot-files" && ! -L "${plain}/dot-files" ]] \
    || fail "absent homelab checkout replaced ~/dot-files"
[[ -f "${plain}/dot-files/marker" ]] || fail "absent homelab checkout edited ~/dot-files"
[[ -d "${plain}/machine-setup" && ! -L "${plain}/machine-setup" ]] \
    || fail "absent homelab checkout replaced ~/machine-setup"
[[ -f "${plain}/machine-setup/marker" ]] || fail "absent homelab checkout edited ~/machine-setup"

# ~/dot-files is already the homelab symlink and ~/machine-setup is
# missing. That is a workstation whose setup checkout lives only
# under the parent.
linked_only="${work}/home-linked-only"
seed "$linked_only"
mkdir -p "${linked_only}/git-workspace/homelab/machine-setup"
git clone "$origin" "${linked_only}/git-workspace/homelab/dot-files" >/dev/null
ln -sfn "${linked_only}/git-workspace/homelab/dot-files" "${linked_only}/dot-files"
rc="$(run_module "$linked_only")"
[[ "$rc" -eq 0 ]] || fail "linked dot-files exited ${rc}: $(cat "${linked_only}/module.err")"
[[ -L "${linked_only}/machine-setup" ]] || fail "linked dot-files left machine-setup unlinked"
[[ "$(readlink -f "${linked_only}/machine-setup")" == "$(readlink -f "${linked_only}/git-workspace/homelab/machine-setup")" ]] \
    || fail "linked dot-files pointed machine-setup elsewhere"
[[ ! -e "${linked_only}/dot-files.before-symlink" ]] \
    || fail "linked dot-files moved the existing symlink aside"
grep -F "machine-setup=$(realpath "${linked_only}/git-workspace/homelab/machine-setup")" \
    "${linked_only}/.config/dot-files/checkouts" >/dev/null \
    || fail "linked dot-files did not record the homelab machine-setup path"

# Both home paths are real directories at the same commit. Both move aside.
both="${work}/home-both"
seed "$both"
mkdir -p "${both}/git-workspace/homelab"
git clone "$origin" "${both}/dot-files" >/dev/null
git clone "$origin" "${both}/machine-setup" >/dev/null
git clone "$origin" "${both}/git-workspace/homelab/dot-files" >/dev/null
git clone "$origin" "${both}/git-workspace/homelab/machine-setup" >/dev/null
rc="$(run_module "$both")"
[[ "$rc" -eq 0 ]] || fail "matching machine-setup exited ${rc}: $(cat "${both}/module.err")"
[[ -L "${both}/machine-setup" ]] || fail "matching machine-setup left a real directory"
[[ -d "${both}/machine-setup.before-symlink" && ! -L "${both}/machine-setup.before-symlink" ]] \
    || fail "matching machine-setup was not kept"
[[ -L "${both}/dot-files" ]] || fail "matching machine-setup left dot-files unlinked"

# Classify both trees before moving either. A machine-setup mismatch
# leaves the matching dot-files directory in place.
kept="${work}/home-kept"
seed "$kept"
mkdir -p "${kept}/git-workspace/homelab"
git clone "$origin" "${kept}/dot-files" >/dev/null
git clone "$origin" "${kept}/git-workspace/homelab/dot-files" >/dev/null
git clone "$origin" "${kept}/machine-setup" >/dev/null
git clone "$origin" "${kept}/git-workspace/homelab/machine-setup" >/dev/null
git -C "${kept}/machine-setup" commit --allow-empty -m diverge >/dev/null
rc="$(run_module "$kept")"
[[ "$rc" -ne 0 ]] || fail "diverged machine-setup was accepted"
[[ -d "${kept}/dot-files" && ! -L "${kept}/dot-files" ]] \
    || fail "diverged machine-setup replaced ~/dot-files"
[[ -d "${kept}/machine-setup" && ! -L "${kept}/machine-setup" ]] \
    || fail "diverged machine-setup replaced ~/machine-setup"
[[ ! -e "${kept}/dot-files.before-symlink" && ! -e "${kept}/machine-setup.before-symlink" ]] \
    || fail "diverged machine-setup moved a directory aside"

# Each mismatch condition fails on its own while the other conditions hold.
fresh_pair() {
    local name="$1"
    local home="${work}/home-${name}"
    seed "$home"
    mkdir -p "${home}/git-workspace/homelab"
    git clone "$origin" "${home}/git-workspace/homelab/dot-files" >/dev/null
    ln -sfn "${home}/git-workspace/homelab/dot-files" "${home}/dot-files"
    git clone "$origin" "${home}/machine-setup" >/dev/null
    git clone "$origin" "${home}/git-workspace/homelab/machine-setup" >/dev/null
    printf '%s\n' "$home"
}

expect_setup_stays() {
    local home="$1"
    local label="$2"
    [[ -d "${home}/machine-setup" && ! -L "${home}/machine-setup" ]] \
        || fail "${label} replaced ~/machine-setup"
    [[ -L "${home}/dot-files" ]] || fail "${label} changed ~/dot-files"
    [[ ! -e "${home}/machine-setup.before-symlink" ]] \
        || fail "${label} moved machine-setup aside"
}

dirty_live="$(fresh_pair dirty-live)"
printf 'local\n' >"${dirty_live}/machine-setup/local"
rc="$(run_module "$dirty_live")"
[[ "$rc" -ne 0 ]] || fail "dirty machine-setup was accepted"
expect_setup_stays "$dirty_live" "dirty machine-setup"
grep -F 'local' "${dirty_live}/module.err" >/dev/null \
    || fail "dirty machine-setup omitted its status"

dirty_home="$(fresh_pair dirty-home)"
printf 'local\n' >"${dirty_home}/git-workspace/homelab/machine-setup/local"
rc="$(run_module "$dirty_home")"
[[ "$rc" -ne 0 ]] || fail "dirty homelab machine-setup was accepted"
expect_setup_stays "$dirty_home" "dirty homelab machine-setup"

empty_live="$(fresh_pair empty-live)"
rm -rf "${empty_live}/machine-setup"
mkdir -p "${empty_live}/machine-setup"
rc="$(run_module "$empty_live")"
[[ "$rc" -ne 0 ]] || fail "non-git machine-setup was accepted"
expect_setup_stays "$empty_live" "non-git machine-setup"

empty_home="$(fresh_pair empty-home)"
rm -rf "${empty_home}/git-workspace/homelab/machine-setup"
mkdir -p "${empty_home}/git-workspace/homelab/machine-setup"
rc="$(run_module "$empty_home")"
[[ "$rc" -ne 0 ]] || fail "non-git homelab machine-setup was accepted"
expect_setup_stays "$empty_home" "non-git homelab machine-setup"

wrong_link="$(fresh_pair wrong-link)"
rm -rf "${wrong_link}/machine-setup"
ln -sfn "${wrong_link}/dot-files" "${wrong_link}/machine-setup"
rc="$(run_module "$wrong_link")"
[[ "$rc" -ne 0 ]] || fail "wrong machine-setup symlink was accepted"
[[ -L "${wrong_link}/dot-files" ]] || fail "wrong symlink changed ~/dot-files"
grep -F 'is a symlink' "${wrong_link}/module.err" >/dev/null \
    || fail "wrong symlink error: $(cat "${wrong_link}/module.err")"

not_dir="$(fresh_pair not-dir)"
rm -rf "${not_dir}/machine-setup"
printf 'file\n' >"${not_dir}/machine-setup"
rc="$(run_module "$not_dir")"
[[ "$rc" -ne 0 ]] || fail "machine-setup file was accepted"
[[ -f "${not_dir}/machine-setup" && ! -L "${not_dir}/machine-setup" ]] \
    || fail "machine-setup file was replaced"
[[ -L "${not_dir}/dot-files" ]] || fail "machine-setup file changed ~/dot-files"

backup_exists="$(fresh_pair backup-exists)"
mkdir -p "${backup_exists}/machine-setup.before-symlink"
printf 'stay\n' >"${backup_exists}/machine-setup.before-symlink/stay"
rc="$(run_module "$backup_exists")"
[[ "$rc" -ne 0 ]] || fail "existing machine-setup backup was accepted"
[[ -d "${backup_exists}/machine-setup" && ! -L "${backup_exists}/machine-setup" ]] \
    || fail "existing backup replaced ~/machine-setup"
[[ -f "${backup_exists}/machine-setup/marker" ]] \
    || fail "existing backup moved the machine-setup checkout"
[[ -f "${backup_exists}/machine-setup.before-symlink/stay" ]] \
    || fail "existing backup was replaced"
[[ ! -e "${backup_exists}/machine-setup.before-symlink/machine-setup" ]] \
    || fail "existing backup absorbed the machine-setup checkout"
[[ -L "${backup_exists}/dot-files" ]] || fail "existing backup changed ~/dot-files"

printf 'link homelab dotfiles ok\n'
