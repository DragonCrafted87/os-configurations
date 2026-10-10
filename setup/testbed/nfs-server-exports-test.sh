#!/usr/bin/env bash
# The nfs-server subrole publishes one export, the castellan line.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="${HERE}/../files/network/nfs-server.exports"
module="${HERE}/../modules/network/install-nfs-server.sh"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ -f "$file" ]] || fail "missing ${file}"
[[ -f "$module" ]] || fail "missing ${module}"

mapfile -t lines <"$file"
[[ "${#lines[@]}" -eq 2 ]] || fail "expected 2 lines, got ${#lines[@]}"
[[ "${lines[0]}" == "# Managed by the nfs-server subrole." ]] || fail "header drifted"
[[ "${lines[1]}" == "/srv/data  192.168.0.0/255.255.240.0(rw,no_root_squash,no_subtree_check)" ]] \
    || fail "export line drifted"
[[ "$(tail -c1 "$file" | wc -l)" -eq 1 ]] || fail "exports file does not end with a newline"

grep -q 'files/network/nfs-server.exports' "$module" || fail "module does not install the exports file"
grep -q 'exportfs -ra' "$module" || fail "module does not reload exports"
grep -q 'die "exportfs -ra failed"' "$module" || fail "exportfs failure is not fatal"

printf '%s\n' "nfs-server exports ok"
