#!/usr/bin/env bash
# Brave repo + package. Used by workstation, laptop, and htpc.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

brave_repo_body() {
    cat <<'EOF'
[brave-browser]
name=Brave Browser
baseurl=https://pulp.stealthdragonland.net/pulp/content/brave/x86_64/
enabled=1
gpgcheck=1
gpgkey=https://brave-browser-rpm-release.s3.brave.com/brave-core.asc
EOF
}

write_brave_repo() {
    local dest="$1"
    local body tmp

    body="$(brave_repo_body)"
    if [[ -f "$dest" ]] && [[ "$(cat "$dest")" == "$body" ]]; then
        return 0
    fi
    log "write ${dest}"
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    tmp="$(mktemp)"
    printf '%s' "$body" >"$tmp"
    if [[ "$dest" == /etc/* ]]; then
        sudo install -m 0644 "$tmp" "$dest"
    else
        install -m 0644 "$tmp" "$dest"
    fi
    rm -f "$tmp"
}

# Tests source this file and call the functions.
if [[ "${DOTFILES_TEST_SOURCE:-0}" == "1" ]]; then
    return 0
fi

require_user

dest="/etc/yum.repos.d/brave-browser.repo"
if [[ ! -f "$dest" ]]; then
    log "add Brave repo"
    if [[ "${DOTFILES_DRY_RUN:-0}" != "1" ]]; then
        sudo rpm --import https://brave-browser-rpm-release.s3.brave.com/brave-core.asc
    fi
fi
write_brave_repo "$dest"

ensure_packages \
    brave-browser \
    qt5-qtwayland
