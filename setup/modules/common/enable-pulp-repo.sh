#!/usr/bin/env bash
# Point dnf at the homelab Pulp RPM distribution. The packages in that
# distribution are unsigned. skip_if_unavailable keeps later dnf installs
# moving when Pulp does not answer.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

pulp_repo_body() {
    cat <<'EOF'
[homelab]
name=Homelab Pulp
baseurl=https://pulp.stealthdragonland.net/pulp/content/homelab/
enabled=1
gpgcheck=0
skip_if_unavailable=1
EOF
}

write_pulp_repo() {
    local dest="$1"
    local body tmp

    body="$(pulp_repo_body)"
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

# Tests source this file and call the functions. A role run writes the
# repo file under /etc.
if [[ "${DOTFILES_TEST_SOURCE:-0}" == "1" ]]; then
    return 0
fi

require_user
write_pulp_repo "${PULP_REPO_DEST:-/etc/yum.repos.d/homelab-pulp.repo}"
