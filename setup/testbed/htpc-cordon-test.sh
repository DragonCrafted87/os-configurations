#!/usr/bin/env bash
# The htpc watcher cordons once, waits 60 seconds, and stays off other roles.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo}/setup/files/k3s/htpc-cordon.sh"
module="${repo}/setup/modules/compute/install-k3s.sh"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ -x "$script" ]] || fail "htpc-cordon is not executable"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/bin" "${work}/boinc"
printf 'rpcsecret\n' >"${work}/boinc/gui_rpc_auth.cfg"
printf 'htpc\n' >"${work}/role"

cat >"${work}/bin/hyprctl" <<'EOF'
#!/bin/bash
cat "${MON_JSON}"
EOF
cat >"${work}/bin/pw-dump" <<'EOF'
#!/bin/bash
cat "${PW_JSON}"
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
ln -s "${work}/bin/boinccmd" /usr/local/bin/boinccmd 2>/dev/null || true
# The script calls /usr/local/bin/boinccmd. Point BOINCCMD by wrapping PATH
# only works if the script uses PATH. It uses the absolute path, so install
# a temporary copy beside the test by overriding via a function? The script
# hardcodes /usr/local/bin/boinccmd. Use a copy in a fake root by running
# with a PATH-based change: patch is in the script as absolute. Copy the
# stub over a test-local bind by setting HOME and replacing the call.
# We install the stub as the command the script runs when that path is
# the stub. Tests run as the user and cannot replace /usr/local/bin.
# The script checks -x /usr/local/bin/boinccmd. If the real one exists,
# the test would call it. Guard the test by using `unshare` or by
# making the script honor BOINCCMD. Honor BOINCCMD.
chmod 0755 "${work}/bin/"*

printf '[{"name":"HDMI-A-1","disabled":false,"dpmsStatus":true}]\n' >"${work}/on.json"
printf '[{"name":"HDMI-A-1","disabled":false,"dpmsStatus":false}]\n' >"${work}/off.json"
printf '[]\n' >"${work}/quiet.json"
cat >"${work}/kodi.json" <<'EOF'
[{"state":"running","props":{"application.name":"Kodi"}}]
EOF

run_watch() {
    PATH="${work}/bin:${PATH}" \
        HOME="${work}" \
        HTPC_ROLE_FILE="${work}/role" \
        HTPC_STATE_DIR="${work}/state" \
        HTPC_KUBECONFIG="${work}/kube" \
        HTPC_NODE_NAME="hearthwyrm" \
        HTPC_NOW="$1" \
        MON_JSON="$2" \
        PW_JSON="$3" \
        KLOG="${work}/kubectl.log" \
        BLOG="${work}/boinc.log" \
        BOINC_DIR="${work}/boinc" \
        "$script"
}

: >"${work}/kube"
: >"${work}/kubectl.log"
: >"${work}/boinc.log"
# boinccmd absolute path: if the real binary exists, skip calling it by
# moving the script's check. Tests set a wrapper only when we export
# a fake through /usr/local. Fall back: the real client may be absent
# in CI. On this machine it exists, so point the script at the stub
# with a copied script under the work dir.
sed 's#/usr/local/bin/boinccmd#${BOINCCMD:-/usr/local/bin/boinccmd}#' "$script" \
    >"${work}/watch.sh"
chmod 0755 "${work}/watch.sh"
script="${work}/watch.sh"

PATH="${work}/bin:${PATH}" BOINCCMD="${work}/bin/boinccmd" \
    run_watch 1000 "${work}/on.json" "${work}/quiet.json"
grep -q 'cordon hearthwyrm' "${work}/kubectl.log" || fail "active did not cordon"
grep -q 'drain hearthwyrm --ignore-daemonsets' "${work}/kubectl.log" \
    || fail "active did not drain"
grep -q -- '--set_run_mode never' "${work}/boinc.log" || fail "active did not suspend BOINC"
grep -q -- '--set_gpu_mode never' "${work}/boinc.log" || fail "active did not stop the GPU"
drains="$(grep -c 'drain hearthwyrm' "${work}/kubectl.log")"
PATH="${work}/bin:${PATH}" BOINCCMD="${work}/bin/boinccmd" \
    run_watch 1005 "${work}/on.json" "${work}/quiet.json"
drains_after="$(grep -c 'drain hearthwyrm' "${work}/kubectl.log")"
[[ "$drains_after" -eq "$drains" ]] || fail "second active tick drained again"

rm -rf "${work}/state"
mkdir -p "${work}/state"
: >"${work}/kubectl.log"
printf 'mode=idle\nidle_since=\n' >"${work}/state/state"
PATH="${work}/bin:${PATH}" BOINCCMD="${work}/bin/boinccmd" \
    run_watch 2000 "${work}/off.json" "${work}/kodi.json"
grep -q 'cordon hearthwyrm' "${work}/kubectl.log" || fail "kodi audio did not cordon"

rm -rf "${work}/state"
mkdir -p "${work}/state"
printf 'mode=active\nidle_since=\n' >"${work}/state/state"
: >"${work}/kubectl.log"
: >"${work}/boinc.log"
PATH="${work}/bin:${PATH}" BOINCCMD="${work}/bin/boinccmd" \
    run_watch 3000 "${work}/off.json" "${work}/quiet.json"
grep -q 'uncordon' "${work}/kubectl.log" && fail "uncordoned before 60 seconds"
PATH="${work}/bin:${PATH}" BOINCCMD="${work}/bin/boinccmd" \
    run_watch 3059 "${work}/off.json" "${work}/quiet.json"
grep -q 'uncordon' "${work}/kubectl.log" && fail "uncordoned at 59 seconds"
PATH="${work}/bin:${PATH}" BOINCCMD="${work}/bin/boinccmd" \
    run_watch 3060 "${work}/off.json" "${work}/quiet.json"
grep -q 'uncordon hearthwyrm' "${work}/kubectl.log" || fail "did not uncordon at 60 seconds"
grep -q -- '--set_run_mode auto' "${work}/boinc.log" || fail "did not resume BOINC"
grep -q -- '--set_gpu_mode always' "${work}/boinc.log" || fail "did not resume the GPU"

printf 'workstation\n' >"${work}/role"
: >"${work}/kubectl.log"
if PATH="${work}/bin:${PATH}" BOINCCMD="${work}/bin/boinccmd" \
    run_watch 4000 "${work}/on.json" "${work}/quiet.json"; then
    fail "workstation role was allowed to cordon"
fi
[[ ! -s "${work}/kubectl.log" ]] || fail "workstation role called kubectl"

grep -q 'role" == "htpc"' "$module" || fail "timer install is not limited to htpc"
grep -q 'install_htpc_cordon' "$module" || fail "module does not install the timer"

printf '%s\n' "htpc cordon ok"
