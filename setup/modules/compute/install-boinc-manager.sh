#!/usr/bin/env bash
# BOINC Manager desktop launcher and Select-computer MRU.
# Sourced from install-boinc.sh. Not a standalone role module.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

# wxGTK ignores gtk-application-prefer-dark-theme. The launcher sets
# GTK_THEME. make install writes boinc.desktop; a second filename is a
# second BOINC Manager. Replace that file and drop boincmgr.desktop.
install_manager_desktop() {
    local src="${SETUP_FILES_DIR}/boinc/boinc.desktop"
    local apps="${BOINC_PREFIX:-/usr/local}/share/applications"
    local dest="${apps}/boinc.desktop"
    local user_stale="${DOTFILES_HOME}/.local/share/applications/boincmgr.desktop"
    local sys_stale="${apps}/boincmgr.desktop"
    local changed=0
    if [[ ! -f "$src" ]]; then
        return 0
    fi
    run sudo mkdir -p "$apps"
    if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
        run sudo install -m 0644 "$src" "$dest"
        changed=1
    fi
    if [[ -e "$user_stale" ]]; then
        run rm -f "$user_stale"
        changed=1
    fi
    if [[ -e "$sys_stale" ]]; then
        run sudo rm -f "$sys_stale"
        changed=1
    fi
    if [[ "$changed" -eq 0 || "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$apps" >/dev/null 2>&1 || true
        if [[ -d "${DOTFILES_HOME}/.local/share/applications" ]]; then
            update-desktop-database "${DOTFILES_HOME}/.local/share/applications" >/dev/null 2>&1 || true
        fi
    fi

    local icon_src="${SETUP_FILES_DIR}/boinc/boinc.png"
    local icon_dest="${DOTFILES_HOME}/.local/share/icons/hicolor/64x64/apps/boinc.png"
    if [[ -f "$icon_src" && "${DOTFILES_DRY_RUN:-0}" != "1" ]]; then
        ensure_dir "$(dirname "$icon_dest")"
        install -m 0644 "$icon_src" "$icon_dest"
    fi
}

# Manager stores the Select computer MRU in ~/.BOINC Manager.
# Names only; the shared rpc_password is the login for every host.
write_manager_computers() {
    local cfg="${DOTFILES_HOME}/.BOINC Manager"
    local list="$1"
    if command -v pgrep >/dev/null && pgrep -u "$(id -u)" -x boincmgr >/dev/null 2>&1; then
        warn "quit boincmgr so it does not overwrite ${cfg} on exit"
    fi
    python3 - "$cfg" "$list" <<'PY'
from pathlib import Path
import sys

cfg = Path(sys.argv[1])
hosts_path = Path(sys.argv[2])
wanted = []
seen = set()
for name in ("localhost", "127.0.0.1"):
    wanted.append(name)
    seen.add(name)
if hosts_path.is_file():
    for raw in hosts_path.read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        host = line.split()[0]
        if host not in seen:
            wanted.append(host)
            seen.add(host)

existing = []
other = []
section = None
if cfg.is_file():
    for line in cfg.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1]
            if section != "ComputerMRU":
                other.append(line)
            continue
        if section == "ComputerMRU":
            if "=" in line:
                existing.append(line.split("=", 1)[1].strip())
            continue
        other.append(line)

for host in existing:
    if host and host not in seen:
        wanted.append(host)
        seen.add(host)

lines = [l for l in other if l.strip() != ""]
if lines and lines[-1] != "":
    lines.append("")
lines.append("[ComputerMRU]")
for i, host in enumerate(wanted):
    lines.append(f"{i}={host}")
lines.append("")
cfg.write_text("\n".join(lines))
print(f"updated {cfg} with {len(wanted)} computers")
PY
}
