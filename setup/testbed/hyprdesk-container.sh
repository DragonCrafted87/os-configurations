#!/usr/bin/env bash
# Build hyprdesk in a throwaway container.
# Host /usr/local is mounted read-only and is not the install prefix.
# The logged-in Wayland socket is not mounted.
set -euo pipefail

IMAGE="openmandriva/minimal:rock"
NAME="hyprdesk-build"
PREFIX="/home/dragon/hypr-prefix"
GUEST_SETUP="/home/dragon/machine-setup"
GUEST_DOTS="/home/dragon/dot-files"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${here}/../.." && pwd)"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

if [[ "$PREFIX" == "/usr/local" ]]; then
    die "refusing install prefix /usr/local"
fi

if [[ -d "${REPO}/../dot-files/bashrc.d" ]]; then
    DOTFILES_HOST="$(cd "${REPO}/../dot-files" && pwd)"
elif [[ -d "$(dirname "$REPO")/hyprdesk-dot-files/bashrc.d" ]]; then
    DOTFILES_HOST="$(cd "$(dirname "$REPO")/hyprdesk-dot-files" && pwd)"
else
    die "missing dot-files checkout next to ${REPO}"
fi

command -v docker >/dev/null 2>&1 || die "docker is required"
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE"
[[ -d "${DOTFILES_HOST}/bashrc.d" ]] || die "missing dot-files checkout ${DOTFILES_HOST}"

if docker container inspect "$NAME" >/dev/null 2>&1; then
    docker rm -f "$NAME" >/dev/null
fi

docker create \
    --name "$NAME" \
    --hostname hyprdesk-build \
    --mount "type=bind,source=${REPO},target=${GUEST_SETUP},readonly" \
    --mount "type=bind,source=${DOTFILES_HOST},target=${GUEST_DOTS},readonly" \
    --mount "type=bind,source=/usr/local,target=/usr/local,readonly" \
    "$IMAGE" \
    sleep infinity >/dev/null

mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}} rw={{.RW}}{{"\n"}}{{end}}' "$NAME")"
printf '%s\n' "$mounts" | grep -qx '/usr/local rw=false' \
    || die "host /usr/local is not a read-only mount"
if printf '%s\n' "$mounts" | grep -E 'wayland|pulse|pipewire' >/dev/null; then
    die "a session socket is mounted into ${NAME}"
fi

docker start "$NAME" >/dev/null

docker exec -i -u root -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" "$NAME" \
    bash -s <<'EOS'
set -euo pipefail
if ! command -v sudo >/dev/null 2>&1; then
    dnf install -y sudo
fi
chmod 4755 /usr/bin/sudo
if [[ -e /usr/sbin/sudo && ! -L /usr/sbin/sudo ]]; then
    chmod 4755 /usr/sbin/sudo
fi
if ! command -v useradd >/dev/null 2>&1; then
    dnf install -y shadow-utils || dnf install -y shadow
fi
if ! getent group "$HOST_GID" >/dev/null 2>&1; then
    groupadd --gid "$HOST_GID" dragon
fi
if ! id dragon >/dev/null 2>&1; then
    if getent passwd "$HOST_UID" >/dev/null 2>&1; then
        userdel "$(getent passwd "$HOST_UID" | cut -d: -f1)"
    fi
    useradd --uid "$HOST_UID" --gid "$HOST_GID" --no-create-home \
        --home-dir /home/dragon --shell /bin/bash dragon
fi
install -d -o dragon -g "$HOST_GID" /home/dragon
cat >/etc/sudoers.d/dragon <<'SUDO'
Defaults:dragon !requiretty
dragon ALL=(ALL) NOPASSWD: ALL
SUDO
chmod 0440 /etc/sudoers.d/dragon
dnf install -y --setopt=install_weak_deps=False \
    git gcc-c++ glibc-devel cmake make pkgconf python xkeyboard-config diffutils \
    lib64pixman-devel lib64drm-devel lib64icu-devel lib64fontconfig-devel \
    lib64qalculate-devel lib64wayland-devel lib64pango1.0-devel \
    lib64pangocairo1.0-devel lib64cairo-devel lib64xkbcommon-devel \
    lib64pugixml1 lib64glvnd-devel lib64gbm-devel lib64absl-devel \
    lib64heif lib64jxl lib64rsvg2_2 lib64magic1 lib64gdk_pixbuf2.0_0 \
    lib64jpeg8 lib64webp lib64png lib64seat lib64display-info lib64iniparser \
    lib64mtdev1 lib64evdev2 lib64systemd-devel
[[ -d /usr/share/X11/xkb ]] || {
    printf 'error: /usr/share/X11/xkb is missing\n' >&2
    exit 1
}
if rpm -q hyprland >/dev/null 2>&1; then
    printf 'error: distro hyprland is installed; the module would skip\n' >&2
    exit 1
fi
EOS

docker exec -i -u dragon -e PREFIX="$PREFIX" "$NAME" bash -s <<'EOS'
set -euo pipefail
install -d "${PREFIX}/bin" "${PREFIX}/share/hyprland-source" "${HOME}/.cache"
sed "s|^prefix=/usr/local$|prefix=${PREFIX}|" \
    /usr/local/share/hyprland-source/.dotfiles-stamp \
    >"${PREFIX}/share/hyprland-source/.dotfiles-stamp"
printf '#!/bin/sh\nexit 0\n' >"${PREFIX}/bin/Hyprland"
chmod 755 "${PREFIX}/bin/Hyprland"
ln -sfn /usr/local/bin/hyprwire-scanner "${PREFIX}/bin/hyprwire-scanner"
ln -sfn /usr/local/bin/hyprwayland-scanner "${PREFIX}/bin/hyprwayland-scanner"
EOS

run_module() {
    local dry="$1"
    docker exec -u dragon \
        -e HOME=/home/dragon \
        -e HYPRLAND_SOURCE_PREFIX="$PREFIX" \
        -e HYPRLAND_SOURCE_ONLY=hyprdesk \
        -e HYPRLAND_SOURCE_SRC=/home/dragon/.cache/hyprland-source \
        -e PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig \
        -e LIBRARY_PATH=/usr/local/lib64:/usr/local/lib \
        -e LDFLAGS="-L/usr/local/lib64 -L/usr/local/lib -Wl,-rpath,/usr/local/lib64" \
        -e PATH="/usr/local/bin:/usr/bin:/bin" \
        -e DOTFILES_DRY_RUN="$dry" \
        "$NAME" \
        "${GUEST_SETUP}/setup/modules/desktop/install-hyprland-source.sh"
}

dry_log="$(run_module 1 2>&1)"
printf '%s\n' "$dry_log"
printf '%s\n' "$dry_log" | grep -F 'would build hyprdesk' >/dev/null \
    || die "dry-run did not log a hyprdesk build"
if printf '%s\n' "$dry_log" | grep -F 'would build Hyprland' >/dev/null; then
    die "dry-run logged a Hyprland rebuild"
fi

run_module 0

version="$(
    docker exec -u dragon \
        -e LD_LIBRARY_PATH=/usr/local/lib64:/usr/local/lib \
        "$NAME" \
        "${PREFIX}/bin/hyprdesk" --version
)"
printf '%s\n' "$version"
printf '%s\n' "$version" | grep -F 'Hyprdesk 1' >/dev/null \
    || die "version was: ${version}"

self_test="$(
    docker exec -u dragon \
        -e LD_LIBRARY_PATH=/usr/local/lib64:/usr/local/lib \
        "$NAME" \
        "${PREFIX}/bin/hyprdesk" --self-test
)"
printf '%s\n' "$self_test"
printf '%s\n' "$self_test" | grep -F 'hyprdesk self-test passed' >/dev/null \
    || die "self-test failed"

if [[ -e /usr/local/bin/hyprdesk ]]; then
    die "host /usr/local/bin/hyprdesk exists after the container build"
fi
pgrep -x qs >/dev/null || die "qs is not running on the host"
printf 'hyprdesk container check passed\n'
