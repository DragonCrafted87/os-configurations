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
Source1:        https://gitlab.freedesktop.org/xorg/util/xcb-util-m4/-/archive/master/xcb-util-m4-master.tar.gz
BuildRequires:  autoconf automake libtool gcc gcc-c++ pkgconf make x11-util-macros

%description
xcb-errors built from the pin in setup/versions.conf. Files install under /usr/local.

%prep
%autosetup -n libxcb-errors-%{pkg_tag}
# The GitLab archive leaves the m4 submodule empty.
tar -xzf %{SOURCE1} --strip-components=1 -C m4
python3 %{_sourcedir}/../gcc14-prep.py .
%build
export CC="%{homelab_cc}"
export CXX="%{homelab_cxx}"
export CFLAGS="%{homelab_cflags}"
export CXXFLAGS="%{homelab_cxxflags}"
export LIBRARY_PATH="%{_prefix}/lib64:%{_prefix}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
./autogen.sh --prefix=%{_prefix} --libdir=%{_prefix}/lib64
%make_build

%install
%make_install
find %{buildroot} -name '*.la' -delete
find %{buildroot} \( -type f -o -type l \) -printf '"%p"\n' | sed 's|"%{buildroot}|"|' > %{_builddir}/%{name}.files
%files -f %{_builddir}/%{name}.files
