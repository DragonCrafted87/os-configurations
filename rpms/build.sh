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
    if [[ "$name" == "boinc" ]]; then
        cc="clang"
        cxx="clang++"
    else
        cc="gcc"
        cxx="g++"
    fi
    if [[ "$dry" -eq 0 && "$name" == "hyprdesk" ]]; then
        tar -C "${repo}/setup/files" -czf "${root}/hyprdesk/hyprdesk.tar.gz" hyprdesk
    fi
    for arch in x86_64 znver1; do
        if [[ "$arch" == "znver1" ]]; then
            march="znver1"
        else
            march="x86-64"
        fi
        cflags="-O2 -march=${march}"
        # The shim uses string_view. BOINC's configure probes C++11, which
        # fails if that header is forced in.
        if [[ "$name" == "boinc" ]]; then
            cxxflags="${cflags}"
        else
            cxxflags="${cflags} -include ${root}/string_view_concat.hpp"
        fi
        rpm_file="${out}/${arch}/${rpm_name}-${version}-1.${arch}.rpm"
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
