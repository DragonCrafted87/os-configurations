#!/usr/bin/env bash
# Point the Rock repo ids this machine uses at the Pulp on-demand cache.
# gpgcheck and gpgkey stay. A distro-release-repos update restores the
# public mirrors until the next role run.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

PULP_CONTENT="https://pulp.stealthdragonland.net/pulp/content"

rewrite_rock_repo() {
    local arch="$1"
    local src="$2"
    python3 - "$arch" "$PULP_CONTENT" "$src" <<'PY'
import sys

arch, prefix, path = sys.argv[1:]
text = open(path, encoding="utf-8").read()
pairs = {
    f"rock-{arch}": f"{prefix}/rock/{arch}/main/release/",
    f"rock-updates-{arch}": f"{prefix}/rock/{arch}/main/updates/",
    f"rock-{arch}-extra": f"{prefix}/rock/{arch}/extra/release/",
    f"rock-updates-{arch}-extra": f"{prefix}/rock/{arch}/extra/updates/",
    f"rock-{arch}-restricted": f"{prefix}/rock/{arch}/restricted/release/",
    f"rock-updates-{arch}-restricted": f"{prefix}/rock/{arch}/restricted/updates/",
    f"rock-{arch}-non-free": f"{prefix}/rock/{arch}/non-free/release/",
    f"rock-updates-{arch}-non-free": f"{prefix}/rock/{arch}/non-free/updates/",
}
lines = text.splitlines(keepends=True)
out = []
index = 0
section = None
while index < len(lines):
    line = lines[index]
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]") and " " not in stripped:
        section = stripped[1:-1]
        out.append(line)
        index += 1
        continue
    key = stripped.split("=", 1)[0].strip() if "=" in stripped else ""
    if section in pairs and key == "baseurl":
        ending = "\n" if line.endswith("\n") else ""
        out.append(f"baseurl={pairs[section]}{ending or chr(10)}")
        index += 1
        while index < len(lines):
            body = lines[index].split("#", 1)[0]
            if body[:1] in (" ", "\t") and "=" not in body:
                index += 1
                continue
            break
        continue
    out.append(line)
    index += 1
sys.stdout.write("".join(out))
PY
}

write_rock_repo() {
    local dest="$1"
    local arch="$2"
    local updated tmp

    if [[ ! -f "$dest" ]]; then
        log "no Rock repo file at ${dest}"
        return 0
    fi
    updated="$(rewrite_rock_repo "$arch" "$dest")"
    if [[ "$updated" == "$(cat "$dest")" ]]; then
        return 0
    fi
    log "point ${dest} at Pulp"
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        printf '%s\n' "$updated"
        return 0
    fi
    tmp="$(mktemp)"
    printf '%s' "$updated" >"$tmp"
    if [[ "$dest" == /etc/* ]]; then
        sudo install -m 0644 "$tmp" "$dest"
    else
        install -m 0644 "$tmp" "$dest"
    fi
    rm -f "$tmp"
}

# Tests source this file and call the functions. A role run rewrites
# the distro repo file for this machine's architecture.
if [[ "${DOTFILES_TEST_SOURCE:-0}" == "1" ]]; then
    return 0
fi

require_user
rpm_arch="$(detect_omv_repo_arch)"
write_rock_repo \
    "${ROCK_REPO_DEST:-/etc/yum.repos.d/openmandriva-rock-${rpm_arch}.repo}" \
    "$rpm_arch"
