#!/usr/bin/env bash
# On a workstation that already has the homelab parent, ~/dot-files
# and ~/machine-setup become symlinks to that parent's checkouts.
# An htpc or server has no such parent, and this module leaves both
# paths alone.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

homelab="${DOTFILES_HOME}/git-workspace/homelab"
homelab_dots="${homelab}/dot-files"
homelab_setup="${homelab}/machine-setup"
live_dots="${DOTFILES_HOME}/dot-files"
live_setup="${DOTFILES_HOME}/machine-setup"
backup_dots="${DOTFILES_HOME}/dot-files.before-symlink"
backup_setup="${DOTFILES_HOME}/machine-setup.before-symlink"

if [[ ! -d "$homelab_dots" ]]; then
    exit 0
fi

# Writes linked, absent, or replace into the named variable.
# A mismatch exits before either home path is moved.
classify_link() {
    local live="$1"
    local want="$2"
    local backup="$3"
    local dest="$4"
    local target want_real
    local live_head home_head live_status home_status

    if [[ -L "$live" ]]; then
        target="$(realpath "$live")"
        want_real="$(realpath "$want")"
        if [[ "$target" == "$want_real" ]]; then
            printf -v "$dest" '%s' linked
            return 0
        fi
        die "${live} is a symlink to ${target}; expected ${want_real}"
    fi

    if [[ ! -e "$live" ]]; then
        printf -v "$dest" '%s' absent
        return 0
    fi

    [[ -d "$live" ]] || die "${live} exists and is not a directory"

    live_head="$(git -C "$live" rev-parse HEAD 2>/dev/null || true)"
    home_head="$(git -C "$want" rev-parse HEAD 2>/dev/null || true)"
    live_status="$(git -C "$live" status --porcelain 2>/dev/null || true)"
    home_status="$(git -C "$want" status --porcelain 2>/dev/null || true)"
    if [[ -z "$live_head" || -z "$home_head" || "$live_head" != "$home_head" || -n "$live_status" || -n "$home_status" ]]; then
        printf 'error: %s and %s do not match\n' "$live" "$want" >&2
        printf 'head %s %s\n' "$live" "$(git -C "$live" rev-parse HEAD 2>&1 || true)" >&2
        printf 'head %s %s\n' "$want" "$(git -C "$want" rev-parse HEAD 2>&1 || true)" >&2
        printf 'status %s\n' "$live" >&2
        git -C "$live" status --porcelain >&2 || true
        printf 'status %s\n' "$want" >&2
        git -C "$want" status --porcelain >&2 || true
        exit 1
    fi

    [[ ! -e "$backup" && ! -L "$backup" ]] || die "${backup} already exists"
    printf -v "$dest" '%s' replace
}

apply_link() {
    local action="$1"
    local live="$2"
    local want="$3"
    local backup="$4"
    case "$action" in
        linked) ;;
        absent)
            run ln -sfn "$want" "$live"
            ;;
        replace)
            run mv "$live" "$backup"
            run ln -sfn "$want" "$live"
            ;;
        *)
            die "unknown link action ${action}"
            ;;
    esac
}

record_homelab() {
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    [[ -d "$homelab_setup" ]] || die "missing ${homelab_setup}"
    write_checkouts "$homelab_dots" "$homelab_setup"
}

dots_action=""
setup_action=""
classify_link "$live_dots" "$homelab_dots" "$backup_dots" dots_action
if [[ ! -d "$homelab_setup" ]]; then
    if [[ "$dots_action" != "linked" ]]; then
        die "missing ${homelab_setup}"
    fi
    apply_link "$dots_action" "$live_dots" "$homelab_dots" "$backup_dots"
    exit 0
fi
classify_link "$live_setup" "$homelab_setup" "$backup_setup" setup_action

apply_link "$dots_action" "$live_dots" "$homelab_dots" "$backup_dots"
apply_link "$setup_action" "$live_setup" "$homelab_setup" "$backup_setup"
if [[ "$dots_action" != "linked" || "$setup_action" != "linked" ]]; then
    record_homelab
fi
