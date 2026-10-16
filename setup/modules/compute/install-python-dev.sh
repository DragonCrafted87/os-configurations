#!/usr/bin/env bash
# Workstation Python tooling plus a reusable pre-commit container.
# The git init template lives in config/git/template and is linked into
# ~/.config/git by link-user-config. A clone made before that link has
# no hook, and a submodule's .git file is not a hooks directory, so each
# role run copies the template hook into the recorded checkouts, their
# superproject, and each initialized submodule. A linked worktree uses
# that checkout's hooks directory.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

install_pre_commit_hook() {
    local repo="$1" template="$2" hook_dir dest
    hook_dir="$(git -C "$repo" rev-parse --git-path hooks)"
    if [[ "$hook_dir" != /* ]]; then
        hook_dir="${repo}/${hook_dir}"
    fi
    dest="${hook_dir}/pre-commit"
    if [[ -f "$dest" && -x "$dest" ]] && cmp -s "$template" "$dest"; then
        return 0
    fi
    log "install pre-commit hook in ${repo}"
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    mkdir -p "$hook_dir"
    install -m 0755 "$template" "$dest"
}

install_checkout_pre_commit_hooks() {
    local template repo super rel
    local -a queue=()
    local -A seen=()
    local i=0

    enqueue() {
        local path top
        [[ -d "$1" ]] || return 0
        path="$(realpath "$1")"
        git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
        top="$(git -C "$path" rev-parse --show-toplevel)"
        [[ "$top" == "$path" ]] || return 0
        [[ -z "${seen[$path]:-}" ]] || return 0
        seen[$path]=1
        queue+=("$path")
    }

    template="${DOTFILES_ROOT}/config/git/template/hooks/pre-commit"
    [[ -f "$template" ]] || die "missing ${template}"

    enqueue "$DOTFILES_ROOT"
    enqueue "$MACHINE_SETUP_ROOT"
    while [[ "$i" -lt "${#queue[@]}" ]]; do
        repo="${queue[$i]}"
        i=$((i + 1))
        super="$(git -C "$repo" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
        if [[ -n "$super" ]]; then
            enqueue "$super"
        fi
        if [[ -f "${repo}/.gitmodules" ]]; then
            while IFS= read -r rel; do
                [[ -n "$rel" ]] || continue
                enqueue "${repo}/${rel}"
            done < <(git -C "$repo" submodule foreach --quiet 'printf "%s\n" "$sm_path"')
        fi
    done

    for repo in "${queue[@]}"; do
        install_pre_commit_hook "$repo" "$template"
    done
}

# Tests source this file and call the function. A role run executes it.
if [[ "${DOTFILES_TEST_SOURCE:-0}" == "1" ]]; then
    return 0
fi

require_user

WRAPPER="${DOTFILES_HOME}/bin/pre-commit"
IMAGE_NAME="dotfiles-pre-commit"
DOCKERFILE="${SETUP_FILES_DIR}/pre-commit/Dockerfile"
CACHE_DIR="${DOTFILES_HOME}/.cache/pre-commit-docker"

ensure_packages python python-pip docker

if getent group docker >/dev/null 2>&1; then
    if ! id -nG "$DOTFILES_USER" | grep -qw docker; then
        log "add ${DOTFILES_USER} to docker"
        run sudo usermod -aG docker "$DOTFILES_USER"
    fi
fi

if command -v systemctl >/dev/null 2>&1; then
    enable_service docker.service || true
    if [[ "${DOTFILES_DRY_RUN:-0}" != "1" ]]; then
        sudo systemctl start docker.service 2>/dev/null || true
    fi
fi

ensure_dir "${DOTFILES_HOME}/.local"
ensure_dir "${DOTFILES_HOME}/bin"
ensure_dir "$CACHE_DIR"

if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
    log "would pip install --user wheel poetry python-dateutil requests"
else
    log "pip install --user wheel poetry python-dateutil requests"
    python -m pip install --user --upgrade pip wheel
    python -m pip install --user --upgrade poetry python-dateutil requests
fi

[[ -f "$DOCKERFILE" ]] || die "missing ${DOCKERFILE}"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    log "build ${IMAGE_NAME}"
    run docker build -t "$IMAGE_NAME" "$(dirname "$DOCKERFILE")"
else
    warn "docker is not usable yet (group/session?); build ${IMAGE_NAME} after a re-login"
fi

run install -m 0755 "${SETUP_FILES_DIR}/pre-commit/pre-commit" "$WRAPPER"
install_checkout_pre_commit_hooks
