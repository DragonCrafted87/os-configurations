#!/usr/bin/env bash
# The checkouts file names both roots. The shell environment does not.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${HERE}/../.." && pwd)"
lib="${repo}/setup/lib/lib.sh"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

wrong="$(mktemp -d)"
fixture="$(mktemp -d)"
home_a="$(mktemp -d)"
home_b="$(mktemp -d)"
wrong="$(realpath "$wrong")"
fixture="$(realpath "$fixture")"
repo="$(realpath "$repo")"
trap 'rm -rf "$wrong" "$fixture" "$home_a" "$home_b"' EXIT
mkdir -p "${fixture}/config" "${fixture}/bashrc.d"

write_file() {
    local home="$1" setup="$2" dots="$3"
    mkdir -p "${home}/.config/dot-files"
    printf 'dot-files=%s\nmachine-setup=%s\n' "$dots" "$setup" \
        >"${home}/.config/dot-files/checkouts"
}

# File wins over exported roots. machine-setup must be this checkout.
write_file "$home_a" "$repo" "$fixture"
result="$(
    export DOTFILES_HOME="$home_a"
    export DOTFILES_ROOT="$wrong"
    export REPO_ROOT="$wrong"
    unset DOTFILES_LIB_LOADED
    # shellcheck disable=SC1090
    . "$lib"
    printf 'config=%s\n' "$CONFIG_SOURCE_DIR"
    printf 'setup=%s\n' "$SETUP_DIR"
    printf 'dots=%s\n' "$DOTFILES_ROOT"
)"
[[ "$result" == *"config=${fixture}/config"* ]] || fail "config did not come from the file: ${result}"
[[ "$result" == *"setup=${repo}/setup"* ]] || fail "setup dir did not stay with lib.sh: ${result}"
[[ "$result" == *"dots=${fixture}"* ]] || fail "dot-files root followed the environment: ${result}"

# A machine-setup path that is not this checkout is an error.
write_file "$home_b" "$fixture" "$fixture"
set +e
(
    export DOTFILES_HOME="$home_b"
    export DOTFILES_ROOT="$wrong"
    export REPO_ROOT="$wrong"
    unset DOTFILES_LIB_LOADED
    # shellcheck disable=SC1090
    . "$lib"
) >"${home_b}/mismatch.out" 2>"${home_b}/mismatch.err"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "a foreign machine-setup path was accepted"
grep -F "$fixture" "${home_b}/mismatch.err" >/dev/null || fail "mismatch error omitted the file path"
grep -F "$repo" "${home_b}/mismatch.err" >/dev/null || fail "mismatch error omitted the running checkout"

# No file: bashrc.d beside setup, or the homelab sibling, names the
# dot-files checkout. The exported roots are unused.
home_c="$(mktemp -d)"
trap 'rm -rf "$wrong" "$fixture" "$home_a" "$home_b" "$home_c"' EXIT
sibling="$(cd "${repo}/.." && pwd)/dot-files"
if [[ -d "${repo}/bashrc.d" && -d "${repo}/setup" ]]; then
    expect="$repo"
elif [[ -d "${sibling}/bashrc.d" ]]; then
    expect="$(realpath "$sibling")"
else
    fail "no bashrc.d beside setup or in the homelab dot-files checkout"
fi
result="$(
    export DOTFILES_HOME="$home_c"
    export DOTFILES_ROOT="$wrong"
    export REPO_ROOT="$wrong"
    unset DOTFILES_LIB_LOADED
    # shellcheck disable=SC1090
    . "$lib"
    printf 'dots=%s\n' "$DOTFILES_ROOT"
    printf 'compiler=%s\n' "$COMPILER_ENV_FILE"
)"
[[ "$result" == *"dots=${expect}"* ]] || fail "missing file did not use ${expect}: ${result}"
[[ "$result" == *"compiler=${expect}/bashrc.d/compiler.bashrc"* ]] \
    || fail "compiler env did not follow the dot-files checkout: ${result}"
[[ "$result" != *"dots=${wrong}"* ]] || fail "missing file used the exported root"
[[ -f "${home_c}/.config/dot-files/checkouts" ]] || fail "discovery did not write the checkouts file"
grep -F "machine-setup=${repo}" "${home_c}/.config/dot-files/checkouts" >/dev/null \
    || fail "discovery did not record this setup checkout"

printf 'checkouts ok\n'
