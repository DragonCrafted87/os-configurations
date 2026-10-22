# Version and compiler flags come from rpms/build.sh.
%global debug_package %{nil}
%global _prefix /usr/local

Name:           wayland-protocols
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        wayland-protocols for the homelab /usr/local prefix
License:        MIT
URL:            https://gitlab.freedesktop.org/wayland/wayland-protocols/-
Source0:        https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/%{pkg_tag}/wayland-protocols-%{pkg_tag}.tar.gz
BuildRequires:  meson ninja gcc gcc-c++ pkgconf

%description
wayland-protocols built from the pin in setup/versions.conf. Files install under /usr/local.

%prep
%autosetup -n wayland-protocols-%{pkg_version}
%build
export CC="%{homelab_cc}"
export CXX="%{homelab_cxx}"
export CFLAGS="%{homelab_cflags}"
export CXXFLAGS="%{homelab_cxxflags}"
export PKG_CONFIG_PATH="%{_prefix}/lib64/pkgconfig:%{_prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
meson setup build . --prefix=%{_prefix} --libdir=lib64 --buildtype=release \
    --pkg-config-path="%{_prefix}/lib64/pkgconfig:%{_prefix}/lib/pkgconfig" \
    -Dtests=false
meson compile -C build

%install
DESTDIR=%{buildroot} meson install -C build
find %{buildroot} \( -type f -o -type l \) | sed "s|^%{buildroot}||" > %{_builddir}/%{name}.files
%files -f %{_builddir}/%{name}.files
