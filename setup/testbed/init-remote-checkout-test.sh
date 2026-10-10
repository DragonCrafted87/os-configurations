#!/usr/bin/env bash
# Dry walk of the remote checkout commands. No SSH session is opened.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/../init-remote.sh"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

script="${HERE}/../init-remote.sh"
grep -F 'apply haos with role.sh --target' "$script" >/dev/null \
    || fail "haos is no longer sent to role.sh --target"

haos_err="$(mktemp)"
set +e
remote_checkout_script haos >/dev/null 2>"$haos_err"
rc=$?
set -e
rm -f "$haos_err"
[[ "$rc" -ne 0 ]] || fail "haos produced a checkout script"

workstation="$(remote_checkout_script workstation)"
server="$(remote_checkout_script server)"

grep -F 'git@github.com:DragonCrafted87/homelab.git' <<<"$workstation" >/dev/null \
    || fail "workstation clone omitted homelab.git"
grep -F 'submodule update --init' <<<"$workstation" >/dev/null \
    || fail "workstation init is missing"
if grep -E 'submodule update --init[[:space:]]+[^[:space:]]' <<<"$workstation" >/dev/null; then
    fail "workstation init named a submodule path"
fi
grep -F 'ln -sfn ~/git-workspace/homelab/dot-files ~/dot-files' <<<"$workstation" >/dev/null \
    || fail "workstation script does not link ~/dot-files"
grep -F 'ln -sfn ~/git-workspace/homelab/machine-setup ~/machine-setup' <<<"$workstation" >/dev/null \
    || fail "workstation script does not link ~/machine-setup"
if grep -F 'ln -sfn ~/git-workspace/homelab/machine-setup ~/machine-setup' <<<"$server" >/dev/null; then
    fail "server script links the homelab machine-setup checkout"
fi
grep -F '.config/dot-files/checkouts' <<<"$workstation" >/dev/null \
    || fail "workstation script does not write the checkouts file"

grep -F 'git@github.com:DragonCrafted87/dot-files.git' <<<"$server" >/dev/null \
    || fail "server clone omitted dot-files.git"
grep -F 'git@github.com:DragonCrafted87/os-configurations.git' <<<"$server" >/dev/null \
    || fail "server clone omitted os-configurations.git"
if grep -F 'homelab.git' <<<"$server" >/dev/null; then
    fail "server script contains homelab.git"
fi
grep -F '.config/dot-files/checkouts' <<<"$server" >/dev/null \
    || fail "server script does not write the checkouts file"

htpc="$(remote_checkout_script htpc)"
grep -F 'os-configurations.git' <<<"$htpc" >/dev/null \
    || fail "htpc clone omitted os-configurations.git"
if grep -F 'homelab.git' <<<"$htpc" >/dev/null; then
    fail "htpc script contains homelab.git"
fi

printf 'init-remote checkout ok\n'
