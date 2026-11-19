#!/usr/bin/env bash
# Build every spec in packages.txt for x86_64 and znver1.
# Versions come from setup/versions.conf. The specs do not pin them.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${root}/.." && pwd)"
packages_file="${root}/packages.txt"
versions_file="${repo}/setup/versions.conf"
map_file="${root}/versions.map"
out="${root}/out"
dry=0
nodeps=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --dry-run)
            dry=1
            shift
            ;;
        --nodeps)
            nodeps=1
            shift
            ;;
        --packages)
            packages_file="$2"
            shift 2
            ;;
        --versions)
            versions_file="$2"
            shift 2
            ;;
        --map)
            map_file="$2"
            shift 2
            ;;
        --out)
            out="$2"
            shift 2
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

declare -A conf=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || continue
    conf["${line%%=*}"]="${line#*=}"
done <"$versions_file"

declare -A transform_of=()
declare -A key_of=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" ]] && continue
    read -r name key transform <<<"$line"
    key_of["$name"]="$key"
    transform_of["$name"]="$transform"
done <"$map_file"

rpm_version() {
    local transform="$1" tag="$2" version=""
    case "$transform" in
        strip_v) version="${tag#v}" ;;
        xkb) version="${tag#xkbcommon-}" ;;
        llvmorg) version="${tag#llvmorg-}" ;;
        full) version="${tag#v}" ;;
        fixed:*) version="${transform#fixed:}" ;;
        *)
            printf 'unknown version transform: %s\n' "$transform" >&2
            return 1
            ;;
    esac
    # RPM splits name-version-release on the hyphen.
    printf '%s\n' "${version//-/.}"
}

hyprland_version="$(rpm_version strip_v "${conf[HYPRLAND_TAG]}")"

mkdir -p "$out"

while IFS= read -r name || [[ -n "$name" ]]; do
    name="${name%%#*}"
    name="${name#"${name%%[![:space:]]*}"}"
    [[ -z "$name" ]] && continue
    [[ -n "${key_of[$name]:-}" ]] || {
        printf 'no versions.map row for %s\n' "$name" >&2
        exit 1
    }
    tag="${conf[${key_of[$name]}]:-}"
    [[ -n "$tag" ]] || {
        printf 'versions.conf has no %s\n' "${key_of[$name]}" >&2
        exit 1
    }
    version="$(rpm_version "${transform_of[$name]}" "$tag")"
    spec="${root}/${name}/${name}.spec"
    [[ -f "$spec" ]] || {
        printf 'missing spec %s\n' "$spec" >&2
        exit 1
    }
    rpm_name="$(awk '/^Name:/ { print $2; exit }' "$spec")"
    [[ -n "$rpm_name" ]] || rpm_name="$name"
    # homelab-llvm's clang is the compiler once it is installed. The LLVM
    # package itself bootstraps from the host gcc. Until that package is
    # installed, BOINC stays on the distro clang and the rest stay on gcc.
    if [[ -x /usr/local/bin/clang && "$name" != "llvm" ]]; then
        cc="/usr/local/bin/clang"
        cxx="/usr/local/bin/clang++"
    elif [[ "$name" == "boinc" ]]; then
        cc="clang"
        cxx="clang++"
    else
        cc="gcc"
        cxx="g++"
    fi
    if [[ "$dry" -eq 0 && "$name" == "hyprdesk" ]]; then
        tar -C "${repo}/setup/files" -czf "${root}/hyprdesk/hyprdesk.tar.gz" hyprdesk
    fi
    arch_list=()
    if [[ -f "${root}/${name}/arches" ]]; then
        while IFS= read -r arch_line || [[ -n "$arch_line" ]]; do
            arch_line="${arch_line%%#*}"
            arch_line="${arch_line#"${arch_line%%[![:space:]]*}"}"
            arch_line="${arch_line%"${arch_line##*[![:space:]]}"}"
            [[ -z "$arch_line" ]] && continue
            arch_list+=("$arch_line")
        done <"${root}/${name}/arches"
    else
        arch_list=(x86_64 znver1)
    fi
    for arch in "${arch_list[@]}"; do
        if [[ "$arch" == "znver1" ]]; then
            march="znver1"
        else
            march="x86-64"
        fi
        # Installed headers include pixman.h, drm_fourcc.h, and
        # pipewire/pipewire.h. Those directories are not on the default path.
        dep_cflags="$(pkg-config --cflags pixman-1 libdrm libpipewire-0.3 2>/dev/null || true)"
        cflags="-O2 -march=${march} ${dep_cflags}"
        # The shim uses string_view. BOINC and MakeMKV probe C++11, which
        # fails if that header is forced in.
        if [[ "$name" == "boinc" || "$name" == "makemkv" ]]; then
            cxxflags="${cflags}"
        else
            cxxflags="${cflags} -include ${root}/string_view_concat.hpp"
        fi
        release="$(awk '/^Release:/ { print $2; exit }' "$spec")"
        release="${release:-1}"
        rpm_file="${out}/${arch}/${rpm_name}-${version}-${release}.${arch}.rpm"
        top="${out}/top/${name}-${arch}"
        cmd=(
            rpmbuild -bb
            --target "$arch"
            --define "_topdir ${top}"
            --define "_sourcedir ${root}/${name}"
            --define "_specdir ${root}/${name}"
            --define "_rpmdir ${out}"
            --define "_prefix /usr/local"
            --define "pkg_version ${version}"
            --define "pkg_tag ${tag}"
            --define "hyprland_version ${hyprland_version}"
            --define "homelab_cc ${cc}"
            --define "homelab_cxx ${cxx}"
            --define "homelab_cflags ${cflags}"
            --define "homelab_cxxflags ${cxxflags}"
            --define "_build_name_fmt %%{ARCH}/%%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm"
            --define "_build_pkgcheck_set %{nil}"
            --define "_build_pkgcheck_srpm %{nil}"
        )
        if [[ "$nodeps" -eq 1 ]]; then
            cmd+=(--nodeps)
        fi
        cmd+=("$spec")
        if [[ "$dry" -eq 1 ]]; then
            printf 'rpmbuild -bb --target %s %s %s\n' "$arch" "$name" "$version"
            continue
        fi
        if [[ -f "$rpm_file" ]]; then
            printf 'keep %s\n' "$rpm_file"
            continue
        fi
        "${cmd[@]}"
    done
done <"$packages_file"
