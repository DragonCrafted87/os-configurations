# Version and compiler flags come from rpms/build.sh.
%global debug_package %{nil}
%global _prefix /usr/local

Name:           hyprland
Version:        %{pkg_version}
Release:        1
Vendor:         homelab
Summary:        hyprland for the homelab /usr/local prefix
License:        BSD-3-Clause
URL:            https://github.com/hyprwm/Hyprland
Source0:        https://github.com/hyprwm/Hyprland/releases/download/v%{pkg_version}/source-v%{pkg_version}.tar.gz
Source1:        hyprland.desktop
Source2:        hyprland-local.conf
Source3:        iniparser.pc
Patch0:         hyprland-gcc14.patch
BuildRequires:  cmake gcc gcc-c++ pkgconf make mold python3
Requires:       aquamarine hyprlang hyprutils hyprcursor hyprgraphics hyprland-protocols hyprwayland-scanner hyprwire hyprtoolkit libxkbcommon libinput re2 glaze wayland-protocols xcb-errors

%description
hyprland built from the pin in setup/versions.conf. Files install under /usr/local.

%prep
%autosetup -n hyprland-source -p1
%build
export CC="%{homelab_cc}"
export CXX="%{homelab_cxx}"
export CFLAGS="%{homelab_cflags}"
export CXXFLAGS="%{homelab_cxxflags}"
export PKG_CONFIG_PATH="%{_prefix}/lib64/pkgconfig:%{_prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
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
    -DNO_UWSM:STRING=true
cmake --build build --config Release -j"$(nproc)"

%install
DESTDIR=%{buildroot} cmake --install build
install -d %{buildroot}/usr/share/wayland-sessions
install -m 0644 %{SOURCE1} %{buildroot}/usr/share/wayland-sessions/hyprland.desktop
install -d %{buildroot}/etc/ld.so.conf.d
install -m 0644 %{SOURCE2} %{buildroot}/etc/ld.so.conf.d/hyprland-local.conf
install -d %{buildroot}%{_prefix}/lib64/pkgconfig
install -m 0644 %{SOURCE3} %{buildroot}%{_prefix}/lib64/pkgconfig/iniparser.pc
find %{buildroot} \( -type f -o -type l \) | sed "s|^%{buildroot}||" > %{_builddir}/%{name}.files
%files -f %{_builddir}/%{name}.files
