#!/usr/bin/env bash
# Minecraft 26+ instances get Temurin 25. Older instances keep their Java.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
module="${HERE}/../modules/desktop/install-gaming-packages.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export DOTFILES_HOME="${work}/home"
unset REPO_ROOT DOTFILES_ROOT DOTFILES_LIB_LOADED
setup_root="$(realpath "${HERE}/../..")"
dotfiles=""
for candidate in \
    "${HERE}/../../../dot-files" \
    /home/dragon/git-workspace/homelab/dot-files \
    /home/dragon/dot-files; do
    if [[ -d "${candidate}/bashrc.d" ]]; then
        dotfiles="$(realpath "$candidate")"
        break
    fi
done
[[ -n "$dotfiles" ]] || {
    printf 'missing dot-files checkout\n' >&2
    exit 1
}
mkdir -p "${DOTFILES_HOME}/.config/dot-files"
printf 'dot-files=%s\nmachine-setup=%s\n' "$dotfiles" "$setup_root" \
    >"${DOTFILES_HOME}/.config/dot-files/checkouts"
# shellcheck disable=SC1090
. "$module"

root="${DOTFILES_HOME}/games/multi-mc"
new="${root}/instances/Fabric-Primary-26.3"
old="${root}/instances/Fabric_Primary1"
admin="${root}/instances/admin"
skip="${root}/instances/_LAUNCHER_TEMP"
mkdir -p "$new" "$old" "$admin" "$skip"

write_pack() {
    local dir="$1"
    local version="$2"
    printf '{"components":[{"uid":"net.minecraft","version":"%s"}]}\n' "$version" \
        >"${dir}/mmc-pack.json"
}

write_cfg() {
    local dir="$1"
    cat >"${dir}/instance.cfg" <<'EOF'
OverrideJavaLocation=false
name=fixture
EOF
}

write_pack "$new" "26.3"
write_pack "$old" "1.19.2"
write_pack "$admin" "1.19.2"
write_cfg "$new"
write_cfg "$old"
write_cfg "$admin"
printf 'not json\n' >"${skip}/mmc-pack.json"
printf 'OverrideJavaLocation=false\n' >"${skip}/instance.cfg"

[[ "$(minecraft_major "${new}/mmc-pack.json")" == "26" ]]
[[ "$(minecraft_major "${old}/mmc-pack.json")" == "1" ]]
if minecraft_major "${work}/missing.json" >/dev/null 2>&1; then
    printf 'missing pack was accepted\n' >&2
    exit 1
fi

point_multimc_java25 "$root"

grep -qx 'OverrideJavaLocation=true' "${new}/instance.cfg"
grep -qx "JavaPath=${TEMURIN_JAVA}" "${new}/instance.cfg"
grep -qx 'OverrideJavaLocation=false' "${old}/instance.cfg"
if grep -q '^JavaPath=' "${old}/instance.cfg"; then
    printf '1.19.2 instance gained a JavaPath\n' >&2
    exit 1
fi
grep -qx 'OverrideJavaLocation=false' "${admin}/instance.cfg"
grep -qx 'OverrideJavaLocation=false' "${skip}/instance.cfg"

before="$(cat "${new}/instance.cfg")"
point_multimc_java25 "$root"
after="$(cat "${new}/instance.cfg")"
[[ "$before" == "$after" ]]

export DOTFILES_DRY_RUN=1
printf 'OverrideJavaLocation=false\nname=fixture\n' >"${new}/instance.cfg"
point_multimc_java25 "$root" >/dev/null
grep -qx 'OverrideJavaLocation=false' "${new}/instance.cfg"

echo ok
