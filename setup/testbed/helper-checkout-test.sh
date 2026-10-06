#!/usr/bin/env bash
# The dot-files helper checks out machine-setup for the saved role.
# Clone URLs are local repositories. GitHub is not contacted.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
real_setup="$(cd "${HERE}/../.." && pwd)"
helper="$(cd "${real_setup}/../dot-files/setup" && pwd)/role.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[[ -f "$helper" ]] || {
    printf 'missing helper %s\n' "$helper" >&2
    exit 1
}

export GIT_AUTHOR_NAME=fixture
export GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture
export GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=protocol.file.allow
export GIT_CONFIG_VALUE_0=always

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

commit_tree() {
    local dir="$1" message="$2"
    git -C "$dir" add -A
    git -C "$dir" commit -m "$message" >/dev/null
}

images="${work}/images-origin"
setup_origin="${work}/setup-origin"
lab_origin="${work}/homelab-origin"
git init -b main "$images" >/dev/null
printf 'marker\n' >"${images}/marker"
commit_tree "$images" 'images'

mkdir -p "$setup_origin"
cp -a "${real_setup}/setup" "${setup_origin}/setup"
git init -b main "$setup_origin" >/dev/null
commit_tree "$setup_origin" 'setup'

git init -b main "$lab_origin" >/dev/null
git -C "$lab_origin" submodule add "$images" images >/dev/null
git -C "$lab_origin" submodule add "$setup_origin" machine-setup >/dev/null
commit_tree "$lab_origin" 'homelab'

bindir="${work}/bin"
log="${work}/git.log"
mkdir -p "$bindir"
cat >"${bindir}/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> '${log}'
exec /usr/bin/git "\$@"
EOF
chmod 755 "${bindir}/git"

empty="${work}/empty-root"
mkdir -p "$empty"

run_helper() {
    local home="$1"
    shift
    : >"$log"
    local err="${home}/helper.err"
    local rc=0
    set +e
    PATH="${bindir}:${PATH}" \
        HOME="$home" \
        DOTFILES_HOME="$home" \
        DOTFILES_ROOT="$empty" \
        HOMELAB_REPO_URL="$lab_origin" \
        MACHINE_SETUP_REPO_URL="$setup_origin" \
        bash "$helper" "$@" >"${home}/helper.out" 2>"$err"
    rc=$?
    set -e
    printf '%s\n' "$rc"
}

expect_usage() {
    local home="$1" rc="$2"
    [[ "$rc" -eq 1 ]] || fail "helper exit ${rc}, expected 1 ($(cat "${home}/helper.err"))"
    grep -F 'usage:' "${home}/helper.err" >/dev/null \
        || fail "usage missing: $(cat "${home}/helper.err")"
}

new_home() {
    local home="$1"
    mkdir -p "${home}/.config/dot-files"
    printf '%s\n' "$2" >"${home}/.config/dot-files/role"
}

# No saved role and no role argument.
blank="${work}/home-blank"
mkdir -p "$blank"
rc="$(run_helper "$blank")"
[[ "$rc" -eq 1 ]] || fail "missing role exited ${rc}"
grep -F 'no role saved; pass workstation, htpc, or server once' \
    "${blank}/helper.err" >/dev/null \
    || fail "missing-role message: $(cat "${blank}/helper.err")"
[[ ! -e "${blank}/git-workspace/homelab" ]] || fail "missing role cloned homelab"
[[ ! -e "${blank}/machine-setup" ]] || fail "missing role cloned machine-setup"

# Server clones the public checkout and does not create the private parent.
server="${work}/home-server"
new_home "$server" server
rc="$(run_helper "$server" --help)"
expect_usage "$server" "$rc"
[[ -f "${server}/machine-setup/setup/role.sh" ]] || fail "server clone has no role.sh"
[[ ! -e "${server}/git-workspace/homelab" ]] || fail "server clone created homelab"
grep -E '(^| )clone ' "$log" >/dev/null || fail "server run did not clone"
server_clones="$(grep -cE '(^| )clone ' "$log" || true)"
rc="$(run_helper "$server" --help)"
expect_usage "$server" "$rc"
second="$(grep -cE '(^| )clone ' "$log" || true)"
[[ "$second" -eq 0 ]] || fail "second server run cloned ${second} time(s); first was ${server_clones}"
grep -F "dot-files=$(realpath "$(dirname "$(dirname "$helper")")")" \
    "${server}/.config/dot-files/checkouts" >/dev/null \
    || fail "server checkouts file did not record the helper repository"
grep -F "machine-setup=$(realpath "${server}/machine-setup")" \
    "${server}/.config/dot-files/checkouts" >/dev/null \
    || fail "server checkouts file did not record ~/machine-setup"
grep -F "$empty" "${server}/.config/dot-files/checkouts" >/dev/null \
    && fail "checkouts file followed DOTFILES_ROOT"

# A new workstation parent initializes every submodule.
fresh="${work}/home-fresh"
new_home "$fresh" workstation
rc="$(run_helper "$fresh" --help)"
expect_usage "$fresh" "$rc"
[[ -f "${fresh}/git-workspace/homelab/machine-setup/setup/role.sh" ]] \
    || fail "new homelab left machine-setup uninitialized"
[[ -f "${fresh}/git-workspace/homelab/images/marker" ]] \
    || fail "new homelab left the other submodule uninitialized"
grep -E '(^| )submodule update --init$' "$log" >/dev/null \
    || fail "new homelab did not init every submodule: $(cat "$log")"
if grep -E '(^| )submodule update --init [^ ]' "$log" >/dev/null; then
    fail "new homelab init named a submodule: $(cat "$log")"
fi
[[ ! -e "${fresh}/machine-setup" ]] || fail "workstation clone created ~/machine-setup"
rc="$(run_helper "$fresh" --help)"
expect_usage "$fresh" "$rc"
if grep -E '(^| )clone |submodule update' "$log" >/dev/null; then
    fail "second workstation run cloned again: $(cat "$log")"
fi

# An existing parent gains only machine-setup.
existing="${work}/home-existing"
new_home "$existing" workstation
mkdir -p "${existing}/git-workspace"
/usr/bin/git clone "$lab_origin" "${existing}/git-workspace/homelab" >/dev/null
rc="$(run_helper "$existing" --help)"
expect_usage "$existing" "$rc"
[[ -f "${existing}/git-workspace/homelab/machine-setup/setup/role.sh" ]] \
    || fail "existing homelab did not gain machine-setup"
[[ ! -e "${existing}/git-workspace/homelab/images/marker" ]] \
    || fail "existing homelab initialized the other submodule"
grep -F 'submodule update --init machine-setup' "$log" >/dev/null \
    || fail "existing homelab did not init only machine-setup: $(cat "$log")"
if grep -E '(^| )submodule update --init$' "$log" >/dev/null; then
    fail "existing homelab initialized every submodule: $(cat "$log")"
fi

printf 'helper checkout ok\n'
