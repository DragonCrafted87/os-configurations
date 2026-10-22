# Version and compiler flags come from rpms/build.sh.
%global debug_package %{nil}
%global _prefix /usr/local

Name:           homelab-libinput
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        libinput for the homelab /usr/local prefix
License:        MIT
URL:            https://gitlab.freedesktop.org/libinput/libinput/-
Source0:        https://gitlab.freedesktop.org/libinput/libinput/-/archive/%{pkg_tag}/libinput-%{pkg_tag}.tar.gz
BuildRequires:  meson ninja gcc gcc-c++ pkgconf

%description
libinput built from the pin in setup/versions.conf. Files install under /usr/local.

%prep
%autosetup -n libinput-%{pkg_version}
python3 %{_sourcedir}/../gcc14-prep.py .
%build
export CC="%{homelab_cc}"
export CXX="%{homelab_cxx}"
export CFLAGS="%{homelab_cflags}"
export CXXFLAGS="%{homelab_cxxflags}"
export PKG_CONFIG_PATH="%{_prefix}/lib64/pkgconfig:%{_prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="%{_prefix}/lib64:%{_prefix}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
meson setup build . --prefix=%{_prefix} --libdir=lib64 --buildtype=release \
    --pkg-config-path="%{_prefix}/lib64/pkgconfig:%{_prefix}/lib/pkgconfig" \
    -Dtests=false -Ddocumentation=false -Ddebug-gui=false -Dlibwacom=false
meson compile -C build

%install
DESTDIR=%{buildroot} meson install -C build
find %{buildroot} -name '*.la' -delete
find %{buildroot} \( -type f -o -type l \) -printf '"%p"\n' | sed 's|"%{buildroot}|"|' > %{_builddir}/%{name}.files
%files -f %{_builddir}/%{name}.files
