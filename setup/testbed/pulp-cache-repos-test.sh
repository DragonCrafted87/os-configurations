#!/usr/bin/env bash
# Rock, Brave, Visual Studio Code, and Temurin point at the Pulp cache.
# A dry run leaves the Rock file alone. A second run does not rewrite it.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repo="$(realpath "$repo")"
rock="${repo}/setup/modules/common/point-rock-repos-at-pulp.sh"
brave="${repo}/setup/modules/desktop/install-brave.sh"
vscode="${repo}/setup/modules/desktop/install-workstation-packages.sh"
gaming="${repo}/setup/modules/desktop/install-gaming-packages.sh"
roles="${repo}/setup/roles.conf"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

home="${work}/home"
dots="${work}/dots"
mkdir -p "${dots}/bashrc.d" "${home}/.config/dot-files"
printf 'dot-files=%s\nmachine-setup=%s\n' "$(realpath "$dots")" "$repo" \
    >"${home}/.config/dot-files/checkouts"
export DOTFILES_HOME="$home"
export DOTFILES_USER="$(id -un)"
export HOME="$home"
export DOTFILES_TEST_SOURCE=1
unset DOTFILES_LIB_LOADED
unset DOTFILES_DRY_RUN

# shellcheck disable=SC1090
. "$rock"
# shellcheck disable=SC1090
. "$brave"
# shellcheck disable=SC1090
. "$vscode"

dest="${work}/openmandriva-rock-znver1.repo"
cat >"$dest" <<'EOF'
[rock-znver1]
name="OpenMandriva Rock - znver1"
baseurl=http://mirror.openmandriva.org/rock/repository/znver1/main/release/
	http://abf-downloads.openmandriva.org/rock/repository/znver1/main/release/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-OpenMandriva
enabled=1

[rock-znver1-debuginfo]
name="OpenMandriva Rock - znver1 - Debug"
baseurl=http://mirror.openmandriva.org/rock/repository/znver1/debug_main/release/
	http://abf-downloads.openmandriva.org/rock/repository/znver1/debug_main/release/
gpgcheck=1
enabled=0
EOF

before="$(cat "$dest")"
DOTFILES_DRY_RUN=1
write_rock_repo "$dest" znver1 >/dev/null
[[ "$(cat "$dest")" == "$before" ]] || fail "dry-run rewrote the Rock file"

DOTFILES_DRY_RUN=0
write_rock_repo "$dest" znver1
grep -F 'baseurl=https://pulp.stealthdragonland.net/pulp/content/rock/znver1/main/release/' "$dest" >/dev/null \
    || fail "Rock baseurl was not rewritten"
abf_count="$(grep -c 'abf-downloads' "$dest")"
[[ "$abf_count" == "1" ]] || fail "the enabled Rock repo still lists the second mirror"
grep -F 'gpgcheck=1' "$dest" >/dev/null || fail "gpgcheck was dropped"
grep -F 'debug_main/release/' "$dest" >/dev/null || fail "debuginfo baseurl was rewritten"
count="$(awk -F= '/^baseurl=/{c++} END {print c+0}' "$dest")"
[[ "$count" == "2" ]] || fail "expected one baseurl line per section, found ${count}"

stamp="$(stat -c '%Y' "$dest")"
sleep 1
write_rock_repo "$dest" znver1
[[ "$(stat -c '%Y' "$dest")" == "$stamp" ]] || fail "second run rewrote a matching Rock file"

brave_dest="${work}/brave-browser.repo"
printf '[brave-browser]\nbaseurl=https://brave-browser-rpm-release.s3.brave.com/x86_64\n' >"$brave_dest"
DOTFILES_DRY_RUN=1
write_brave_repo "$brave_dest"
grep -F 's3.brave.com/x86_64' "$brave_dest" >/dev/null || fail "dry-run rewrote Brave"
DOTFILES_DRY_RUN=0
write_brave_repo "$brave_dest"
[[ "$(cat "$brave_dest")" == "$(brave_repo_body)" ]] || fail "Brave repo body drifted"
grep -F 'baseurl=https://pulp.stealthdragonland.net/pulp/content/brave/x86_64/' "$brave_dest" >/dev/null \
    || fail "Brave baseurl is missing"
grep -F 'gpgkey=https://brave-browser-rpm-release.s3.brave.com/brave-core.asc' "$brave_dest" >/dev/null \
    || fail "Brave gpg key moved off the vendor host"
stamp="$(stat -c '%Y' "$brave_dest")"
sleep 1
write_brave_repo "$brave_dest"
[[ "$(stat -c '%Y' "$brave_dest")" == "$stamp" ]] || fail "second run rewrote a matching Brave file"

code_dest="${work}/vscode.repo"
DOTFILES_DRY_RUN=1
write_vscode_repo "$code_dest"
[[ ! -e "$code_dest" ]] || fail "dry-run created the Visual Studio Code repo"
DOTFILES_DRY_RUN=0
write_vscode_repo "$code_dest"
grep -F 'baseurl=https://pulp.stealthdragonland.net/pulp/content/vscode/' "$code_dest" >/dev/null \
    || fail "Visual Studio Code baseurl is missing"
grep -F 'gpgkey=https://packages.microsoft.com/keys/microsoft.asc' "$code_dest" >/dev/null \
    || fail "Visual Studio Code gpg key moved off the vendor host"

grep -F 'baseurl=https://pulp.stealthdragonland.net/pulp/content/brave/x86_64/' "$brave" >/dev/null \
    || fail "install-brave.sh does not name the Pulp baseurl"
grep -F 'baseurl=https://pulp.stealthdragonland.net/pulp/content/vscode/' "$vscode" >/dev/null \
    || fail "install-workstation-packages.sh does not name the Pulp baseurl"
grep -F 'https://pulp.stealthdragonland.net/pulp/content/adoptium/rhel/9/${arch}/' "$gaming" >/dev/null \
    || fail "Temurin download does not use the Pulp base path"
grep -F 'packages.adoptium.net/artifactory/api/gpg/key/public' "$gaming" >/dev/null \
    || fail "Temurin gpg key moved off Adoptium"

awk '
    /^\[common\]/ { in_common=1; next }
    /^\[/ { in_common=0 }
    in_common && $0 == "enable-rock-repos" { rock=NR }
    in_common && $0 == "point-rock-repos-at-pulp" { point=NR }
    END { exit !(rock && point && point > rock) }
' "$roles" || fail "common role does not point Rock at Pulp after enable-rock-repos"

printf 'pulp cache repos ok.\n'
