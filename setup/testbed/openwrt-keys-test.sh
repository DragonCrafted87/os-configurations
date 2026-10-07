#!/usr/bin/env bash
# Proves the OpenWrt key updater fails closed and can fetch three ways.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sync_sh="${repo}/setup/files/ssh/openwrt-sync-github-keys.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sys="${work}/sys"
bin="${work}/bin"
mkdir -p "$sys" "$bin"
for tool in mktemp grep chmod mv date cat rm awk; do
    ln -s "$(command -v "$tool")" "${sys}/${tool}"
done

cat >"${bin}/fetch-stub" <<'EOF'
#!/bin/bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -O|-o)
            out="$2"
            shift 2
            ;;
        -O*)
            out="${1#-O}"
            shift
            ;;
        -o*)
            out="${1#-o}"
            shift
            ;;
        *) shift ;;
    esac
done
emit() {
    if [[ -n "$out" ]]; then
        cat >"$out"
    else
        cat
    fi
}
case "${FETCH_MODE:-ok}" in
    ok)
        printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey dragon@test' | emit
        ;;
    extra)
        printf '%s\n' \
            'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey dragon@test' \
            'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKey dragon@other' | emit
        ;;
    empty)
        : >"${out:-/dev/stdout}"
        ;;
    bad) printf '%s\n' 'not-a-key' | emit ;;
    fail) exit 1 ;;
    *) printf 'bad FETCH_MODE %s\n' "${FETCH_MODE}" >&2; exit 1 ;;
esac
EOF
chmod 755 "${bin}/fetch-stub"

auth="${work}/authorized_keys"
keep='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey dragon@test'
other='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQLocalOnly local@router'

reset_auth() {
    printf '%s\n' "$1" >"$auth"
    chmod 600 "$auth"
}

run_sync() {
    local tool="$1"
    rm -f "${bin}/uclient-fetch" "${bin}/curl" "${bin}/wget"
    if [[ -n "$tool" ]]; then
        ln -s fetch-stub "${bin}/${tool}"
    fi
    env PATH="${bin}:${sys}" \
        FETCH_MODE="$2" \
        GITHUB_KEYS_USER=DragonCrafted87 \
        AUTH_KEYS_FILE="$auth" \
        /bin/sh "$sync_sh"
}

expect_kept() {
    local label="$1"
    [[ "$(cat "$auth")" == "$2" ]] || {
        printf '%s replaced the file:\n%s\n' "$label" "$(cat "$auth")" >&2
        exit 1
    }
}

reset_auth "$keep"
set +e
fail_out="$(run_sync uclient-fetch fail 2>&1)"
fail_rc=$?
set -e
[[ "$fail_rc" -ne 0 ]] || {
    printf 'fetch failure should stop:\n%s\n' "$fail_out" >&2
    exit 1
}
expect_kept 'fetch failure' "$keep"

reset_auth "$keep"
set +e
bad_out="$(run_sync uclient-fetch bad 2>&1)"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]]
expect_kept 'non-key body' "$keep"

reset_auth "$keep"
set +e
empty_out="$(run_sync uclient-fetch empty 2>&1)"
empty_rc=$?
set -e
[[ "$empty_rc" -ne 0 ]]
expect_kept 'empty body' "$keep"

reset_auth "$other"
set +e
drop_out="$(run_sync uclient-fetch ok 2>&1)"
drop_rc=$?
set -e
[[ "$drop_rc" -ne 0 ]] || {
    printf 'dropping every current key should stop:\n%s\n' "$drop_out" >&2
    exit 1
}
grep -q 'drop every key' <<<"$drop_out" || {
    printf 'drop guard missing the error:\n%s\n' "$drop_out" >&2
    exit 1
}
expect_kept 'drop guard' "$other"

reset_auth "${keep}
${other}"
ok_out="$(run_sync uclient-fetch extra 2>&1)"
grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAITestKey' "$auth" || {
    printf 'uclient-fetch did not keep the known key:\n%s\n' "$(cat "$auth")" >&2
    exit 1
}
grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAIOtherKey' "$auth" || {
    printf 'uclient-fetch did not write the new key:\n%s\n' "$(cat "$auth")" >&2
    exit 1
}
grep -q '^# synced from https://github.com/DragonCrafted87.keys at ' "$auth" || {
    printf 'missing the sync comment:\n%s\n' "$ok_out" >&2
    exit 1
}
[[ "$(stat -c %a "$auth")" == "600" ]] || {
    printf 'mode is %s\n' "$(stat -c %a "$auth")" >&2
    exit 1
}
if grep -q 'LocalOnly' "$auth"; then
    printf 'a key outside the fetch stayed:\n%s\n' "$(cat "$auth")" >&2
    exit 1
fi

reset_auth "$keep"
run_sync curl ok >/dev/null
grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAITestKey' "$auth" || {
    printf 'curl fallback did not write the key\n' >&2
    exit 1
}

reset_auth "$keep"
run_sync wget ok >/dev/null
grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAITestKey' "$auth" || {
    printf 'wget fallback did not write the key\n' >&2
    exit 1
}

reset_auth "$keep"
set +e
none_out="$(run_sync '' ok 2>&1)"
none_rc=$?
set -e
[[ "$none_rc" -ne 0 ]]
grep -q 'no https fetch tool' <<<"$none_out" || {
    printf 'missing fetch tool was silent:\n%s\n' "$none_out" >&2
    exit 1
}
expect_kept 'no fetch tool' "$keep"

printf 'openwrt key sync ok\n'
