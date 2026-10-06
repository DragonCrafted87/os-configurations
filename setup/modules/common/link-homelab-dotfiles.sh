#!/usr/bin/env bash
# On a workstation that already has the homelab parent, ~/dot-files
# becomes a symlink to that parent's dot-files checkout. An htpc or
# server has no such parent, and this module leaves ~/dot-files alone.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

homelab="${DOTFILES_HOME}/git-workspace/homelab"
homelab_dots="${homelab}/dot-files"
homelab_setup="${homelab}/machine-setup"
live="${DOTFILES_HOME}/dot-files"
backup="${DOTFILES_HOME}/dot-files.before-symlink"

if [[ ! -d "$homelab_dots" ]]; then
    exit 0
fi

if [[ -L "$live" ]]; then
    target="$(realpath "$live")"
    want="$(realpath "$homelab_dots")"
    if [[ "$target" == "$want" ]]; then
        exit 0
    fi
    die "${live} is a symlink to ${target}; expected ${want}"
fi

record_homelab() {
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    [[ -d "$homelab_setup" ]] || die "missing ${homelab_setup}"
    write_checkouts "$homelab_dots" "$homelab_setup"
}

if [[ ! -e "$live" ]]; then
    run ln -sfn "$homelab_dots" "$live"
    record_homelab
    exit 0
fi

[[ -d "$live" ]] || die "${live} exists and is not a directory"

report_mismatch() {
    printf 'error: %s and %s do not match\n' "$live" "$homelab_dots" >&2
    printf 'head %s %s\n' "$live" "$(git -C "$live" rev-parse HEAD 2>&1 || true)" >&2
    printf 'head %s %s\n' "$homelab_dots" "$(git -C "$homelab_dots" rev-parse HEAD 2>&1 || true)" >&2
    printf 'status %s\n' "$live" >&2
    git -C "$live" status --porcelain >&2 || true
    printf 'status %s\n' "$homelab_dots" >&2
    git -C "$homelab_dots" status --porcelain >&2 || true
    exit 1
}

live_head="$(git -C "$live" rev-parse HEAD 2>/dev/null || true)"
home_head="$(git -C "$homelab_dots" rev-parse HEAD 2>/dev/null || true)"
live_status="$(git -C "$live" status --porcelain 2>/dev/null || true)"
home_status="$(git -C "$homelab_dots" status --porcelain 2>/dev/null || true)"
if [[ -z "$live_head" || -z "$home_head" || "$live_head" != "$home_head" || -n "$live_status" || -n "$home_status" ]]; then
    report_mismatch
fi

[[ ! -e "$backup" && ! -L "$backup" ]] || die "${backup} already exists"
run mv "$live" "$backup"
run ln -sfn "$homelab_dots" "$live"
record_homelab
