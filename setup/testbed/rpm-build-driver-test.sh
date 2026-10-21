#!/usr/bin/env bash
# The driver names both RPM arches for every package, and a second run
# leaves an RPM that is already in the output directory.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
driver="${repo}/rpms/build.sh"
packages="${repo}/rpms/packages.txt"
fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

[[ -x "$driver" ]] || fail "build.sh is not executable"
out="$(bash "$driver" --dry-run)"
while IFS= read -r name || [[ -n "$name" ]]; do
    name="${name%%#*}"
    name="${name#"${name%%[![:space:]]*}"}"
    [[ -z "$name" ]] && continue
    grep -F -- "--target x86_64 ${name} " <<<"$out" >/dev/null \
        || fail "dry-run missed x86_64 for ${name}"
    grep -F -- "--target znver1 ${name} " <<<"$out" >/dev/null \
        || fail "dry-run missed znver1 for ${name}"
done <"$packages"
grep -F 'rpmbuild' <<<"$out" >/dev/null || fail "dry-run did not name rpmbuild"
grep -E 'cmake|meson|configure' <<<"$out" && fail "dry-run compiled a project"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "${work}/rpms/fixture" "${work}/bin" "${work}/versions"
printf 'fixture FIXTURE_TAG full\n' >"${work}/rpms/versions.map"
printf 'FIXTURE_TAG=1\nHYPRLAND_TAG=v0.0.0\n' >"${work}/versions/versions.conf"
printf 'fixture\n' >"${work}/rpms/packages.txt"
# The driver looks for specs next to itself. Point a copy of the driver
# at this tree by passing --packages, --map, --versions, and --out, and
# by placing the spec where the real driver expects: under its own root.
# A fixture spec lives in the real tree only for this run, then goes.
spec="${work}/driver-spec"
mkdir -p "${repo}/rpms/fixture"
cleanup_spec() {
    rm -rf "${repo}/rpms/fixture" "$work"
}
trap cleanup_spec EXIT
cat >"${repo}/rpms/fixture/fixture.spec" <<'EOF'
Name:           fixture
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        fixture
License:        MIT
Source0:        fixture.c

%description
%{summary}

%prep
cp %{SOURCE0} .

%build
%{homelab_cc} %{homelab_cflags} -o fixture fixture.c

%install
mkdir -p %{buildroot}%{_prefix}/bin
install -m 0755 fixture %{buildroot}%{_prefix}/bin/fixture

%files
%{_prefix}/bin/fixture
EOF
printf 'int main(void) { return 0; }\n' >"${repo}/rpms/fixture/fixture.c"
printf 'fixture\n' >"${work}/packages.txt"
cat "${repo}/rpms/versions.map" >"${work}/map"
printf 'fixture FIXTURE_TAG full\n' >>"${work}/map"
printf 'FIXTURE_TAG=1\n' >>"${work}/versions.conf"
cp "${repo}/setup/versions.conf" "${work}/versions.conf"
printf '\nFIXTURE_TAG=1\n' >>"${work}/versions.conf"

printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${RPMBUILD_LOG}"\nexit 0\n' >"${work}/bin/rpmbuild"
chmod 0755 "${work}/bin/rpmbuild"
: >"${work}/rpmbuild.log"

PATH="${work}/bin:${PATH}" RPMBUILD_LOG="${work}/rpmbuild.log" \
    bash "$driver" --packages "${work}/packages.txt" --map "${work}/map" \
    --versions "${work}/versions.conf" --out "${work}/out"
grep -F -- '--target x86_64' "${work}/rpmbuild.log" >/dev/null || fail "fixture missed x86_64"
grep -F -- '--target znver1' "${work}/rpmbuild.log" >/dev/null || fail "fixture missed znver1"
mkdir -p "${work}/out/x86_64" "${work}/out/znver1"
: >"${work}/out/x86_64/fixture-1-1.x86_64.rpm"
: >"${work}/out/znver1/fixture-1-1.znver1.rpm"
: >"${work}/rpmbuild.log"
PATH="${work}/bin:${PATH}" RPMBUILD_LOG="${work}/rpmbuild.log" \
    bash "$driver" --packages "${work}/packages.txt" --map "${work}/map" \
    --versions "${work}/versions.conf" --out "${work}/out"
[[ ! -s "${work}/rpmbuild.log" ]] || fail "second build called rpmbuild: $(cat "${work}/rpmbuild.log")"

if command -v rpmbuild >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1; then
    real="${work}/real"
    mkdir -p "$real"
    env -u RPMBUILD_LOG PATH="/usr/bin:/bin:${PATH}" \
        bash "$driver" --packages "${work}/packages.txt" --map "${work}/map" \
        --versions "${work}/versions.conf" --out "$real"
    [[ -f "${real}/x86_64/fixture-1-1.x86_64.rpm" ]] || fail "missing x86_64 fixture rpm"
    [[ -f "${real}/znver1/fixture-1-1.znver1.rpm" ]] || fail "missing znver1 fixture rpm"
fi

rm -rf "${repo}/rpms/fixture"
printf 'rpm build driver ok.\n'
