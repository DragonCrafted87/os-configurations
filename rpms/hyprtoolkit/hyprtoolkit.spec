# Version and compiler flags come from rpms/build.sh.
%global debug_package %{nil}
%global _prefix /usr/local

Name:           hyprtoolkit
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        hyprtoolkit for the homelab /usr/local prefix
License:        BSD-3-Clause
URL:            https://github.com/hyprwm/hyprtoolkit
Source0:        https://github.com/hyprwm/hyprtoolkit/archive/refs/tags/%{pkg_tag}.tar.gz
Patch0:         libstdcxx-format.patch
BuildRequires:  cmake gcc gcc-c++ pkgconf make
Requires:       hyprutils hyprlang

%description
hyprtoolkit built from the pin in setup/versions.conf. Files install under /usr/local.

%prep
%autosetup -n hyprtoolkit-%{pkg_version} -p1
python3 %{_sourcedir}/../gcc14-prep.py .
%build
export CC="%{homelab_cc}"
export CXX="%{homelab_cxx}"
export CFLAGS="%{homelab_cflags}"
export CXXFLAGS="%{homelab_cxxflags}"
export PKG_CONFIG_PATH="%{_prefix}/lib64/pkgconfig:%{_prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="%{_prefix}/lib64:%{_prefix}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=%{_prefix} \
    -DCMAKE_PREFIX_PATH=%{_prefix} \
    -DCMAKE_LIBRARY_PATH="%{_prefix}/lib64;%{_prefix}/lib" \
    -DCMAKE_INSTALL_LIBDIR=lib64 \
    -DCMAKE_INSTALL_RPATH="%{_prefix}/lib64;%{_prefix}/lib" \
    -DCMAKE_BUILD_RPATH="%{_prefix}/lib64;%{_prefix}/lib" \
    -DBUILD_TESTING=OFF \
    -DCMAKE_C_COMPILER="%{homelab_cc}" \
    -DCMAKE_CXX_COMPILER="%{homelab_cxx}" \
    -DCMAKE_C_FLAGS="%{homelab_cflags}" \
    -DCMAKE_CXX_FLAGS="%{homelab_cxxflags}" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--allow-shlib-undefined" \

cmake --build build --config Release -j"$(nproc)"

%install
DESTDIR=%{buildroot} cmake --install build
# The distro library has no iniparser.pc. The source role writes this one.
mkdir -p %{buildroot}%{_prefix}/lib64/pkgconfig
cat > %{buildroot}%{_prefix}/lib64/pkgconfig/iniparser.pc <<'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=/usr/lib64
includedir=/usr/include/iniparser
Name: iniparser
Description: INI file parser
Version: 4.2.1
Libs: -L${libdir} -liniparser
Cflags: -I${includedir} -I/usr/include
EOF
find %{buildroot} -name '*.la' -delete
find %{buildroot} \( -type f -o -type l \) -printf '"%p"\n' | sed 's|"%{buildroot}|"|' > %{_builddir}/%{name}.files
%files -f %{_builddir}/%{name}.files
