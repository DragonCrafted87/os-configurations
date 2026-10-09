#!/usr/bin/env bash
# git is not enough. The grotto-wyrm prune removed git-core, and dnf
# then removed the git package. diffutils is a Requires of git-core.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${HERE}/../modules/common/prune-extra-packages.py"
never="${HERE}/../files/packages/never-remove.list"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

out="$(
    python3 - "$py" "$never" <<'PY'
import importlib.util
import sys

path, never_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("prune_extra_packages", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
never = mod.read_names(mod.Path(never_path))
keep = set(never) | set(mod.ALWAYS_KEEP_NAMES)
installed = [
    "bash",
    "chromium",
    "curl",
    "diffutils",
    "git",
    "git-core",
    "plasma6-desktop",
]
removed = mod.removals_outside(installed, keep)
print("\n".join(removed))
PY
)"

for name in git git-core diffutils curl bash; do
    if printf '%s\n' "$out" | grep -Fx "$name" >/dev/null; then
        fail "${name} would be removed: ${out}"
    fi
done
printf '%s\n' "$out" | grep -Fx chromium >/dev/null || fail "chromium was kept: ${out}"
printf '%s\n' "$out" | grep -Fx plasma6-desktop >/dev/null \
    || fail "plasma6-desktop was kept: ${out}"

printf 'never-remove bootstrap ok\n'
