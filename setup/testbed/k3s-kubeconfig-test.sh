#!/usr/bin/env bash
# The workstation kubeconfig follows the server file and keeps other contexts.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tool="${repo}/setup/files/k3s/merge-kubeconfig.py"
fixture="FIXTUREKEY9f3a"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat >"${work}/server.yaml" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: default
  cluster:
    server: https://127.0.0.1:6443
    certificate-authority-data: Y2E=
users:
- name: default
  user:
    client-certificate-data: Y2VydA==
    client-key-data: ${fixture}
contexts:
- name: default
  context:
    cluster: default
    user: default
current-context: default
EOF

cat >"${work}/dest.yaml" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: microk8s-cluster
  cluster:
    server: https://192.168.0.54:16443
    certificate-authority-data: b2xk
- name: roost-drake
  cluster:
    server: https://roost-drake.stealthdragonland.net:6443
    certificate-authority-data: b2xk
users:
- name: admin
  user:
    token: old-token
- name: roost-drake
  user:
    client-certificate-data: b2xk
    client-key-data: old-key
contexts:
- name: microk8s
  context:
    cluster: microk8s-cluster
    user: admin
- name: roost-drake
  context:
    cluster: roost-drake
    user: roost-drake
current-context: roost-drake
EOF

run() {
    python3 "$tool" \
        --server "${work}/server.yaml" \
        --dest "${work}/dest.yaml" \
        --server-url "https://k3s.stealthdragonland.net:6443"
}

out="$(run 2>&1)" || fail "merge failed: ${out}"
printf '%s\n' "$out" | grep -q "$fixture" && fail "merge printed the fixture key"
grep -q 'https://k3s.stealthdragonland.net:6443' "${work}/dest.yaml" || fail "server URL was not updated"
grep -q "$fixture" "${work}/dest.yaml" || fail "roost-drake user was not replaced"
grep -q 'name: microk8s' "${work}/dest.yaml" || fail "microk8s context was dropped"
grep -q 'old-token' "${work}/dest.yaml" || fail "microk8s user was dropped"
before="$(cksum "${work}/dest.yaml")"
out="$(run 2>&1)" || fail "second merge failed: ${out}"
after="$(cksum "${work}/dest.yaml")"
[[ "$before" == "$after" ]] || fail "identical server file rewrote the kubeconfig"
printf '%s\n' "$out" | grep -q "$fixture" && fail "second merge printed the fixture key"

python3 - "${work}/server.yaml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("FIXTUREKEY9f3a", "NEWKEY9f3a")
path.write_text(text)
PY
out="$(run 2>&1)" || fail "changed merge failed: ${out}"
grep -q 'NEWKEY9f3a' "${work}/dest.yaml" || fail "changed server file did not update the user"
grep -q "$fixture" "${work}/dest.yaml" && fail "old key stayed in the kubeconfig"
printf '%s\n' "$out" | grep -q 'NEWKEY9f3a' && fail "changed merge printed the new key"
grep -q 'merge-kubeconfig.py' "${repo}/setup/modules/compute/install-k3s.sh" \
    || fail "install-k3s does not refresh the kubeconfig"

printf '%s\n' "k3s kubeconfig ok"
