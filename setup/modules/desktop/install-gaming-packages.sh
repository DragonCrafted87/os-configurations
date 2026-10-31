#!/usr/bin/env bash
# Workstation-only gaming stack. Needs Rock Non-free for Steam.
# Proton games should launch through
# ~/.config/hypr/scripts/steam-proton-wrap.sh so they follow the active
# Hyprland display profile (desk / theater / laptop panel).

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

# The package symlinks this path in its posttrans script. We create the
# same link because that script is skipped on OpenMandriva.
TEMURIN_JAVA="/usr/lib/jvm/temurin-25-jdk/bin/java"
TEMURIN_PACKAGE="temurin-25-jdk"

install_gaming_packages() {
    require_user
    ensure_packages \
        steam \
        wine \
        gamescope \
        dxvk \
        protonplus
}

ensure_ini_key() {
    local file="$1"
    local section="$2"
    local key="$3"
    local value="$4"
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        log "dry-run: ${file} [${section}] ${key}=${value}"
        return 0
    fi
    python3 - "$file" "$section" "$key" "$value" <<'PY'
import sys
from pathlib import Path

path, section, key, value = sys.argv[1:]
p = Path(path)
text = p.read_text() if p.exists() else ""
lines = text.splitlines()
header = f"[{section}]"
out = []
in_section = False
seen_section = False
written = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_section and not written:
            out.append(f"{key}={value}")
            written = True
        in_section = stripped == header
        if in_section:
            seen_section = True
        out.append(line)
        continue
    if in_section and stripped.startswith(f"{key}="):
        out.append(f"{key}={value}")
        written = True
        continue
    out.append(line)
if seen_section:
    if not written:
        out.append(f"{key}={value}")
else:
    if out and out[-1] != "":
        out.append("")
    out.append(header)
    out.append(f"{key}={value}")
p.parent.mkdir(parents=True, exist_ok=True)
new = "\n".join(out) + "\n"
if new != text:
    p.write_text(new)
PY
}

looks_like_multimc() {
    local d="$1"
    [[ -d "$d" ]] || return 1
    [[ -f "${d}/multimc.cfg" ]] && return 0
    [[ -x "${d}/MultiMC" || -x "${d}/multimc" || -x "${d}/bin/multimc" || -x "${d}/MultiMC5" ]] && return 0
    return 1
}

find_multimc_root() {
    local d
    for d in \
        "${DOTFILES_HOME}/games/multi-mc" \
        "${DOTFILES_HOME}/games/MultiMC" \
        "${DOTFILES_HOME}/games/multimc" \
        "${DOTFILES_HOME}/Games/MultiMC" \
        "${DOTFILES_HOME}/MultiMC" \
        "${DOTFILES_HOME}/multimc" \
        "${DOTFILES_HOME}/.local/share/multimc" \
        "${DOTFILES_HOME}/.multimc"; do
        if looks_like_multimc "$d"; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    shopt -s nullglob
    for d in "${DOTFILES_HOME}/games"/*; do
        if looks_like_multimc "$d"; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    return 1
}

rewrite_multimc_paths() {
    local cfg="$1"
    local root="$2"
    [[ -f "$cfg" ]] || return 0
    python3 - "$cfg" "$root" <<'PY'
import sys
from pathlib import Path

cfg = Path(sys.argv[1])
root = sys.argv[2].rstrip("/")
text = cfg.read_text()
old_needles = (
    "/games/MultiMC",
    "/games/multimc",
    "/Games/MultiMC",
)
new = text
for needle in old_needles:
    new = new.replace(needle, "/games/multi-mc")
if new != text:
    cfg.write_text(new)
PY
}

# Minecraft 26+ needs Java 25. Older instances keep the global JavaPath.
minecraft_major() {
    python3 - "$1" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(1)
try:
    data = json.loads(path.read_text())
except json.JSONDecodeError:
    raise SystemExit(1)
version = ""
for comp in data.get("components") or []:
    if comp.get("uid") == "net.minecraft":
        version = str(comp.get("version") or "")
        break
major = version.split(".", 1)[0]
if not major.isdigit():
    raise SystemExit(1)
print(major)
PY
}

install_temurin_25_rpm() {
    local arch repo dest
    arch="$(rpm --eval '%{_arch}')"
    case "$arch" in
        x86_64 | aarch64) ;;
        *)
            die "Temurin 25 has no RPM for ${arch}"
            ;;
    esac
    # Adoptium publishes no OpenMandriva tree. The RHEL 9 RPM is the
    # temurin-25-jdk package. OpenMandriva's releasever is 6.0, so a
    # $ID/$releasever repo URL does not resolve. The RPM bytes come
    # from the Pulp cache of that Adoptium tree. The gpg key stays
    # on Adoptium.
    repo="https://pulp.stealthdragonland.net/pulp/content/adoptium/rhel/9/${arch}/"
    log "install ${TEMURIN_PACKAGE} from ${repo}"
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        printf 'dry-run: dnf download %s\n' "$TEMURIN_PACKAGE"
        printf 'dry-run: rpm -Uvh --nodeps --noscripts %s\n' "$TEMURIN_PACKAGE"
        return 0
    fi
    dest="$(mktemp -d)"
    dnf download -y --destdir "$dest" \
        --repofrompath "adoptium,${repo}" \
        --setopt=adoptium.gpgcheck=1 \
        --setopt=adoptium.gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public \
        "$TEMURIN_PACKAGE"
    # Adoptium returns 403 to urllib's default User-Agent.
    python3 - "${dest}/adoptium.gpg" <<'PY'
import sys
import urllib.request

request = urllib.request.Request(
    "https://packages.adoptium.net/artifactory/api/gpg/key/public",
    headers={"User-Agent": "machine-setup"},
)
with urllib.request.urlopen(request, timeout=60) as response:
    data = response.read()
with open(sys.argv[1], "wb") as handle:
    handle.write(data)
PY
    sudo rpm --import "${dest}/adoptium.gpg"
    # dnf cannot install this RPM here: it requires RHEL provides such as
    # libX11(x86-64) and dejavu-sans-fonts. The libraries are already
    # installed under OpenMandriva names. --noscripts skips the
    # alternatives registration, which would put Java 25 at /usr/bin/java
    # ahead of the Java 21 path from /etc/profile.d/90java.sh.
    sudo rpm -Uvh --nodeps --noscripts "${dest}/${TEMURIN_PACKAGE}"-*.rpm
    rm -rf "$dest"
}

ensure_temurin_25() {
    if rpm -q "$TEMURIN_PACKAGE" >/dev/null 2>&1 && [[ -x "$TEMURIN_JAVA" ]]; then
        log "${TEMURIN_PACKAGE} already installed"
        return 0
    fi
    if ! rpm -q "$TEMURIN_PACKAGE" >/dev/null 2>&1; then
        install_temurin_25_rpm
    fi
    if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
        printf 'dry-run: ln -sfn /usr/lib/jvm/java-25-temurin-jdk /usr/lib/jvm/temurin-25-jdk\n'
        return 0
    fi
    sudo ln -sfn /usr/lib/jvm/java-25-temurin-jdk /usr/lib/jvm/temurin-25-jdk
    if [[ ! -x "$TEMURIN_JAVA" ]]; then
        die "Temurin 25 java is missing after install"
    fi
    "$TEMURIN_JAVA" -version
}

point_multimc_java25() {
    local root="$1"
    local inst name major cfg
    [[ -d "${root}/instances" ]] || return 0
    for inst in "${root}/instances"/*/; do
        [[ -d "$inst" ]] || continue
        name="$(basename "$inst")"
        [[ "$name" == _* ]] && continue
        cfg="${inst}/instance.cfg"
        [[ -f "$cfg" ]] || continue
        if ! major="$(minecraft_major "${inst}/mmc-pack.json")"; then
            continue
        fi
        if ((major < 26)); then
            continue
        fi
        log "Java 25 for ${name}"
        if [[ "${DOTFILES_DRY_RUN:-0}" == "1" ]]; then
            printf 'dry-run: %s OverrideJavaLocation=true JavaPath=%s\n' "$cfg" "$TEMURIN_JAVA"
            continue
        fi
        python3 - "$cfg" "$TEMURIN_JAVA" <<'PY'
import sys
from pathlib import Path

path, java = sys.argv[1:]
updates = {
    "OverrideJavaLocation": "true",
    "JavaPath": java,
}
file = Path(path)
text = file.read_text()
seen = set()
out = []
for line in text.splitlines():
    key, sep, _value = line.partition("=")
    if sep and key in updates:
        out.append(f"{key}={updates[key]}")
        seen.add(key)
        continue
    out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={value}")
new = "\n".join(out) + "\n"
if new != text:
    file.write_text(new)
PY
    done
}

configure_multimc() {
    local root
    root="$(find_multimc_root || true)"
    if [[ -z "$root" ]]; then
        log "MultiMC not found; skip theme, desktop, and java"
        return 0
    fi
    log "MultiMC root ${root}"
    # The start script ldd's plugins only. bin/MultiMC still needs Qt XML.
    ensure_packages lib64qt5xml5
    ensure_temurin_25
    point_multimc_java25 "$root"
    ensure_dir "${root}/themes/custom"
    local src_json="${SETUP_FILES_DIR}/multimc/theme.json"
    local src_css="${SETUP_FILES_DIR}/multimc/themeStyle.css"
    if [[ -f "$src_json" ]]; then
        if [[ "${DOTFILES_DRY_RUN:-0}" != "1" ]]; then
            install -m 0644 "$src_json" "${root}/themes/custom/theme.json"
            install -m 0644 "$src_css" "${root}/themes/custom/themeStyle.css"
        fi
        log "write MultiMC custom theme"
    fi
    local cfg="${root}/multimc.cfg"
    if [[ -f "$cfg" ]]; then
        if [[ "${DOTFILES_DRY_RUN:-0}" != "1" ]]; then
            rewrite_multimc_paths "$cfg" "$root"
        fi
        ensure_ini_key "$cfg" General ApplicationTheme custom
        ensure_ini_key "$cfg" General IconTheme pe_colored
    fi

    local bin=""
    for candidate in "${root}/MultiMC" "${root}/multimc" "${root}/bin/multimc" "${root}/MultiMC5"; do
        if [[ -x "$candidate" ]]; then
            bin="$candidate"
            break
        fi
    done
    [[ -n "$bin" ]] || return 0

    local icon_src="${SETUP_FILES_DIR}/multimc/multimc.png"
    local icon_dest="${DOTFILES_HOME}/.local/share/icons/hicolor/scalable/apps/multimc.png"
    local icon_svg="${DOTFILES_HOME}/.local/share/icons/hicolor/scalable/apps/multimc.svg"
    if [[ "${DOTFILES_DRY_RUN:-0}" != "1" ]]; then
        rm -f "$icon_svg"
    fi
    if [[ -f "$icon_src" && "${DOTFILES_DRY_RUN:-0}" != "1" ]]; then
        ensure_dir "$(dirname "$icon_dest")"
        install -m 0644 "$icon_src" "$icon_dest"
        if command -v gtk-update-icon-cache >/dev/null 2>&1; then
            gtk-update-icon-cache -f "${DOTFILES_HOME}/.local/share/icons/hicolor" >/dev/null 2>&1 || true
        fi
    fi

    local desk="/tmp/multimc.desktop"
    cat >"$desk" <<EOF
[Desktop Entry]
Type=Application
Name=MultiMC
Comment=Minecraft launcher
Exec=${bin}
Icon=multimc
Terminal=false
Categories=Game;
StartupNotify=true
Path=${root}
EOF
    if [[ "${DOTFILES_DRY_RUN:-0}" != "1" ]]; then
        install_user_desktop "$desk"
    fi
    rm -f "$desk"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    install_gaming_packages
    configure_multimc
fi
