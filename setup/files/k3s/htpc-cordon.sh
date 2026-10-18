#!/usr/bin/env bash
# Cordon an htpc node from hypridle's idle timeout, and while PulseAudio
# has a running sink input. hypridle's own timeout is the idle wait.
# A running sink input keeps the node cordoned after that timeout, and
# a quiet sink waits 60 seconds before the undo. DaemonSets stay.

set -euo pipefail

role_file="${HTPC_ROLE_FILE:-${HOME}/.config/dot-files/role}"
state_dir="${HTPC_STATE_DIR:-/run/htpc-cordon}"
kubeconfig="${HTPC_KUBECONFIG:-/etc/rancher/k3s/htpc.kubeconfig}"
node="${HTPC_NODE_NAME:-$(hostname -s)}"
boinc_dir="${BOINC_DIR:-${HOME}/.local/share/boinc}"
boinccmd="${BOINCCMD:-/usr/local/bin/boinccmd}"
now="${HTPC_NOW:-$(date +%s)}"
action="${1:-check}"

role=""
if [[ -f "$role_file" ]]; then
    role="$(tr -d '[:space:]' <"$role_file")"
fi
if [[ "$role" != "htpc" ]]; then
    printf 'htpc-cordon: saved role is %s\n' "${role:-unset}" >&2
    exit 1
fi

case "$action" in
    active | idle | check) ;;
    *)
        printf 'usage: %s active|idle|check\n' "${0##*/}" >&2
        exit 2
        ;;
esac

mkdir -p "$state_dir"
state_file="${state_dir}/state"
hypridle="active"
mode="idle"
idle_since=""
if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    . "$state_file"
fi
case "$action" in
    active) hypridle="active" ;;
    idle) hypridle="idle" ;;
esac

pulse_running() {
    local listing
    if ! listing="$(pactl list sink-inputs 2>/dev/null)"; then
        return 2
    fi
    grep -q 'State: RUNNING' <<<"$listing"
}

pulse_rc=0
pulse_running || pulse_rc=$?
if [[ "$pulse_rc" -eq 2 ]]; then
    printf 'htpc-cordon: pactl failed; leaving the cordon state\n' >&2
    exit 0
fi
sink_running=0
if [[ "$pulse_rc" -eq 0 ]]; then
    sink_running=1
fi

boinc_mode() {
    local run_mode="$1" gpu_mode="$2" rpc=""
    local rpc_file="${boinc_dir}/gui_rpc_auth.cfg"
    if [[ ! -x "$boinccmd" || ! -f "$rpc_file" ]]; then
        return 0
    fi
    rpc="$(tr -d '[:space:]' <"$rpc_file")"
    [[ -n "$rpc" ]] || return 0
    "$boinccmd" --host 127.0.0.1 --passwd "$rpc" \
        --set_run_mode "$run_mode" >/dev/null
    "$boinccmd" --host 127.0.0.1 --passwd "$rpc" \
        --set_gpu_mode "$gpu_mode" >/dev/null
}

write_state() {
    printf 'hypridle=%s\nmode=%s\nidle_since=%s\n' "$1" "$2" "$3" >"$state_file"
}

export KUBECONFIG="$kubeconfig"

in_use=0
if [[ "$hypridle" != "idle" || "$sink_running" -eq 1 ]]; then
    in_use=1
fi

if [[ "$in_use" -eq 1 ]]; then
    if [[ "$mode" != "active" ]]; then
        kubectl cordon "$node"
        kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
            --grace-period=15 --timeout=90s
        boinc_mode never never
    fi
    write_state "$hypridle" active ""
    exit 0
fi

# hypridle already waited out its timeout. Undo immediately when the
# sink is quiet at that moment. A later check waits 60 seconds so a
# gap between tracks does not flap the node.
if [[ "$action" == "idle" ]]; then
    if [[ "$mode" == "active" ]]; then
        kubectl uncordon "$node"
        boinc_mode auto always
    fi
    write_state idle idle ""
    exit 0
fi

if [[ "$mode" != "active" ]]; then
    write_state idle idle ""
    exit 0
fi
if [[ -z "${idle_since}" ]]; then
    write_state idle active "$now"
    exit 0
fi
if ((now - idle_since < 60)); then
    write_state idle active "$idle_since"
    exit 0
fi
kubectl uncordon "$node"
boinc_mode auto always
write_state idle idle ""
