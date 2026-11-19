# Version and compiler flags come from rpms/build.sh.
%global debug_package %{nil}
%global _prefix /usr/local

Name:           makemkv
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        MakeMKV for the homelab /usr/local prefix
License:        GPL-2.0-or-later AND LicenseRef-MakeMKV-EULA
URL:            https://www.makemkv.com/
Source0:        https://www.makemkv.com/download/makemkv-oss-%{pkg_version}.tar.gz
Source1:        https://www.makemkv.com/download/makemkv-bin-%{pkg_version}.tar.gz
BuildRequires:  homelab-llvm make pkgconf lib64openssl-devel lib64expat-devel lib64z-devel lib64ffmpeg-devel lib64qt5core-devel lib64qt5gui-devel lib64qt5widgets-devel lib64qt5dbus-devel

%description
MakeMKV built from the pin in setup/versions.conf. The open-source
libraries are compiled here. The closed makemkvcon binary is the
upstream build for this version. Files install under /usr/local.

%prep
%setup -q -n makemkv-oss-%{pkg_version}
tar -xf %{SOURCE1} -C ..

%build
export CC="%{homelab_cc}"
export CXX="%{homelab_cxx}"
export CFLAGS="%{homelab_cflags}"
export CXXFLAGS="%{homelab_cxxflags}"
./configure --prefix=%{_prefix} \
    CC="%{homelab_cc}" CXX="%{homelab_cxx}" \
    CFLAGS="%{homelab_cflags}" CXXFLAGS="%{homelab_cxxflags}"
# lld 23 rejects version-script symbols that are not in this link.
sed -i 's/^LDFLAGS=.*/LDFLAGS=-fuse-ld=lld -Wl,--undefined-version/' Makefile
%make_build

%install
%make_install
mkdir -p ../makemkv-bin-%{pkg_version}/tmp
printf 'accepted\n' > ../makemkv-bin-%{pkg_version}/tmp/eula_accepted
make -C ../makemkv-bin-%{pkg_version} install DESTDIR=%{buildroot} PREFIX=%{_prefix}
find %{buildroot} \( -type f -o -type l \) -printf '"%p"\n' | sed 's|"%{buildroot}|"|' > %{_builddir}/%{name}.files

%files -f %{_builddir}/%{name}.files
