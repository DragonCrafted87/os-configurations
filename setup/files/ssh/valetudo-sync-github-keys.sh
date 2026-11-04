#!/usr/bin/env bash
# Fetch the GitHub keys on this machine and install them on a Valetudo
# robot. The robot cannot reach GitHub. Dropbear reads
# /oem/authorized_keys (dropbear -D /oem). Fails closed: a bad fetch,
# an empty fetch, a failed read, or a fetch that contains none of the
# keys already on the robot leaves that file alone.
#
#   GITHUB_KEYS_USER=DragonCrafted87 VALETUDO_SSH=root@besom-wyvern ./valetudo-sync-github-keys.sh

set -euo pipefail

GITHUB_KEYS_USER="${GITHUB_KEYS_USER:-DragonCrafted87}"
TARGET="${VALETUDO_SSH:-root@besom-wyvern}"
REMOTE_AUTH="${VALETUDO_AUTH_KEYS:-/oem/authorized_keys}"
url="https://github.com/${GITHUB_KEYS_USER}.keys"
key_re='^[A-Za-z0-9._+-]+(@openssh\.com)? [A-Za-z0-9+/=]+'

if ! command -v curl >/dev/null 2>&1; then
    printf 'error: no https fetch tool\n' >&2
    exit 1
fi
if ! command -v ssh >/dev/null 2>&1; then
    printf 'error: no ssh\n' >&2
    exit 1
fi

tmp="$(mktemp)"
out="${tmp}.out"
trap 'rm -f "$tmp" "$out"' EXIT

if ! curl -fsSL --max-time 20 "$url" -o "$tmp"; then
    printf 'error: failed to fetch %s\n' "$url" >&2
    exit 1
fi
if ! grep -qE "$key_re" "$tmp"; then
    printf 'error: %s did not contain any SSH public keys\n' "$url" >&2
    exit 1
fi

probe="if [ -f '${REMOTE_AUTH}' ]; then cat '${REMOTE_AUTH}'; exit \$?; fi; exit 2"
set +e
remote_body="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "$probe" 2>/dev/null)"
remote_rc=$?
set -e
if [[ "$remote_rc" -eq 2 ]]; then
    remote_body=""
elif [[ "$remote_rc" -ne 0 ]]; then
    printf 'error: failed to read %s on %s\n' "$REMOTE_AUTH" "$TARGET" >&2
    exit 1
fi

overlap=0
if [[ -n "$remote_body" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        blob="$(printf '%s\n' "$line" | awk '{print $2}')"
        [[ -n "$blob" ]] || continue
        if grep -qF "$blob" "$tmp"; then
            overlap=1
            break
        fi
    done <<<"$remote_body"
fi
if [[ "$remote_rc" -eq 0 ]] && grep -qE "$key_re" <<<"$remote_body" && [[ "$overlap" -eq 0 ]]; then
    printf 'error: fetch would drop every key in %s on %s\n' "$REMOTE_AUTH" "$TARGET" >&2
    exit 1
fi

{
    printf '# synced from %s at %s\n' "$url" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    grep -E "$key_re" "$tmp"
} >"$out"

install_cmd="umask 077; cat > '${REMOTE_AUTH}.tmp' && chmod 600 '${REMOTE_AUTH}.tmp' && mv '${REMOTE_AUTH}.tmp' '${REMOTE_AUTH}'"
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "$install_cmd" <"$out"; then
    printf 'error: failed to install %s on %s\n' "$REMOTE_AUTH" "$TARGET" >&2
    exit 1
fi
printf 'updated %s on %s from %s\n' "$REMOTE_AUTH" "$TARGET" "$url"
