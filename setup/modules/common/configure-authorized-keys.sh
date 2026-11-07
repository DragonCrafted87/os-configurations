#!/usr/bin/env bash
# Install the GitHub authorized_keys sync script and timer, then run
# it once so this box immediately trusts every key on the account.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

src="${SETUP_FILES_DIR}/ssh"
ensure_packages curl

if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
    log "install GitHub authorized_keys sync and the besom-wyvern push, with timers"
    exit 0
fi

sudo install -m 0755 "${src}/sync-github-authorized-keys.sh" /usr/local/bin/sync-github-authorized-keys.sh
sudo install -m 0755 "${src}/valetudo-sync-github-keys.sh" /usr/local/bin/valetudo-sync-github-keys.sh
sudo install -m 0644 "${src}/sync-github-keys.service" /etc/systemd/system/sync-github-keys.service
sudo install -m 0644 "${src}/sync-github-keys.timer" /etc/systemd/system/sync-github-keys.timer
sudo install -m 0644 "${src}/sync-valetudo-keys.service" /etc/systemd/system/sync-valetudo-keys.service
sudo install -m 0644 "${src}/sync-valetudo-keys.timer" /etc/systemd/system/sync-valetudo-keys.timer
sudo systemctl daemon-reload
enable_service sync-github-keys.timer
enable_service sync-valetudo-keys.timer
run sudo systemctl start sync-github-keys.timer
run sudo systemctl start sync-valetudo-keys.timer

if ! sudo -u "${DOTFILES_USER}" GITHUB_KEYS_USER="${GITHUB_KEYS_USER:-DragonCrafted87}" \
    /usr/local/bin/sync-github-authorized-keys.sh; then
    warn "GitHub key sync failed this run; timer will retry"
fi
if ! sudo -u "${DOTFILES_USER}" GITHUB_KEYS_USER="${GITHUB_KEYS_USER:-DragonCrafted87}" \
    /usr/local/bin/valetudo-sync-github-keys.sh; then
    warn "besom-wyvern key push failed this run; timer will retry"
fi
