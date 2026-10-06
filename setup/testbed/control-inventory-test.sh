#!/usr/bin/env bash
# Parser cases for the hardware-control inventory. Stdlib only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${HERE}/../.." && pwd)"
parser="${repo}/setup/control/inventory.py"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ -f "$parser" ]] || fail "missing ${parser}"

python3 - "$parser" <<'PY'
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("control_inventory", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

example = """
# a comment
[runewyrm]
user=dragon
host=runewyrm.stealthdragonland.net
status=in
note=workstation, subrole gaming is saved on the machine

[calligraphy-wyrm]
user=dragon
host=192.168.1.100
status=out
note=Windows. SMB and RDP answer. SSH does not.
"""
hosts = mod.parse_inventory(example)
if [h.name for h in hosts] != ["runewyrm", "calligraphy-wyrm"]:
    raise SystemExit(f"example names: {hosts}")
if hosts[0].status != "in" or hosts[1].status != "out":
    raise SystemExit("example status")
if "SSH does not" not in hosts[1].note:
    raise SystemExit(f"note dropped: {hosts[1].note}")

def expect(text, needle):
    try:
        mod.parse_inventory(text)
    except mod.InventoryError as err:
        message = str(err)
        if needle not in message:
            raise SystemExit(f"error {message!r} did not name {needle!r}")
        return
    raise SystemExit(f"accepted bad inventory, wanted {needle!r}")

expect("""
[partial]
user=dragon
host=example.invalid
""", "partial: missing status")

expect("""
[partial]
host=example.invalid
status=in
""", "partial: missing user")

expect("""
[partial]
user=dragon
status=in
""", "partial: missing host")

expect("""
[bad-status]
user=dragon
host=example.invalid
status=maybe
""", "bad-status: status")

expect("""
[bad-host]
user=dragon
host=../box
status=in
""", "bad-host: host")

expect("""
[bad-host]
user=dragon
host=box/name
status=in
""", "bad-host: host")

expect("""
[bad-host]
user=dragon
host=has space
status=in
""", "bad-host: host")

expect("""
[same]
user=dragon
host=one.example
status=in

[same]
user=dragon
host=two.example
status=out
""", "duplicate section same")

print("inventory ok")
PY
