#!/usr/bin/env bash
# Replace ~/.ssh/authorized_keys with the published key list. Fails
# closed: a bad or empty fetch leaves the current file.
#
#   KEYS_URL=https://github.com/DragonCrafted87.keys ./sync-github-authorized-keys.sh

set -euo pipefail

DOTFILES_USER="${DOTFILES_USER:-dragon}"
DOTFILES_HOME="${DOTFILES_HOME:-/home/${DOTFILES_USER}}"
auth="${DOTFILES_HOME}/.ssh/authorized_keys"
url="${KEYS_URL:-http://192.168.8.23/authorized_keys}"

mkdir -p "${DOTFILES_HOME}/.ssh"
chmod 700 "${DOTFILES_HOME}/.ssh"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL --max-time 20 "$url" -o "$tmp"; then
    printf 'error: failed to fetch %s\n' "$url" >&2
    exit 1
fi

# Any OpenSSH pubkey: type token, then base64. Covers rsa, ed25519,
# ecdsa-sha2-nistp256/384/521, and security-key variants.
key_re='^[A-Za-z0-9._+-]+(@openssh\.com)? [A-Za-z0-9+/=]+'
if ! grep -qE "$key_re" "$tmp"; then
    printf 'error: %s did not contain any SSH public keys\n' "$url" >&2
    exit 1
fi

{
    printf '# synced from %s at %s\n' "$url" "$(date --iso-8601=seconds)"
    grep -E "$key_re" "$tmp"
} >"${tmp}.out"

install -m 0600 "${tmp}.out" "$auth"
chown "${DOTFILES_USER}:${DOTFILES_USER}" "$auth" 2>/dev/null || true
rm -f "${tmp}.out"
printf 'updated %s from %s\n' "$auth" "$url"
