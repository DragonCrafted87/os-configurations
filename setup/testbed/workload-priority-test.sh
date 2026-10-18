#!/usr/bin/env bash
# BOINC is a system unit, and the workstation helper only changes weights.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unit="${repo}/setup/files/boinc/boinc-client.service"
helper="${repo}/setup/files/k3s/workload-priority.sh"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

grep -q 'Slice=boinc.slice' "$unit" || fail "boinc unit is not in boinc.slice"
grep -q 'User=dragon' "$unit" || fail "boinc unit has no user"
grep -q 'systemctl stop' "$helper" && fail "helper stops a unit"
grep -q 'CPUWeight=20' "$helper" || fail "helper missed the active k3s weight"
grep -q 'CPUWeight=1' "$helper" || fail "helper missed the active boinc weight"
grep -q 'IOWeight=50' "$helper" || fail "helper missed the idle k3s IO weight"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'workstation\n' >"${work}/role"
cat >"${work}/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${LOG}"
exit 0
EOF
chmod 0755 "${work}/systemctl"

LOG="${work}/active.log" PATH="${work}:${PATH}" HOME="${work}" \
    DOTFILES_ROLE_FILE="${work}/role" \
    "${helper}" active
grep -q 'set-property k3s.slice CPUWeight=20 IOWeight=20' "${work}/active.log" \
    || fail "active did not set the k3s weight"
grep -q 'set-property boinc.slice CPUWeight=1 IOWeight=1' "${work}/active.log" \
    || fail "active did not set the boinc weight"
grep -q 'stop' "${work}/active.log" && fail "active log contains stop"

LOG="${work}/idle.log" PATH="${work}:${PATH}" HOME="${work}" \
    DOTFILES_ROLE_FILE="${work}/role" \
    "${helper}" idle
grep -q 'set-property k3s.slice CPUWeight=100 IOWeight=50' "${work}/idle.log" \
    || fail "idle did not restore the k3s weight"
grep -q 'set-property boinc.slice CPUWeight=10 IOWeight=10' "${work}/idle.log" \
    || fail "idle did not restore the boinc weight"

printf '%s\n' "workload priority ok"
