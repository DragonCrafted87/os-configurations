#!/usr/bin/env bash
# Shared helpers for setup modules and role scripts.
# Safe to source more than once.
# This is the only import. Pieces live beside this file.

# shellcheck disable=SC2034

if [[ -n "${DOTFILES_LIB_LOADED:-}" ]]; then
    return 0
fi
DOTFILES_LIB_LOADED=1

set -euo pipefail

log() {
    printf '==> %s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

run() {
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        printf 'dry-run: %s\n' "$*"
        return 0
    fi
    "$@"
}

_trim_line() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The running setup tree. A preset SETUP_DIR does not relocate it.
SETUP_DIR="$(cd "${_lib_dir}/.." && pwd)"

DOTFILES_USER="${DOTFILES_USER:-dragon}"
DOTFILES_HOME="${DOTFILES_HOME:-/home/${DOTFILES_USER}}"
DOTFILES_DIR="${DOTFILES_DIR:-${DOTFILES_HOME}/dot-files}"

# Checkout that contains this setup tree. git is asked with -C so a
# module started from $HOME still resolves.
_setup_checkout() {
    local top
    top="$(git -C "$SETUP_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$top" ]]; then
        top="$(cd "${SETUP_DIR}/.." && pwd)"
    fi
    realpath "$top"
}

checkouts_file() {
    printf '%s\n' "${DOTFILES_HOME}/.config/dot-files/checkouts"
}

write_checkouts() {
    local dotfiles="$1" setup_root="$2" file body
    dotfiles="$(realpath "$dotfiles")"
    setup_root="$(realpath "$setup_root")"
    file="$(checkouts_file)"
    mkdir -p -- "$(dirname "$file")"
    body="dot-files=${dotfiles}"$'\n'"machine-setup=${setup_root}"$'\n'
    if [[ -f "$file" ]] && [[ "$(cat "$file")" == "$body" ]]; then
        return 0
    fi
    printf '%s' "$body" >"$file"
}

read_checkouts() {
    local file="$1" line key value
    local got_dot="" got_setup=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(_trim_line "$line")"
        [[ -z "$line" ]] && continue
        [[ "$line" == *=* ]] || die "bad line in ${file}"
        key="$(_trim_line "${line%%=*}")"
        value="$(_trim_line "${line#*=}")"
        case "$key" in
            dot-files) got_dot="$value" ;;
            machine-setup) got_setup="$value" ;;
            *) die "unknown key ${key} in ${file}" ;;
        esac
    done <"$file"
    [[ -n "$got_dot" && -n "$got_setup" ]] || die "missing dot-files or machine-setup in ${file}"
    [[ "$got_dot" == /* && "$got_setup" == /* ]] || die "relative path in ${file}"
    [[ -d "$got_dot" ]] || die "not a directory in ${file}: ${got_dot}"
    [[ -d "$got_setup" ]] || die "not a directory in ${file}: ${got_setup}"
    DOTFILES_ROOT="$(realpath "$got_dot")"
    MACHINE_SETUP_ROOT="$(realpath "$got_setup")"
}

discover_checkouts() {
    local setup_root parent home_dots home_setup
    setup_root="$(_setup_checkout)"
    if [[ -d "${setup_root}/bashrc.d" && -d "${setup_root}/setup" ]]; then
        write_checkouts "$setup_root" "$setup_root"
        return 0
    fi
    parent="$(cd "${setup_root}/.." && pwd)"
    if [[ -d "${parent}/dot-files/bashrc.d" ]]; then
        write_checkouts "${parent}/dot-files" "$setup_root"
        return 0
    fi
    home_dots="${DOTFILES_HOME}/dot-files"
    home_setup="${DOTFILES_HOME}/machine-setup"
    if [[ -d "${home_dots}/bashrc.d" && -f "${home_setup}/setup/role.sh" ]]; then
        write_checkouts "$home_dots" "$home_setup"
        return 0
    fi
    die "cannot find the dot-files and machine-setup checkouts; run dot-files/setup/role.sh"
}

load_checkouts() {
    local file setup_root
    file="$(checkouts_file)"
    if [[ ! -f "$file" ]]; then
        discover_checkouts
    fi
    read_checkouts "$file"
    setup_root="$(_setup_checkout)"
    if [[ "$MACHINE_SETUP_ROOT" != "$setup_root" ]]; then
        die "machine-setup in ${file} is ${MACHINE_SETUP_ROOT}; the running checkout is ${setup_root}"
    fi
    REPO_ROOT="$setup_root"
}

load_checkouts
export REPO_ROOT
export DOTFILES_ROOT
export MACHINE_SETUP_ROOT

require_user() {
    if [[ "$(id -un)" != "${DOTFILES_USER}" ]]; then
        die "run this as ${DOTFILES_USER}, not $(id -un)"
    fi
}

DOTFILES_REPO_URL="${DOTFILES_REPO_URL:-git@github.com:DragonCrafted87/dot-files.git}"
SSH_KEY_PATH="${SSH_KEY_PATH:-${DOTFILES_HOME}/.ssh/id_ed25519}"
DOTFILES_BASHRC="${DOTFILES_BASHRC:-hw_bashrc.sh}"
DOTFILES_TIMEZONE="${DOTFILES_TIMEZONE:-America/Chicago}"
OMP_INSTALL_DIR="${OMP_INSTALL_DIR:-${DOTFILES_HOME}/bin}"
CONFIG_SOURCE_DIR="${DOTFILES_ROOT}/config"
CONFIG_TARGET_DIR="${CONFIG_TARGET_DIR:-${DOTFILES_HOME}/.config}"
SETUP_FILES_DIR="${SETUP_FILES_DIR:-${SETUP_DIR}/files}"
SETUP_VERSIONS_FILE="${SETUP_VERSIONS_FILE:-${SETUP_DIR}/versions.conf}"
COMPILER_ENV_FILE="${DOTFILES_ROOT}/bashrc.d/compiler.bashrc"
# Cross-module flags belong in /tmp, not ~/.config/dot-files.
DOTFILES_QS_RESTART_FLAG="${DOTFILES_QS_RESTART_FLAG:-/tmp/dot-files-$(id -u)-need-qs-restart}"

_dotfiles_source() {
    local name="$1"
    # shellcheck disable=SC1090
    . "${REPO_ROOT}/setup/lib/${name}.sh"
}

_dotfiles_source files
_dotfiles_source packages
_dotfiles_source services
_dotfiles_source desktop
_dotfiles_source roles
# shellcheck disable=SC1091
. "${REPO_ROOT}/setup/subroles.sh"
unset -f _dotfiles_source

load_source_versions
load_compiler_env
