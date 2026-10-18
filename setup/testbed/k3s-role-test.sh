#!/usr/bin/env bash
# install-k3s joins the right way and does not print the token.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
module="${repo}/setup/modules/compute/install-k3s.sh"
packages="${repo}/setup/modules/desktop/install-workstation-packages.sh"
fixture="fixture-token-9f3a"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ -x "$module" ]] || fail "module is not executable"
grep -q 'kubernetes-client' "$packages" && fail "workstation packages still install kubernetes-client"
grep -q 'K3S_VERSION=v1.36.5+k3s1' "${repo}/setup/versions.conf" || fail "version pin missing"
awk -F= '$1=="bootstrap" && $2=="roost-drake" { found=1 } END { exit !found }' \
    "${repo}/setup/files/k3s/cluster.conf" || fail "bootstrap is not roost-drake"
bootstrap_count="$(awk -F= '$1=="bootstrap" { c++ } END { print c+0 }' \
    "${repo}/setup/files/k3s/cluster.conf")"
[[ "$bootstrap_count" -eq 1 ]] || fail "bootstrap is not unique"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/home/.config/dot-files" "${work}/dot-files/bashrc.d" "${work}/bin" \
    "${work}/home/.kube"
printf 'dot-files=%s\nmachine-setup=%s\n' "${work}/dot-files" "$repo" \
    >"${work}/home/.config/dot-files/checkouts"
printf '%s\n' "$fixture" >"${work}/token"
cat >"${work}/kube.yaml" <<'EOF'
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
    client-key-data: FIXTUREKEY9f3a
contexts:
- name: default
  context:
    cluster: default
    user: default
current-context: default
EOF

cat >"${work}/bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
cat >"${work}/bin/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${SYSLOG}"
case "$*" in
    "is-active --quiet k3s")
        [[ -f ${SYSROOT}/active-k3s ]]
        ;;
    "is-active --quiet k3s-agent")
        [[ -f ${SYSROOT}/active-agent ]]
        ;;
    "is-enabled --quiet keepalived" | "is-enabled --quiet htpc-cordon.timer")
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
EOF
cat >"${work}/bin/rpm" <<'EOF'
#!/bin/bash
if [[ "$1" == "-q" && "$2" == "kubernetes-client" ]]; then
    [[ -f ${SYSROOT}/has-k8s-client ]]
    exit
fi
exec /usr/bin/rpm "$@"
EOF
cat >"${work}/bin/dnf" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${SYSLOG}"
if [[ "$1" == "remove" ]]; then
    rm -f "${SYSROOT}/has-k8s-client"
fi
exit 0
EOF
cat >"${work}/bin/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"${work}/bin/sh" <<'EOF'
#!/bin/sh
if [[ "$1" == "-s" ]]; then
    printf '%s\n' "$*" >>"${INSTALL_LOG}"
    mkdir -p "${SYSROOT}/usr/local/bin"
    printf '#!/bin/sh\nexit 0\n' >"${SYSROOT}/usr/local/bin/k3s"
    chmod 0755 "${SYSROOT}/usr/local/bin/k3s"
    exit 0
fi
exec /bin/sh "$@"
EOF
cat >"${work}/bin/ssh" <<'EOF'
#!/bin/sh
cmd=""
for arg in "$@"; do
    cmd="${arg}"
done
case "$cmd" in
    *node-token*)
        printf '%s\n' "${FIXTURE_TOKEN}"
        ;;
    *k3s.yaml*)
        cat "${KUBE_FIXTURE}"
        ;;
    *k3s-vip.pass*)
        printf '%s\n' "vip-pass"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod 0755 "${work}/bin/"*

run_user="$(id -un)"
run_module() {
    local name="$1" role="$2" subroles="${3:-}"
    printf '%s\n' "$role" >"${work}/home/.config/dot-files/role"
    if [[ -n "$subroles" ]]; then
        printf '%s\n' "$subroles" >"${work}/home/.config/dot-files/subroles"
    else
        rm -f "${work}/home/.config/dot-files/subroles"
    fi
    PATH="${work}/bin:${PATH}" \
        DOTFILES_HOME="${work}/home" \
        DOTFILES_USER="$run_user" \
        K3S_SYSROOT="${work}/sys-${name}" \
        K3S_NODE_NAME="$name" \
        K3S_VIP_IFACE="eth0" \
        SYSROOT="${work}/sys-${name}" \
        SYSLOG="${work}/sys-${name}.log" \
        INSTALL_LOG="${work}/sys-${name}.install" \
        FIXTURE_TOKEN="$fixture" \
        KUBE_FIXTURE="${work}/kube.yaml" \
        /usr/bin/bash "$module"
}

mkdir -p "${work}/sys-roost-drake"
: >"${work}/sys-roost-drake.log"
: >"${work}/sys-roost-drake.install"
touch "${work}/sys-roost-drake/has-k8s-client"
out="$(run_module roost-drake server 2>&1)" || fail "bootstrap failed: ${out}"
printf '%s\n' "$out" | grep -q "$fixture" && fail "bootstrap printed the token"
grep -q -- '--cluster-init' "${work}/sys-roost-drake.install" || fail "bootstrap missed cluster-init"
grep -q 'subrole-nfs-server' "${work}/sys-roost-drake/etc/rancher/k3s/config.yaml" \
    && fail "bootstrap grew an nfs label"
[[ -L "${work}/sys-roost-drake/usr/local/bin/kubectl" ]] || fail "missing kubectl symlink"
[[ -L "${work}/sys-roost-drake/usr/local/bin/crictl" ]] || fail "missing crictl symlink"
[[ -L "${work}/sys-roost-drake/usr/local/bin/ctr" ]] || fail "missing ctr symlink"
printf '%s\n' "$out" | grep -q 'remove kubernetes-client' || fail "did not remove kubernetes-client"
grep -q 'remove -y kubernetes-client' "${work}/sys-roost-drake.log" || fail "dnf did not remove kubernetes-client"
mkdir -p "${work}/sys-roost-drake/var/lib/rancher/k3s/server/db/etcd"
: >"${work}/sys-roost-drake.install"
out="$(run_module roost-drake server 2>&1)" || fail "second bootstrap failed: ${out}"
[[ ! -s "${work}/sys-roost-drake.install" ]] || fail "second bootstrap reinstalled"

out="$(run_module hoard-drake server nfs-server 2>&1)" || fail "hoard join failed: ${out}"
printf '%s\n' "$out" | grep -q "$fixture" && fail "hoard printed the token"
grep -q -- '--cluster-init' "${work}/sys-hoard-drake.install" && fail "joiner passed cluster-init"
grep -q 'https://k3s.stealthdragonland.net:6443' "${work}/sys-hoard-drake.install" \
    || fail "joiner missed the registration address"
grep -q 'subrole-nfs-server=true' "${work}/sys-hoard-drake/etc/rancher/k3s/config.yaml" \
    || fail "hoard missed the nfs label"
grep -q 'node-taint' "${work}/sys-hoard-drake/etc/rancher/k3s/config.yaml" \
    && fail "hoard gained a taint"
cmp -s "${work}/sys-hoard-drake/etc/rancher/k3s/cluster-token" "${work}/token" \
    || fail "hoard token file mismatch"

out="$(run_module runewyrm workstation gaming 2>&1)" || fail "agent failed: ${out}"
printf '%s\n' "$out" | grep -q "$fixture" && fail "agent printed the token"
grep -q -- '--cluster-init' "${work}/sys-runewyrm.install" && fail "agent passed cluster-init"
grep -q 'purpose=workstation:NoSchedule' "${work}/sys-runewyrm/etc/rancher/k3s/config.yaml" \
    || fail "workstation missed its taint"
grep -q 'subrole-gaming=true' "${work}/sys-runewyrm/etc/rancher/k3s/config.yaml" \
    || fail "workstation missed the gaming label"
touch "${work}/sys-runewyrm/active-agent"
: >"${work}/sys-runewyrm.install"
out="$(run_module runewyrm workstation gaming 2>&1)" || fail "second agent failed: ${out}"
[[ ! -s "${work}/sys-runewyrm.install" ]] || fail "active agent reinstalled"

printf '%s\n' "k3s role ok"
