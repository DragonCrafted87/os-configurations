#!/usr/bin/env bash
# Cordon an htpc node while a display is on or playback is running.
# Undo both after the screens have been off and playback has been
# quiet for 60 seconds. A Hyprland session that is only sitting there
# does not cordon the node. DaemonSets stay through the drain.

set -euo pipefail

role_file="${HTPC_ROLE_FILE:-${HOME}/.config/dot-files/role}"
state_dir="${HTPC_STATE_DIR:-/run/htpc-cordon}"
kubeconfig="${HTPC_KUBECONFIG:-/etc/rancher/k3s/htpc.kubeconfig}"
node="${HTPC_NODE_NAME:-$(hostname -s)}"
boinc_dir="${BOINC_DIR:-${HOME}/.local/share/boinc}"
now="${HTPC_NOW:-$(date +%s)}"

role=""
if [[ -f "$role_file" ]]; then
    role="$(tr -d '[:space:]' <"$role_file")"
fi
if [[ "$role" != "htpc" ]]; then
    printf 'htpc-cordon: saved role is %s\n' "${role:-unset}" >&2
    exit 1
fi

probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT
if ! hyprctl monitors -j >"${probe}/mon.json" 2>/dev/null; then
    printf 'htpc-cordon: hyprctl failed; leaving the cordon state\n' >&2
    exit 0
fi
if ! pw-dump >"${probe}/pw.json" 2>/dev/null; then
    printf '[]\n' >"${probe}/pw.json"
fi

in_use="$(
    python3 - "${probe}/mon.json" "${probe}/pw.json" <<'PY'
import json
import sys

apps = (
    "kodi",
    "steam",
    "retroarch",
    "duckstation",
    "pcsx2",
    "rpcs3",
    "cemu",
    "yuzu",
    "ryujinx",
    "brave",
    "firefox",
    "chromium",
    "chrome",
)


def load(path):
    with open(path, encoding="utf-8") as handle:
        text = handle.read().strip()
    if not text:
        return []
    return json.loads(text)


def screen_on(mons):
    if not isinstance(mons, list):
        return False
    for mon in mons:
        if not isinstance(mon, dict) or mon.get("disabled") is True:
            continue
        if mon.get("dpmsStatus") is True:
            return True
    return False


def strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for value in obj.values():
            yield from strings(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from strings(value)


def playback(obj):
    if isinstance(obj, dict):
        if str(obj.get("state", "")).lower() == "running":
            blob = " ".join(strings(obj)).lower()
            if any(app in blob for app in apps):
                return True
        return any(playback(value) for value in obj.values())
    if isinstance(obj, list):
        return any(playback(value) for value in obj)
    return False


mons = load(sys.argv[1])
streams = load(sys.argv[2])
print("1" if screen_on(mons) or playback(streams) else "0")
PY
)"

mkdir -p "$state_dir"
state_file="${state_dir}/state"
mode="idle"
idle_since=""
if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    . "$state_file"
fi

boinc_mode() {
    local run_mode="$1" gpu_mode="$2" rpc=""
    local rpc_file="${boinc_dir}/gui_rpc_auth.cfg"
    if [[ ! -x /usr/local/bin/boinccmd || ! -f "$rpc_file" ]]; then
        return 0
    fi
    rpc="$(tr -d '[:space:]' <"$rpc_file")"
    [[ -n "$rpc" ]] || return 0
    /usr/local/bin/boinccmd --host 127.0.0.1 --passwd "$rpc" \
        --set_run_mode "$run_mode" >/dev/null
    /usr/local/bin/boinccmd --host 127.0.0.1 --passwd "$rpc" \
        --set_gpu_mode "$gpu_mode" >/dev/null
}

write_state() {
    printf 'mode=%s\nidle_since=%s\n' "$1" "$2" >"$state_file"
}

export KUBECONFIG="$kubeconfig"

if [[ "$in_use" == "1" ]]; then
    if [[ "$mode" != "active" ]]; then
        kubectl cordon "$node"
        kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
            --grace-period=15 --timeout=90s
        boinc_mode never never
    fi
    write_state active ""
    exit 0
fi

if [[ "$mode" != "active" && -z "${idle_since}" ]]; then
    write_state idle ""
    exit 0
fi
if [[ -z "${idle_since}" ]]; then
    write_state active "$now"
    exit 0
fi
if ((now - idle_since < 60)); then
    write_state active "$idle_since"
    exit 0
fi
kubectl uncordon "$node"
boinc_mode auto always
write_state idle ""
