#!/usr/bin/env bash
# hypridle's idle timeout and any PulseAudio sink input drive the cordon.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo}/setup/files/k3s/htpc-cordon.sh"
module="${repo}/setup/modules/compute/install-k3s.sh"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ -x "$script" ]] || fail "htpc-cordon is not executable"
grep -q 'kodi' "$script" && fail "cordon still names apps"
grep -q 'hyprctl' "$script" && fail "cordon still reads hyprctl"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin" "${work}/boinc" "${work}/state"
printf 'rpcsecret\n' >"${work}/boinc/gui_rpc_auth.cfg"
printf 'htpc\n' >"${work}/role"
printf 'Sink Input #1\n\tState: RUNNING\n' >"${work}/running.txt"
printf 'Sink Input #1\n\tState: CORKED\n' >"${work}/quiet.txt"

cat >"${work}/bin/pactl" <<'EOF'
#!/bin/bash
cat "${PACTL_OUT}"
EOF
cat >"${work}/bin/kubectl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${KLOG}"
exit 0
EOF
cat >"${work}/bin/boinccmd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${BLOG}"
exit 0
EOF
chmod 0755 "${work}/bin/"*

run_watch() {
    PATH="${work}/bin:${PATH}" \
        HOME="${work}" \
        HTPC_ROLE_FILE="${work}/role" \
        HTPC_STATE_DIR="${work}/state" \
        HTPC_KUBECONFIG="${work}/kube" \
        HTPC_NODE_NAME="hearthwyrm" \
        HTPC_NOW="$1" \
        PACTL_OUT="$2" \
        KLOG="${work}/kubectl.log" \
        BLOG="${work}/boinc.log" \
        BOINC_DIR="${work}/boinc" \
        BOINCCMD="${work}/bin/boinccmd" \
        "$script" "$3"
}

: >"${work}/kube"
: >"${work}/kubectl.log"
: >"${work}/boinc.log"
run_watch 1000 "${work}/quiet.txt" active
grep -q 'cordon hearthwyrm' "${work}/kubectl.log" || fail "active did not cordon"
grep -q 'drain hearthwyrm --ignore-daemonsets' "${work}/kubectl.log" \
    || fail "active did not drain"
grep -q -- '--set_run_mode never' "${work}/boinc.log" || fail "active did not suspend BOINC"
drains="$(grep -c 'drain hearthwyrm' "${work}/kubectl.log")"
run_watch 1005 "${work}/quiet.txt" active
drains_after="$(grep -c 'drain hearthwyrm' "${work}/kubectl.log")"
[[ "$drains_after" -eq "$drains" ]] || fail "second active tick drained again"

: >"${work}/kubectl.log"
run_watch 2000 "${work}/running.txt" idle
grep -q 'uncordon' "${work}/kubectl.log" && fail "pulse output uncordoned the node"
drains_pulse="$(grep -c 'drain hearthwyrm' "${work}/kubectl.log" || true)"
[[ "${drains_pulse:-0}" -eq 0 ]] || fail "idle with pulse drained again"

: >"${work}/kubectl.log"
: >"${work}/boinc.log"
run_watch 2100 "${work}/quiet.txt" idle
grep -q 'uncordon hearthwyrm' "${work}/kubectl.log" || fail "hypridle idle did not uncordon"
grep -q -- '--set_run_mode auto' "${work}/boinc.log" || fail "did not resume BOINC"
grep -q -- '--set_gpu_mode always' "${work}/boinc.log" || fail "did not resume the GPU"

rm -rf "${work}/state"
mkdir -p "${work}/state"
printf 'hypridle=idle\nmode=active\nidle_since=\n' >"${work}/state/state"
: >"${work}/kubectl.log"
run_watch 3000 "${work}/quiet.txt" check
grep -q 'uncordon' "${work}/kubectl.log" && fail "uncordoned before 60 seconds"
run_watch 3059 "${work}/quiet.txt" check
grep -q 'uncordon' "${work}/kubectl.log" && fail "uncordoned at 59 seconds"
run_watch 3060 "${work}/quiet.txt" check
grep -q 'uncordon hearthwyrm' "${work}/kubectl.log" || fail "did not uncordon at 60 seconds"

printf 'workstation\n' >"${work}/role"
: >"${work}/kubectl.log"
if run_watch 4000 "${work}/quiet.txt" active; then
    fail "workstation role was allowed to cordon"
fi
[[ ! -s "${work}/kubectl.log" ]] || fail "workstation role called kubectl"

grep -q 'role" == "htpc"' "$module" || fail "timer install is not limited to htpc"

printf '%s\n' "htpc cordon ok"
