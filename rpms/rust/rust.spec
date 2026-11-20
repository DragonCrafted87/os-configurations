# Version comes from rpms/build.sh. The bootstrap keeps its tree across
# rpmbuild runs so a second package build does not compile Rust again.
%global debug_package %{nil}
%global _prefix /usr/local

Name:           homelab-rust
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        Rust built with homelab Clang against homelab LLVM
License:        Apache-2.0 OR MIT
URL:            https://www.rust-lang.org/
Source0:        bootstrap.sh
BuildRequires:  homelab-llvm python git cmake ninja
Requires:       homelab-llvm

%description
Rustc, Cargo, rustfmt, Clippy, and rust-analyzer. The compiler links
the shared libLLVM from homelab-llvm. Files install under /usr/local.

%prep
cp %{SOURCE0} .

%build
bash bootstrap.sh --version %{pkg_version} --prefix %{_prefix}

%install
cache="${HOME}/builds/homelab-rust/%{pkg_version}/prefix"
[[ -d "$cache" ]] || {
    printf 'missing install tree %s\n' "$cache" >&2
    exit 1
}
mkdir -p %{buildroot}%{_prefix}
cp -a "${cache}/." %{buildroot}%{_prefix}/
find %{buildroot} \( -type f -o -type l \) -printf '"%p"\n' | sed 's|"%{buildroot}|"|' > %{_builddir}/%{name}.files

%files -f %{_builddir}/%{name}.files
