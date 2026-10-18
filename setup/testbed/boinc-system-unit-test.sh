#!/usr/bin/env bash
# A system boinc unit must not keep %h. systemd expands that to /root.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
unit="${repo}/setup/files/boinc/boinc-client.service"
installer="${repo}/setup/modules/compute/install-boinc-run.sh"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

grep -q 'unit_text//%h' "$installer" || fail "installer does not replace %h"
grep -q 'RUSTICL_ENABLE=radeonsi,r600' "$unit" || fail "unit lost the OpenCL devices"

home=/home/example
text="$(<"$unit")"
text="${text//%h/${home}}"
printf '%s\n' "$text" | grep -q '%h' && fail "rendered unit still contains %h"
printf '%s\n' "$text" | grep -q "WorkingDirectory=${home}/.local/share/boinc" \
    || fail "working directory was not the account home"
printf '%s\n' "$text" | grep -q "ExecStartPre=/usr/bin/mkdir -p ${home}/.local/share/boinc" \
    || fail "start mkdir was not the account home"
printf '%s\n' "$text" | grep -q "ExecStart=/usr/local/bin/boinc --dir ${home}/.local/share/boinc" \
    || fail "boinc dir was not the account home"

printf '%s\n' "boinc system unit ok"
