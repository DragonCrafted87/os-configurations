#!/usr/bin/env bash
# BOINC install helpers: runtime libraries, RPM version, data dir.
# Sourced from install-boinc.sh. Not a standalone role module.


set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

BOINC_VERSION="${BOINC_VERSION:?set BOINC_VERSION in setup/versions.conf}"
BOINC_PREFIX="${BOINC_PREFIX:-/usr/local}"
BOINC_DIR="${DOTFILES_HOME}/.local/share/boinc"

# Shared libraries boincmgr links. Reset removes them. The RPM version
# check skips a second install of boinc itself, so every live role run
# installs these libraries again.
install_runtime_deps() {
    local had_icd=0
    # Mesa Rusticl is the OpenCL platform for the 7900 XTX. Reset removes
    # it, so every live role run installs it again. The client dlopens
    # libOpenCL.so.
    if [[ -f /etc/OpenCL/vendors/rusticl.icd ]]; then
        had_icd=1
    fi
    ensure_packages \
        lib64wx_baseu3.2_0 \
        lib64wx_baseu_net3.2_0 \
        lib64wx_gtk3u_core3.2_0 \
        lib64wx_gtk3u_html3.2_0 \
        lib64wx_gtk3u_webview3.2_0 \
        lib64RusticlOpenCL
    BOINC_OPENCL_NEW=0
    if [[ "$had_icd" -eq 0 && -f /etc/OpenCL/vendors/rusticl.icd ]]; then
        BOINC_OPENCL_NEW=1
    fi
}

boinc_opencl_linked() {
    local lib
    for lib in \
        "${BOINC_PREFIX}/lib/libboinc_opencl.so" \
        "${BOINC_PREFIX}/lib64/libboinc_opencl.so"; do
        [[ -e "$lib" ]] || continue
        ldd "$lib" 2>/dev/null | grep -q 'libOpenCL\.so' && return 0
    done
    return 1
}

boinc_already_built() {
    local query version vendor
    query="$(rpm -q --queryformat '%{VERSION} %{VENDOR}' boinc 2>/dev/null)" || return 1
    version="${query%% *}"
    vendor="${query#* }"
    [[ "$version" == "$BOINC_VERSION" && "$vendor" == "homelab" ]] || return 1
    boinc_opencl_linked
}

remove_stale_path_cmds() {
    local stale
    for stale in find-boinccmd.sh find-boinccmd boinc-session.sh boinc-session boinc-config.sh boinc-status.sh boinc-status-all.sh; do
        if [[ -e "/usr/local/bin/${stale}" ]]; then
            run sudo rm -f "/usr/local/bin/${stale}"
        fi
    done
    if [[ -e "${DOTFILES_HOME}/bin/boincmgr" ]]; then
        run rm -f "${DOTFILES_HOME}/bin/boincmgr"
    fi
}

write_config_properties() {
    local conf_dir=/etc/boinc-client
    local conf="${conf_dir}/config.properties"
    local tmp
    run sudo mkdir -p "$conf_dir"
    tmp="$(mktemp)"
    printf 'data_dir=%s\n' "$BOINC_DIR" >"$tmp"
    if [[ -f "$conf" ]] && cmp -s "$tmp" "$conf"; then
        rm -f "$tmp"
        return 0
    fi
    log "write ${conf} data_dir=${BOINC_DIR}"
    run sudo install -m 0644 "$tmp" "$conf"
    rm -f "$tmp"
}
