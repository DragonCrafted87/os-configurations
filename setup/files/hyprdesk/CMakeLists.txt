cmake_minimum_required(VERSION 3.19)

file(READ "${CMAKE_SOURCE_DIR}/VERSION" VER_RAW)
string(STRIP "${VER_RAW}" HYPRDESK_VERSION)

project(hyprdesk VERSION ${HYPRDESK_VERSION} DESCRIPTION "Hyprland desk menu and volume OSD")

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
find_package(Threads REQUIRED)
pkg_check_modules(DEPS REQUIRED IMPORTED_TARGET hyprtoolkit)
pkg_check_modules(SYSTEMD REQUIRED IMPORTED_TARGET libsystemd)
pkg_check_modules(PANGO REQUIRED IMPORTED_TARGET pangocairo)

add_executable(hyprdesk
    src/main.cpp
    src/place.cpp
    src/volume.cpp
    src/desktop.cpp
    src/clients.cpp
    src/stats.cpp
    src/spawn.cpp
    src/tray.cpp
    src/ui.cpp
    src/self_test.cpp)
target_compile_definitions(hyprdesk PRIVATE HYPRDESK_VERSION="${HYPRDESK_VERSION}")
target_link_libraries(hyprdesk PRIVATE PkgConfig::DEPS PkgConfig::SYSTEMD PkgConfig::PANGO Threads::Threads)

install(TARGETS hyprdesk)
