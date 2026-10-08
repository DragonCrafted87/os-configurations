#!/usr/bin/env bash
# Priority mapping for the ntfy desktop command. notify-send is a stub.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo}/setup/files/ntfy/ntfy-desktop-notify"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "${work}/bin" "${work}/home"
cat >"${work}/bin/notify-send" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$NOTIFY_LOG"
EOF
chmod 0755 "${work}/bin/notify-send"

run_one() {
    local priority="$1"
    local expect="$2"
    NOTIFY_LOG="${work}/log" \
        HOME="${work}/home" \
        PATH="${work}/bin:${PATH}" \
        NTFY_TITLE="Pit" \
        NTFY_MESSAGE="ready" \
        NTFY_PRIORITY="$priority" \
        NTFY_ID="msg-${priority}" \
        "$script"
    grep -q -- "-u ${expect}" "${work}/log" || {
        printf 'priority %s wrote: %s\n' "$priority" "$(cat "${work}/log")" >&2
        exit 1
    }
    grep -qx "msg-${priority}" "${work}/home/.local/state/ntfy-workstations.since" || {
        printf 'priority %s did not record the message id\n' "$priority" >&2
        exit 1
    }
}

run_one 2 low
run_one 3 normal
run_one 5 critical
run_one high critical
run_one "" normal

printf 'ntfy-desktop-notify priority map ok\n'
