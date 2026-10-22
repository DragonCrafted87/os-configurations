# Version and compiler flags come from rpms/build.sh.
%global debug_package %{nil}
%global _prefix /usr/local

Name:           boinc
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        boinc for the homelab /usr/local prefix
License:        LGPL-3.0-or-later
URL:            https://github.com/BOINC/boinc
Source0:        https://github.com/BOINC/boinc/archive/refs/tags/client_release/8.2/%{pkg_version}.tar.gz
Patch0:         opencl-libadd.patch
BuildRequires:  clang make autoconf automake libtool pkgconf m4 opencl-headers lib64OpenCL-devel

%description
boinc built from the pin in setup/versions.conf. Files install under /usr/local.

%prep
%autosetup -n boinc-client_release-8.2-%{pkg_version} -p1
python3 %{_sourcedir}/../gcc14-prep.py .
%build
export CC="%{homelab_cc}"
export CXX="%{homelab_cxx}"
export CFLAGS="%{homelab_cflags}"
export CXXFLAGS="%{homelab_cxxflags}"
export LIBRARY_PATH="%{_prefix}/lib64:%{_prefix}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
./_autosetup
./configure --prefix=%{_prefix} --disable-server --disable-fcgi \
    --disable-silent-rules --enable-unicode --with-ssl --with-x \
    CC="%{homelab_cc}" CXX="%{homelab_cxx}" \
    CFLAGS="%{homelab_cflags}" CXXFLAGS="%{homelab_cxxflags}"
# _autosetup turns the Makefile.am OpenCL line into Makefile.in.
grep -q 'libboinc_opencl_la_LIBADD = .*OpenCL' api/Makefile.in
%make_build

%install
%make_install
find %{buildroot} -name '*.la' -delete
find %{buildroot} \( -type f -o -type l \) -printf '"%p"\n' | sed 's|"%{buildroot}|"|' > %{_builddir}/%{name}.files
%files -f %{_builddir}/%{name}.files
