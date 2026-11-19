# Version comes from rpms/build.sh. The bootstrap lives in bootstrap.sh
# because a three-stage PGO build has to keep its trees across rpmbuild runs.
%global debug_package %{nil}
%global _prefix /usr/local

Name:           homelab-llvm
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        LLVM 23 toolchain built by itself for the homelab prefix
License:        Apache-2.0 WITH LLVM-exception
URL:            https://llvm.org
Source0:        bootstrap.sh
BuildRequires:  cmake ninja gcc gcc-c++ python lib64z-devel lib64zstd-devel lib64xml2-devel lib64ncurses-devel

%description
Clang, LLD, compiler-rt, libc++, libc++abi, and libunwind. Stage 3 is
built by stage 2 with ThinLTO and an IR profile from compiling Clang.
Files install under /usr/local. The driver defaults to lld and libstdc++.

%prep
cp %{SOURCE0} .

%build
bash bootstrap.sh --tag %{pkg_tag} --prefix %{_prefix} --march znver1

%install
cache="${HOME}/builds/homelab-llvm/%{pkg_version}/destdir"
[[ -d "$cache" ]] || {
    printf 'missing install tree %s\n' "$cache" >&2
    exit 1
}
mkdir -p %{buildroot}
cp -a "${cache}/." %{buildroot}/
find %{buildroot} \( -type f -o -type l \) -printf '"%p"\n' | sed 's|"%{buildroot}|"|' > %{_builddir}/%{name}.files

%files -f %{_builddir}/%{name}.files
