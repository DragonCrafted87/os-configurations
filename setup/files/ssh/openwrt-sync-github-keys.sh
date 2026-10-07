#!/bin/sh
# Replace /etc/dropbear/authorized_keys with the keys listed on the GitHub
# account. Fails closed: a bad or empty fetch leaves the current file.
# If the file already has keys and the fetch contains none of them, the
# file stays. That is the case that would remove the only login.
# OpenWrt has ash. The AP has uclient-fetch and no curl.
#
#   GITHUB_KEYS_USER=DragonCrafted87 ./openwrt-sync-github-keys.sh

set -eu

GITHUB_KEYS_USER="${GITHUB_KEYS_USER:-DragonCrafted87}"
auth="${AUTH_KEYS_FILE:-/etc/dropbear/authorized_keys}"
url="https://github.com/${GITHUB_KEYS_USER}.keys"
key_re='^[A-Za-z0-9._+-]+(@openssh\.com)? [A-Za-z0-9+/=]+'

fetch() {
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$1" -T 20 "$2"
        return
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 20 "$2" -o "$1"
        return
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$1" -T 20 "$2"
        return
    fi
    printf 'error: no https fetch tool\n' >&2
    return 1
}

tmp="$(mktemp)"
out="${tmp}.out"
auth_tmp="${auth}.tmp"
trap 'rm -f "$tmp" "$out" "$auth_tmp"' EXIT

if ! fetch "$tmp" "$url"; then
    printf 'error: failed to fetch %s\n' "$url" >&2
    exit 1
fi

if ! grep -qE "$key_re" "$tmp"; then
    printf 'error: %s did not contain any SSH public keys\n' "$url" >&2
    exit 1
fi

overlap=0
if [ -f "$auth" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        blob=$(printf '%s\n' "$line" | awk '{print $2}')
        [ -n "$blob" ] || continue
        if grep -qF "$blob" "$tmp"; then
            overlap=1
            break
        fi
    done <"$auth"
fi
if [ -f "$auth" ] && grep -qE "$key_re" "$auth" && [ "$overlap" -eq 0 ]; then
    printf 'error: fetch would drop every key in %s\n' "$auth" >&2
    exit 1
fi

# BusyBox date has no --iso-8601. GNU date accepts this format too.
{
    printf '# synced from %s at %s\n' "$url" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    grep -E "$key_re" "$tmp"
} >"$out"

umask 077
cat "$out" >"$auth_tmp"
chmod 600 "$auth_tmp"
mv "$auth_tmp" "$auth"
printf 'updated %s from %s\n' "$auth" "$url"
