# Version and compiler flags come from rpms/build.sh.
%global debug_package %{nil}
%global _prefix /usr/local

Name:           xcb-errors
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        xcb-errors for the homelab /usr/local prefix
License:        MIT
URL:            https://gitlab.freedesktop.org/xorg/lib/libxcb-errors/-
Source0:        https://gitlab.freedesktop.org/xorg/lib/libxcb-errors/-/archive/%{pkg_tag}/libxcb-errors-%{pkg_tag}.tar.gz
BuildRequires:  autoconf automake libtool gcc gcc-c++ pkgconf make xorg-x11-util-macros

%description
xcb-errors built from the pin in setup/versions.conf. Files install under /usr/local.

%prep
%autosetup -n libxcb-errors-%{pkg_tag}
%build
export CC="%{homelab_cc}"
export CXX="%{homelab_cxx}"
export CFLAGS="%{homelab_cflags}"
export CXXFLAGS="%{homelab_cxxflags}"
./autogen.sh --prefix=%{_prefix} --libdir=%{_prefix}/lib64
%make_build

%install
%make_install
find %{buildroot} \( -type f -o -type l \) | sed "s|^%{buildroot}||" > %{_builddir}/%{name}.files
%files -f %{_builddir}/%{name}.files
