#!/usr/bin/env bash
# Proves the Valetudo key pusher fails closed and writes over ssh.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sync_sh="${repo}/setup/files/ssh/valetudo-sync-github-keys.sh"
bash_bin="$(command -v bash)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sys="${work}/sys"
bin="${work}/bin"
mkdir -p "$sys" "$bin"
for tool in mktemp grep chmod mv date cat rm awk; do
    ln -s "$(command -v "$tool")" "${sys}/${tool}"
done

cat >"${bin}/curl" <<'EOF'
#!/bin/bash
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)
            out="$2"
            shift 2
            ;;
        -o*)
            out="${1#-o}"
            shift
            ;;
        *) shift ;;
    esac
done
case "${FETCH_MODE:-ok}" in
    ok)
        printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey dragon@test' >"$out"
        ;;
    extra)
        printf '%s\n' \
            'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey dragon@test' \
            'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKey dragon@other' >"$out"
        ;;
    empty) : >"$out" ;;
    bad) printf '%s\n' 'not-a-key' >"$out" ;;
    fail) exit 1 ;;
    *) printf 'bad FETCH_MODE %s\n' "${FETCH_MODE}" >&2; exit 1 ;;
esac
EOF
chmod 755 "${bin}/curl"

cat >"${bin}/ssh" <<'EOF'
#!/bin/bash
cmd="${*: -1}"
if [[ "${SSH_MODE:-ok}" == "fail" ]]; then
    exit 255
fi
printf '%s\n' "$cmd" >>"${SSH_LOG}"
if [[ "$cmd" == *"cat >"* ]]; then
    cat >"$AUTH_KEYS_FILE"
    chmod 600 "$AUTH_KEYS_FILE"
    exit 0
fi
if [[ ! -e "$AUTH_KEYS_FILE" ]]; then
    exit 2
fi
cat "$AUTH_KEYS_FILE"
exit 0
EOF
chmod 755 "${bin}/ssh"

auth="${work}/authorized_keys"
log="${work}/ssh.log"
keep='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey dragon@test'
other='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQLocalOnly local@router'

reset_auth() {
    printf '%s\n' "$1" >"$auth"
    chmod 600 "$auth"
    : >"$log"
}

run_sync() {
    env PATH="${bin}:${sys}" \
        FETCH_MODE="$1" \
        SSH_MODE="${2:-ok}" \
        SSH_LOG="$log" \
        AUTH_KEYS_FILE="$auth" \
        GITHUB_KEYS_USER=DragonCrafted87 \
        VALETUDO_SSH=root@besom-wyvern \
        VALETUDO_AUTH_KEYS="$auth" \
        "${bash_bin}" "$sync_sh"
}

expect_kept() {
    local label="$1"
    [[ "$(cat "$auth")" == "$2" ]] || {
        printf '%s replaced the file:\n%s\n' "$label" "$(cat "$auth")" >&2
        exit 1
    }
}

wrote() {
    grep -q '^umask' "$log"
}

reset_auth "$keep"
set +e
fail_out="$(run_sync fail 2>&1)"
fail_rc=$?
set -e
[[ "$fail_rc" -ne 0 ]]
expect_kept 'fetch failure' "$keep"
wrote && { printf 'fetch failure wrote the file\n' >&2; exit 1; }

reset_auth "$keep"
set +e
bad_out="$(run_sync bad 2>&1)"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]]
grep -q 'did not contain any SSH public keys' <<<"$bad_out"
expect_kept 'non-key body' "$keep"
wrote && { printf 'non-key body wrote the file\n' >&2; exit 1; }

reset_auth "$keep"
set +e
empty_out="$(run_sync empty 2>&1)"
empty_rc=$?
set -e
[[ "$empty_rc" -ne 0 ]]
expect_kept 'empty body' "$keep"

reset_auth "$other"
set +e
drop_out="$(run_sync ok 2>&1)"
drop_rc=$?
set -e
[[ "$drop_rc" -ne 0 ]]
grep -q 'drop every key' <<<"$drop_out"
expect_kept 'drop guard' "$other"
wrote && { printf 'drop guard wrote the file\n' >&2; exit 1; }

reset_auth "$keep"
set +e
down_out="$(run_sync ok fail 2>&1)"
down_rc=$?
set -e
[[ "$down_rc" -ne 0 ]]
grep -q 'failed to read' <<<"$down_out"
expect_kept 'ssh down' "$keep"

reset_auth "${keep}
${other}"
ok_out="$(run_sync extra)"
grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAITestKey' "$auth"
grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAIOtherKey' "$auth"
grep -q '^# synced from https://github.com/DragonCrafted87.keys at ' "$auth"
[[ "$(stat -c %a "$auth")" == "600" ]]
if grep -q 'LocalOnly' "$auth"; then
    printf 'a key outside the fetch stayed:\n%s\n' "$(cat "$auth")" >&2
    exit 1
fi
grep -q 'updated /' <<<"$ok_out"

rm -f "$auth"
: >"$log"
miss_out="$(run_sync ok)"
grep -q 'AAAAC3NzaC1lZDI1NTE5AAAAITestKey' "$auth"
[[ "$(stat -c %a "$auth")" == "600" ]]
grep -q 'updated /' <<<"$miss_out"

rm -f "${bin}/curl"
reset_auth "$keep"
set +e
none_out="$(env PATH="${bin}:${sys}" \
    SSH_LOG="$log" AUTH_KEYS_FILE="$auth" \
    VALETUDO_AUTH_KEYS="$auth" \
    "${bash_bin}" "$sync_sh" 2>&1)"
none_rc=$?
set -e
[[ "$none_rc" -ne 0 ]]
grep -q 'no https fetch tool' <<<"$none_out"
expect_kept 'no curl' "$keep"

printf 'valetudo key sync ok\n'
