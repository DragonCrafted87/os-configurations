#!/usr/bin/env bash
# configure-ntp points timesyncd and chrony at mist-dragon.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
module="${repo}/setup/modules/common/configure-ntp.sh"
roles="${repo}/setup/roles.conf"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ -x "$module" ]] || fail "module is not executable"

awk '
    /^\[common\]/ { in_common=1; next }
    /^\[/ { in_common=0 }
    in_common && $0 == "configure-ntp" { found=1 }
    END { exit !found }
' "$roles" || fail "common role is missing configure-ntp"

export DOTFILES_HOME="${work}/home"
unset REPO_ROOT DOTFILES_ROOT DOTFILES_LIB_LOADED
# shellcheck disable=SC1091
. "${repo}/setup/lib/lib.sh"

server="$(ntp_server)"
[[ "$server" == "192.168.0.1" ]] || fail "default server is ${server}"

body="$(timesyncd_ntp_body)"$'\n'
[[ "$body" == $'[Time]\nNTP=192.168.0.1\n' ]] || fail "timesyncd body is wrong"

pool="${work}/chrony.conf"
cat >"$pool" <<'EOF'
# Use public servers from the pool.ntp.org project.
server 0.openmandriva.pool.ntp.org iburst
server 1.openmandriva.pool.ntp.org iburst
pool 2.openmandriva.pool.ntp.org iburst

driftfile /var/lib/chrony/drift
EOF

CHRONY_CONF="$pool" ensure_chrony_ntp
grep -qx 'server 192.168.0.1 iburst' "$pool" || fail "chrony server was not replaced"
grep -q 'driftfile /var/lib/chrony/drift' "$pool" || fail "chrony lost its driftfile"
grep -E -q '^(server|pool) .*openmandriva' "$pool" && fail "pool server remained"
before="$(cat "$pool")"
CHRONY_CONF="$pool" ensure_chrony_ntp
[[ "$(cat "$pool")" == "$before" ]] || fail "second chrony run changed the file"

empty="${work}/empty.conf"
printf 'makestep 10 3\n' >"$empty"
CHRONY_CONF="$empty" ensure_chrony_ntp
[[ "$(head -n 1 "$empty")" == "server 192.168.0.1 iburst" ]] || fail "empty source list was not filled"
grep -qx 'makestep 10 3' "$empty" || fail "makestep line was dropped"

dropin="${work}/mist-dragon.conf"
TIMESYNCD_DROPIN="$dropin" ensure_timesyncd_ntp
cmp -s "$dropin" <(printf '[Time]\nNTP=192.168.0.1\n') || fail "timesyncd drop-in mismatch"
TIMESYNCD_DROPIN="$dropin" ensure_timesyncd_ntp
cmp -s "$dropin" <(printf '[Time]\nNTP=192.168.0.1\n') || fail "second timesyncd run changed the drop-in"

dry="${work}/dry.conf"
printf 'server 0.openmandriva.pool.ntp.org iburst\n' >"$dry"
dry_out="$(DOTFILES_DRY_RUN=1 CHRONY_CONF="$dry" ensure_chrony_ntp 2>&1)"
grep -q "ntp ${dry}" <<<"$dry_out" || fail "dry-run did not name the chrony file: ${dry_out}"
grep -qx 'server 0.openmandriva.pool.ntp.org iburst' "$dry" || fail "dry-run wrote the chrony file"

bad_err="${work}/bad-server.err"
set +e
(
    DOTFILES_NTP_SERVER='192.168.0.1 extra'
    ntp_server
) >"${work}/bad-server.out" 2>"$bad_err"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]] || fail "bad server was accepted"
grep -q 'bad DOTFILES_NTP_SERVER' "$bad_err" || fail "bad server died without the error"

printf '%s\n' "ntp mist-dragon ok"
