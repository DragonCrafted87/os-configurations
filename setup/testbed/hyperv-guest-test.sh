#!/usr/bin/env bash
# hyperv-guest is a no-op unless systemd-detect-virt prints microsoft,
# and the server role pulls that subrole in.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
module="${repo}/setup/modules/host/configure-hyperv-guest.sh"
conf="${repo}/setup/files/hyperv/hyperv-guest.conf"
hosts="${repo}/setup/files/boinc/hosts.list"
roles="${repo}/setup/roles.conf"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ -x "$module" ]] || fail "module is not executable"
[[ -f "$conf" ]] || fail "missing dracut drop-in"

grep -q 'hv_vmbus' "$conf" || fail "dracut drop-in misses hv_vmbus"
grep -q 'hv_storvsc' "$conf" || fail "dracut drop-in misses hv_storvsc"
grep -q 'hv_netvsc' "$conf" || fail "dracut drop-in misses hv_netvsc"
grep -q 'hv_utils' "$conf" || fail "dracut drop-in misses hv_utils"
grep -q 'force_drivers' "$conf" || fail "dracut drop-in does not force the modules"

grep -qx 'brood-drake' "$hosts" || fail "hosts.list is missing brood-drake"
grep -qx 'hoard-drake' "$hosts" || fail "hosts.list lost hoard-drake"
grep -qx 'roost-drake' "$hosts" || fail "hosts.list lost roost-drake"
awk '
    /^# servers$/ { in_servers=1; next }
    /^#/ { in_servers=0 }
    in_servers && $0 == "brood-drake" { found=1 }
    END { exit !found }
' "$hosts" || fail "brood-drake is not under # servers"

grep -q '@subrole.hyperv-guest' "$roles" || fail "server role does not pull in the subrole"
awk '
    /^\[server\]/ { in_server=1; next }
    /^\[/ { in_server=0 }
    in_server && $0 == "@subrole.hyperv-guest" { found=1 }
    END { exit !found }
' "$roles" || fail "@subrole.hyperv-guest is not in [server]"
awk '
    /^\[subrole.hyperv-guest\]/ { in_sub=1; next }
    /^\[/ { in_sub=0 }
    in_sub && $0 == "configure-hyperv-guest" { found=1 }
    END { exit !found }
' "$roles" || fail "subrole does not run configure-hyperv-guest"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/home/.config/dot-files" "${work}/dot-files/bashrc.d" \
    "${work}/bin" "${work}/nousr"
printf 'dot-files=%s\nmachine-setup=%s\n' "${work}/dot-files" "$repo" \
    >"${work}/home/.config/dot-files/checkouts"
ln -s /usr/bin/* "${work}/nousr/"
rm -f "${work}/nousr/systemd-detect-virt"

cat >"${work}/bin/dnf" <<'EOF'
#!/bin/sh
printf 'dnf should not run: %s\n' "$*" >&2
exit 99
EOF
cat >"${work}/bin/systemd-detect-virt" <<'EOF'
#!/bin/sh
printf '%s\n' "${VIRT_NAME:-none}"
EOF
chmod 0755 "${work}/bin/dnf" "${work}/bin/systemd-detect-virt"

run_user="$(id -un)"
server_list="$(
    DOTFILES_HOME="${work}/home" DOTFILES_USER="$run_user" \
        /usr/bin/bash -c 'set -euo pipefail; . "$1"; role_modules server' _ "${repo}/setup/lib/lib.sh"
)"
grep -qx 'configure-hyperv-guest' <<<"$server_list" \
    || fail "server module list lost configure-hyperv-guest"
grep -qx 'install-boinc' <<<"$server_list" \
    || fail "server module list lost install-boinc"

run_module() {
    PATH="${1}" DOTFILES_HOME="${work}/home" DOTFILES_USER="$run_user" \
        /usr/bin/bash "$module" 2>&1
}

skip_out="$(VIRT_NAME=kvm run_module "${work}/bin:${PATH}")"
grep -q 'not a Hyper-V guest (kvm); skipping' <<<"$skip_out" \
    || fail "kvm run did not skip: ${skip_out}"
grep -q 'install packages' <<<"$skip_out" && fail "kvm run tried to install packages"

unset VIRT_NAME
skip_out="$(run_module "${work}/bin:${PATH}")"
grep -q 'not a Hyper-V guest (none); skipping' <<<"$skip_out" \
    || fail "none run did not skip: ${skip_out}"

skip_out="$(run_module "${work}/nousr")"
grep -q 'not a Hyper-V guest (unknown); skipping' <<<"$skip_out" \
    || fail "missing detector did not skip: ${skip_out}"

dracut_dest="${work}/hyperv-guest.conf"
dry_out="$(VIRT_NAME=microsoft DOTFILES_DRY_RUN=1 HYPERV_DRACUT_CONF="$dracut_dest" \
    run_module "${work}/bin:${PATH}")"
grep -q 'install packages: hyperv-tools chrony' <<<"$dry_out" \
    || fail "dry-run did not install the packages: ${dry_out}"
grep -q 'dry-run: drop-in hypervkvpd.service -> /usr/bin/hv_kvp_daemon' <<<"$dry_out" \
    || fail "dry-run missed the KVP drop-in: ${dry_out}"
grep -q 'dry-run: start hypervvssd.service' <<<"$dry_out" \
    || fail "dry-run missed VSS: ${dry_out}"
grep -q 'dry-run: start hypervfcopyd.service' <<<"$dry_out" \
    || fail "dry-run missed file copy: ${dry_out}"
grep -q 'dry-run: start chronyd.service' <<<"$dry_out" \
    || fail "dry-run missed chronyd: ${dry_out}"
grep -q 'dry-run: dracut -f' <<<"$dry_out" \
    || fail "dry-run missed the initramfs rebuild: ${dry_out}"
grep -q 'dnf should not run' <<<"$dry_out" && fail "dry-run executed dnf"

cp "$conf" "$dracut_dest"
same_out="$(VIRT_NAME=microsoft DOTFILES_DRY_RUN=1 HYPERV_DRACUT_CONF="$dracut_dest" \
    run_module "${work}/bin:${PATH}")"
grep -q 'dry-run: dracut -f' <<<"$same_out" \
    && fail "unchanged dracut drop-in rebuilt initramfs: ${same_out}"
grep -q 'write ' <<<"$same_out" \
    && fail "unchanged dracut drop-in was rewritten: ${same_out}"

printf 'force_drivers+=" hv_vmbus "\n' >"$dracut_dest"
changed_out="$(VIRT_NAME=microsoft DOTFILES_DRY_RUN=1 HYPERV_DRACUT_CONF="$dracut_dest" \
    run_module "${work}/bin:${PATH}")"
grep -q 'dry-run: dracut -f' <<<"$changed_out" \
    || fail "changed dracut drop-in did not rebuild: ${changed_out}"

bad_out="$(VIRT_NAME=microsoft DOTFILES_DRY_RUN=1 HYPERV_DRACUT_CONF=/etc/dracut.conf.d/hyperv-guest.conf \
    run_module "${work}/bin:${PATH}" || true)"
grep -q 'HYPERV_DRACUT_CONF must sit under /tmp' <<<"$bad_out" \
    || fail "override outside /tmp was accepted: ${bad_out}"

printf '%s\n' "hyperv-guest ok"
