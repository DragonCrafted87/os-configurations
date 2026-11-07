#!/usr/bin/env bash
# Install the authorized_keys sync script and timer, then run it once
# so this box immediately trusts the published key list.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

src="${SETUP_FILES_DIR}/ssh"
ensure_packages curl

if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
    log "install authorized_keys sync and its timer"
    exit 0
fi

sudo install -m 0755 "${src}/sync-github-authorized-keys.sh" /usr/local/bin/sync-github-authorized-keys.sh
sudo install -m 0644 "${src}/sync-github-keys.service" /etc/systemd/system/sync-github-keys.service
sudo install -m 0644 "${src}/sync-github-keys.timer" /etc/systemd/system/sync-github-keys.timer
sudo systemctl daemon-reload
enable_service sync-github-keys.timer
run sudo systemctl start sync-github-keys.timer

if ! sudo -u "${DOTFILES_USER}" /usr/local/bin/sync-github-authorized-keys.sh; then
    warn "authorized_keys sync failed this run; timer will retry"
fi
