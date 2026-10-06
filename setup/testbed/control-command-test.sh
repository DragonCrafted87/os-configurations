#!/usr/bin/env bash
# Remote steps for the hardware-control walk. No Fabric, no git, no SSH.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${HERE}/../.." && pwd)"
cli="${repo}/setup/control/fabric.py"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ -f "$cli" ]] || fail "missing ${cli}"

python3 - "$cli" <<'PY'
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("control_fabric", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

if "fabric" in sys.modules and hasattr(sys.modules["fabric"], "Connection"):
    raise SystemExit("importing the controller loaded the Fabric package")

DOT = "/tmp/control-dots"
SETUP = "/tmp/control-setup"
PULL_DOT = f"git -C {DOT} pull --ff-only"
PULL_SETUP = f"git -C {SETUP} pull --ff-only"
ROLE = "~/dot-files/setup/role.sh"

def clean(path):
    return mod.CheckoutFacts(path)

def probe():
    return mod.Probe(None, clean(DOT), clean(SETUP), False)

apply = mod.plan_actions("apply", probe())
if apply.error:
    raise SystemExit(apply.error)
if apply.preview:
    raise SystemExit(f"apply preview should be empty: {apply.preview}")
if apply.commands != [PULL_DOT, PULL_SETUP, ROLE]:
    raise SystemExit(f"apply commands: {apply.commands}")

dry = mod.plan_actions("dry-run", probe())
if dry.commands != [f"{ROLE} --dry-run"]:
    raise SystemExit(f"dry-run commands: {dry.commands}")
if dry.preview != [PULL_DOT, PULL_SETUP]:
    raise SystemExit(f"dry-run preview: {dry.preview}")
if any("pull" in command for command in dry.commands):
    raise SystemExit("dry-run would run a pull")

def stops(facts_dot, facts_setup, helper_missing, needle):
    planned = mod.plan_actions(
        "apply",
        mod.Probe(None, facts_dot, facts_setup, helper_missing),
    )
    if planned.commands or planned.preview:
        raise SystemExit(f"planned work despite {needle}: {planned.commands}")
    if not planned.error or needle not in planned.error:
        raise SystemExit(f"error {planned.error!r} did not name {needle!r}")

stops(mod.CheckoutFacts(DOT, porcelain=" M README\n"), clean(SETUP), False, DOT)
stops(clean(DOT), mod.CheckoutFacts(SETUP, porcelain="?? x\n"), False, SETUP)
stops(mod.CheckoutFacts(DOT, detached=True), clean(SETUP), False, DOT)
stops(mod.CheckoutFacts(SETUP, missing=True, work_tree=False), clean(DOT), False, SETUP)
stops(clean(DOT), clean(SETUP), True, ROLE)

class Record:
    def __init__(self, name, host, status):
        self.name = name
        self.host = host
        self.status = status

records = [
    Record("runewyrm", "runewyrm.stealthdragonland.net", "in"),
    Record("roost-drake", "roost-drake.stealthdragonland.net", "in"),
    Record("calligraphy-wyrm", "192.168.1.100", "out"),
]
walk = mod.hosts_for_walk(records, [], "runewyrm", False)
if [item.name for item in walk] != ["roost-drake"]:
    raise SystemExit(f"local host was not omitted: {[item.name for item in walk]}")
included = mod.hosts_for_walk(records, [], "runewyrm", True)
if [item.name for item in included] != ["runewyrm", "roost-drake"]:
    raise SystemExit(f"--include-self dropped a host: {[item.name for item in included]}")

def rejects(requested, needle):
    try:
        mod.hosts_for_walk(records, requested, "runewyrm", False)
    except mod.WalkError as err:
        if needle not in str(err):
            raise SystemExit(f"error {err} did not name {needle!r}")
        return
    raise SystemExit(f"accepted {requested}")

rejects(["calligraphy-wyrm"], "calligraphy-wyrm")
rejects(["no-such"], "no-such")
rejects(["runewyrm"], "runewyrm")
print("commands ok")
PY

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<'EOF'
[runewyrm]
user=dragon
host=runewyrm.stealthdragonland.net
status=in

[calligraphy-wyrm]
user=dragon
host=192.168.1.100
status=out
note=Windows. SSH does not.
EOF

list="$(python3 "$cli" --inventory "$tmp" list)"
printf '%s\n' "$list" | grep -qx 'runewyrm in' || fail "list missed the in row: ${list}"
printf '%s\n' "$list" | grep -qx 'calligraphy-wyrm out' || fail "list missed the out row: ${list}"

set +e
python3 "$cli" --inventory "$tmp" --host calligraphy-wyrm dry-run \
    >"${tmp}.out" 2>"${tmp}.err"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "an out host was accepted"
grep -F 'calligraphy-wyrm' "${tmp}.err" >/dev/null \
    || fail "out-host error omitted the section: $(cat "${tmp}.err")"

set +e
python3 "$cli" --inventory "$tmp" --host missing-box dry-run \
    >"${tmp}.out" 2>"${tmp}.err"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "an unknown section was accepted"
grep -F 'missing-box' "${tmp}.err" >/dev/null \
    || fail "unknown-section error omitted the section: $(cat "${tmp}.err")"
