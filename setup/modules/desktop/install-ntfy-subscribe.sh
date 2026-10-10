#!/usr/bin/env bash
# Workstation subscriber. client.yml is a secret; transfer-secrets.sh
# copies it. Without that file the unit stays installed and does not start.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

version="2.29.0"
sha256="7862bcb9bc422d9f442fffa72b6393386475f880079edd0978a5d31d3307314e"
url="https://github.com/binwiederhier/ntfy/releases/download/v${version}/ntfy_${version}_linux_amd64.tar.gz"
src="${SETUP_FILES_DIR}/ntfy"

[[ "$(uname -m)" == "x86_64" ]] || die "ntfy client package is pinned for x86_64"

if ! command -v notify-send >/dev/null 2>&1; then
    ensure_packages libnotify
fi

install_client() {
    local current=""
    if [[ -x /usr/local/bin/ntfy ]]; then
        current="$(/usr/local/bin/ntfy --version 2>/dev/null || /usr/local/bin/ntfy version 2>/dev/null || true)"
    fi
    if [[ "$current" == *"${version}"* ]]; then
        return 0
    fi
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        log "dry-run: install ntfy ${version} to /usr/local/bin/ntfy"
        return 0
    fi
    local tmp archive
    tmp="$(mktemp -d)"
    archive="${tmp}/ntfy.tar.gz"
    log "download ntfy ${version}"
    curl -fsSL --max-time 60 -o "$archive" "$url"
    echo "${sha256}  ${archive}" | sha256sum -c -
    tar -xzf "$archive" -C "$tmp"
    run sudo install -m 0755 "${tmp}/ntfy_${version}_linux_amd64/ntfy" /usr/local/bin/ntfy
    rm -rf "$tmp"
}

install_client

ensure_dir "${DOTFILES_HOME}/bin"
ensure_dir "${DOTFILES_HOME}/.config/systemd/user"
run install -m 0755 "${src}/ntfy-desktop-notify" "${DOTFILES_HOME}/bin/ntfy-desktop-notify"
run install -m 0755 "${src}/ntfy-workstations" "${DOTFILES_HOME}/bin/ntfy-workstations"
run install -m 0644 "${src}/ntfy-workstations.service" \
    "${DOTFILES_HOME}/.config/systemd/user/ntfy-workstations.service"

if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
    exit 0
fi

systemctl --user daemon-reload
systemctl --user enable ntfy-workstations.service

if [[ ! -f "${DOTFILES_HOME}/.config/ntfy/client.yml" ]]; then
    warn "no ${DOTFILES_HOME}/.config/ntfy/client.yml yet"
    warn "run the haos role, then transfer-secrets.sh, then this module again"
    exit 0
fi

if systemctl --user is-active --quiet graphical-session.target 2>/dev/null \
    || systemctl --user is-active --quiet workstation-session.target 2>/dev/null; then
    systemctl --user restart ntfy-workstations.service
    log "ntfy subscriber restarted"
else
    log "ntfy subscriber enabled; it starts with the workstation session"
fi
