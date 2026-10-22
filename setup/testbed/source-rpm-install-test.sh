#!/usr/bin/env bash
# Hyprland and BOINC install from RPMs. A dry run logs dnf and does not
# compile. A distro hyprland package, or a matching homelab version,
# does not log dnf.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repo="$(realpath "$repo")"
hypr="${repo}/setup/modules/desktop/install-hyprland-source.sh"
boinc="${repo}/setup/modules/compute/install-boinc.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

home="${work}/home"
dots="${work}/dots"
prefix="${work}/prefix"
mkdir -p "${dots}/bashrc.d" "${home}/.config/dot-files" "${prefix}/lib" "${work}/bin"
printf '# fixture\n' >"${dots}/bashrc.d/compiler.bashrc"
printf 'dot-files=%s\nmachine-setup=%s\n' "$dots" "$repo" \
    >"${home}/.config/dot-files/checkouts"
printf 'server\n' >"${home}/.config/dot-files/role"
: >"${prefix}/lib/libboinc_opencl.so"
: >"${work}/dnf.log"
: >"${work}/sudo.log"

cat >"${work}/bin/rpm" <<'EOF'
#!/bin/bash
fmt=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "--queryformat" || "$prev" == "--qf" ]]; then
        fmt="$arg"
    fi
    prev="$arg"
done
pkg="${*: -1}"
vendor=""
version=""
case "$pkg" in
    hyprland)
        case "${HYPR_RPM:-missing}" in
            distro)
                vendor="OpenMandriva"
                version="0.41.2"
                ;;
            match)
                vendor="homelab"
                version="${HYPRLAND_SOURCE_VERSION:?}"
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    boinc)
        case "${BOINC_RPM:-missing}" in
            match)
                vendor="homelab"
                version="${BOINC_VERSION:?}"
                ;;
            old)
                vendor="homelab"
                version="0.0.0"
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
out="$fmt"
out="${out//"%{VENDOR}"/$vendor}"
out="${out//"%{VERSION}"/$version}"
printf '%s\n' "$out"
EOF
cat >"${work}/bin/dnf" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${DNF_LOG:?}"
EOF
cat >"${work}/bin/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"${SUDO_LOG:?}"
exit 0
EOF
cat >"${work}/bin/systemctl" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"${work}/bin/ldd" <<'EOF'
#!/bin/bash
if [[ "${BOINC_LINKED:-0}" == "1" ]]; then
    printf '%s\n' "libOpenCL.so.1 => /lib64/libOpenCL.so.1"
else
    printf '%s\n' "libstdc++.so.6 => /lib64/libstdc++.so.6"
fi
EOF
chmod 0755 "${work}/bin/rpm" "${work}/bin/dnf" "${work}/bin/sudo" \
    "${work}/bin/systemctl" "${work}/bin/ldd"

export DOTFILES_HOME="$home"
export DOTFILES_USER
DOTFILES_USER="$(id -un)"
export DOTFILES_DRY_RUN=1
export BOINC_PREFIX="$prefix"
export BOINC_LINKED=1
export DNF_LOG="${work}/dnf.log"
export SUDO_LOG="${work}/sudo.log"
export PATH="${work}/bin:${PATH}"

assert_no_compile() {
    local out="$1"
    if grep -E '(^|[[:space:]])(cmake|meson)([[:space:]]|$)|[.]/configure' <<<"$out" >/dev/null; then
        fail "dry-run compiled: ${out}"
    fi
}

assert_dnf_idle() {
    [[ ! -s "${work}/dnf.log" ]] || fail "dnf ran: $(cat "${work}/dnf.log")"
    if grep -F 'dnf ' "${work}/sudo.log" >/dev/null; then
        fail "sudo ran dnf: $(cat "${work}/sudo.log")"
    fi
}

run_hypr() {
    local mode="$1"
    HYPR_RPM="$mode" bash "$hypr"
}

out="$(run_hypr distro 2>&1)" || fail "distro hyprland exited nonzero: ${out}"
grep -F 'distro package still installed' <<<"$out" >/dev/null || fail "distro skip missing: ${out}"
grep -F 'dnf install' <<<"$out" && fail "distro package called dnf: ${out}"
assert_no_compile "$out"
assert_dnf_idle

out="$(run_hypr match 2>&1)" || fail "matching hyprland exited nonzero: ${out}"
grep -F 'prefix already current' <<<"$out" >/dev/null || fail "match skip missing: ${out}"
grep -F 'dnf install' <<<"$out" && fail "matching package called dnf: ${out}"
assert_no_compile "$out"
assert_dnf_idle

out="$(run_hypr missing 2>&1)" || fail "missing hyprland exited nonzero: ${out}"
grep -F 'dnf install -y' <<<"$out" >/dev/null || fail "missing package did not log dnf: ${out}"
for name in hyprland hyprdesk hyprcapture hypridle hyprlock hyprpaper \
    hyprpicker hyprpolkitagent hyprpwcenter hyprsunset hyprsysteminfo \
    hyprshutdown hyprland-guiutils hyprland-qt-support hyprqt6engine \
    xdg-desktop-portal-hyprland; do
    grep -F "$name" <<<"$out" >/dev/null || fail "dnf list omitted ${name}: ${out}"
done
assert_no_compile "$out"
assert_dnf_idle

run_boinc() {
    local mode="$1"
    BOINC_RPM="$mode" bash "$boinc"
}

out="$(run_boinc match 2>&1)" || fail "matching boinc exited nonzero: ${out}"
grep -F 'already installed' <<<"$out" >/dev/null || fail "boinc match missing: ${out}"
grep -F 'dnf install' <<<"$out" && fail "matching boinc called dnf: ${out}"
assert_no_compile "$out"
assert_dnf_idle

out="$(run_boinc old 2>&1)" || fail "old boinc exited nonzero: ${out}"
grep -F 'dnf install -y boinc' <<<"$out" >/dev/null || fail "old boinc did not log dnf: ${out}"
assert_no_compile "$out"
assert_dnf_idle

printf 'source rpm install ok.\n'
