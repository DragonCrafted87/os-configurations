#!/usr/bin/env bash
# install-python-dev copies the template pre-commit hook into a
# submodule's real git dir, the superproject, and a linked worktree.
# A second run leaves a matching hook in place. A dry run does not
# write one. The wrapper mounts that external git dir so git works
# inside the pre-commit container.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repo="$(realpath "$repo")"
module="${repo}/setup/modules/compute/install-python-dev.sh"
wrapper="${repo}/setup/files/pre-commit/pre-commit"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

export GIT_AUTHOR_NAME=fixture
export GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture
export GIT_COMMITTER_EMAIL=fixture@example.com

real_home="$HOME"
cache_root="${XDG_CACHE_HOME:-${real_home}/.cache}"
home="${work}/home"
dots="${work}/dots"
mkdir -p "${dots}/bashrc.d" "${home}/.config/dot-files"
printf 'dot-files=%s\nmachine-setup=%s\n' "$(realpath "$dots")" "$repo" \
    >"${home}/.config/dot-files/checkouts"
export DOTFILES_HOME="$home"
export DOTFILES_USER="$(id -un)"
export HOME="$home"
export DOTFILES_TEST_SOURCE=1
export PRE_COMMIT_CACHE="${cache_root}/pre-commit-docker"
unset DOTFILES_LIB_LOADED
unset DOTFILES_DRY_RUN

# shellcheck disable=SC1090
. "$module"
# shellcheck disable=SC1090
PRE_COMMIT_TEST_SOURCE=1 . "$wrapper"

git_init() {
    git init -b main "$1" >/dev/null
    git -C "$1" config user.email fixture@example.com
    git -C "$1" config user.name fixture
}

commit_all() {
    git -C "$1" add -A
    git -C "$1" commit -m seed >/dev/null
}

hook_path() {
    local repo_dir="$1" hook_dir
    hook_dir="$(git -C "$repo_dir" rev-parse --git-path hooks)"
    if [[ "$hook_dir" != /* ]]; then
        hook_dir="${repo_dir}/${hook_dir}"
    fi
    printf '%s\n' "${hook_dir}/pre-commit"
}

strip_hook() {
    rm -f "$(hook_path "$1")"
}

assert_hook() {
    local repo_dir="$1" dest
    dest="$(hook_path "$repo_dir")"
    [[ -x "$dest" ]] || fail "missing hook in ${repo_dir} (${dest})"
    cmp -s "$template" "$dest" || fail "hook content differs in ${repo_dir}"
}

assert_git_in_container() {
    local dir="$1" out
    out="$(
        cd "$dir"
        pre_commit_docker_args
        docker run --rm --entrypoint git \
            -u "$(id -u):$(id -g)" \
            "${PRE_COMMIT_DOCKER_ARGS[@]}" \
            "$IMAGE" status -sb
    )" || fail "git status failed in ${dir}"
    printf '%s\n' "$out" | grep -q '^##' || fail "git status in ${dir} was: ${out}"
}

template_body='#!/bin/sh
# fixture-hook
exit 0
'

origin_dots="${work}/origin-dots"
origin_setup="${work}/origin-setup"
origin_images="${work}/origin-images"
lab="${work}/homelab"
other="${work}/other"
standalone_dots="${work}/standalone-dots"
standalone_setup="${work}/standalone-setup"

git_init "$origin_dots"
mkdir -p "${origin_dots}/config/git/template/hooks"
printf '%s\n' "$template_body" >"${origin_dots}/config/git/template/hooks/pre-commit"
chmod 0755 "${origin_dots}/config/git/template/hooks/pre-commit"
commit_all "$origin_dots"

git_init "$origin_setup"
printf 'setup\n' >"${origin_setup}/README"
commit_all "$origin_setup"

git_init "$origin_images"
printf 'images\n' >"${origin_images}/README"
commit_all "$origin_images"

git_init "$lab"
git -C "$lab" config protocol.file.allow always
git -C "$lab" -c protocol.file.allow=always submodule add "$origin_dots" dot-files >/dev/null
git -C "$lab" -c protocol.file.allow=always submodule add "$origin_setup" machine-setup >/dev/null
git -C "$lab" -c protocol.file.allow=always submodule add "$origin_images" images >/dev/null
git -C "$lab" commit -m lab >/dev/null

template="${lab}/dot-files/config/git/template/hooks/pre-commit"
[[ -f "$template" ]] || fail "fixture template missing"

strip_hook "$lab"
strip_hook "${lab}/dot-files"
strip_hook "${lab}/machine-setup"
strip_hook "${lab}/images"
[[ ! -e "$(hook_path "${lab}/machine-setup")" ]] || fail "strip left a submodule hook"

export DOTFILES_ROOT="$(realpath "${lab}/dot-files")"
export MACHINE_SETUP_ROOT="$(realpath "${lab}/machine-setup")"
install_checkout_pre_commit_hooks

assert_hook "$lab"
assert_hook "${lab}/dot-files"
assert_hook "${lab}/machine-setup"
assert_hook "${lab}/images"
[[ -f "${lab}/machine-setup/.git" && ! -d "${lab}/machine-setup/.git" ]] \
    || fail "submodule .git file was replaced"

second="$(install_checkout_pre_commit_hooks)"
[[ -z "$second" ]] || fail "second run logged: ${second}"

images_hook="$(hook_path "${lab}/images")"
rm -f "$images_hook"
export DOTFILES_DRY_RUN=1
dry="$(install_checkout_pre_commit_hooks)"
unset DOTFILES_DRY_RUN
printf '%s\n' "$dry" | grep -F "install pre-commit hook in ${lab}/images" >/dev/null \
    || fail "dry-run did not name the images checkout: ${dry}"
[[ ! -e "$images_hook" ]] || fail "dry-run wrote the images hook"
install_checkout_pre_commit_hooks
assert_hook "${lab}/images"

git -C "${lab}/machine-setup" worktree add -b side "${work}/side" HEAD >/dev/null
[[ "$(hook_path "${work}/side")" == "$(hook_path "${lab}/machine-setup")" ]] \
    || fail "worktree uses a different hooks directory"
assert_hook "${work}/side"

git_init "$other"
other_hook="$(hook_path "$other")"
rm -f "$other_hook"

git_init "$standalone_dots"
mkdir -p "${standalone_dots}/config/git/template/hooks"
printf '%s\n' "$template_body" >"${standalone_dots}/config/git/template/hooks/pre-commit"
chmod 0755 "${standalone_dots}/config/git/template/hooks/pre-commit"
commit_all "$standalone_dots"
git_init "$standalone_setup"
printf 'alone\n' >"${standalone_setup}/README"
commit_all "$standalone_setup"
strip_hook "$standalone_dots"
strip_hook "$standalone_setup"
template="${standalone_dots}/config/git/template/hooks/pre-commit"
export DOTFILES_ROOT="$(realpath "$standalone_dots")"
export MACHINE_SETUP_ROOT="$(realpath "$standalone_setup")"
install_checkout_pre_commit_hooks
assert_hook "$standalone_dots"
assert_hook "$standalone_setup"
[[ ! -e "$other_hook" ]] || fail "unrelated repo received a hook"

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    fail "missing docker image ${IMAGE}"
fi
template="${lab}/dot-files/config/git/template/hooks/pre-commit"
export DOTFILES_ROOT="$(realpath "${lab}/dot-files")"
export MACHINE_SETUP_ROOT="$(realpath "${lab}/machine-setup")"
assert_git_in_container "$lab"
assert_git_in_container "${lab}/machine-setup"
assert_git_in_container "${work}/side"

printf 'pre-commit hooks ok\n'
