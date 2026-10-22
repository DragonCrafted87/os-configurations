# Version and compiler flags come from rpms/build.sh.
%global debug_package %{nil}
%global _prefix /usr/local

Name:           hyprcapture
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        hyprcapture for the homelab /usr/local prefix
License:        GPL-3.0-or-later
URL:            https://github.com/gfhdhytghd/HyprCapture
Source0:        https://github.com/gfhdhytghd/HyprCapture/archive/%{pkg_tag}.tar.gz
Source1:        https://github.com/hyprwm/Hyprland/releases/download/v%{hyprland_version}/source-v%{hyprland_version}.tar.gz
Patch0:         layershell.patch
BuildRequires:  cmake gcc gcc-c++ pkgconf make hyprland
Requires:       hyprland

%description
hyprcapture built from the pin in setup/versions.conf. Files install under /usr/local.

%prep
%autosetup -n HyprCapture-%{pkg_tag} -p1
mkdir -p hyprland-src
tar -xzf %{SOURCE1} -C hyprland-src --strip-components=1
python3 %{_sourcedir}/../gcc14-prep.py .
%build
export CC="%{homelab_cc}"
export CXX="%{homelab_cxx}"
export CFLAGS="%{homelab_cflags}"
export CXXFLAGS="%{homelab_cxxflags}"
export PKG_CONFIG_PATH="%{_prefix}/lib64/pkgconfig:%{_prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="%{_prefix}/lib64:%{_prefix}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export PATH="%{_prefix}/bin:${PATH}"
# The plugin includes generated Hyprland protocol headers and src/version.h.
cmake -S hyprland-src -B hyprland-src/protocol-build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=%{_prefix} \
    -DCMAKE_PREFIX_PATH=%{_prefix} \
    -DCMAKE_C_COMPILER="%{homelab_cc}" \
    -DCMAKE_CXX_COMPILER="%{homelab_cxx}" \
    -DCMAKE_C_FLAGS="%{homelab_cflags}" \
    -DCMAKE_CXX_FLAGS="%{homelab_cxxflags}" \
    -DNO_UWSM:STRING=true
cmake --build hyprland-src/protocol-build --target generate-protocol-headers -j"$(nproc)"
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
    -DHYPRLAND_SOURCE_DIR="${PWD}/hyprland-src" -DHYPRCAPTURE_DEFAULT_HELPER_PATH=%{_prefix}/bin/hyprcapture-ui
cmake --build build --config Release -j"$(nproc)" --target hyprcapture --target hyprcapture-ui

%install
install -d %{buildroot}%{_prefix}/lib %{buildroot}%{_prefix}/bin
so="$(find build -name libhyprcapture.so -type f -print -quit)"
install -m 0755 "$so" %{buildroot}%{_prefix}/lib/libhyprcapture.so
install -m 0755 build/hyprcapture-ui %{buildroot}%{_prefix}/bin/hyprcapture-ui
find %{buildroot} -name '*.la' -delete
find %{buildroot} \( -type f -o -type l \) -printf '"%p"\n' | sed 's|"%{buildroot}|"|' > %{_builddir}/%{name}.files
%files -f %{_builddir}/%{name}.files
