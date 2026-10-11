#!/usr/bin/env bash
# Proves the mist-dragon reflash refuses the wrong disk and the wrong image.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# shellcheck disable=SC1091
. "${repo}/setup/ventoy/mist-dragon/reflash.sh"

bin="${work}/bin"
mkdir -p "$bin"
find_log="${work}/findmnt.log"

cat >"${bin}/findmnt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FIND_LOG:?}"
if [[ "$*" == *"-T "* ]]; then
    printf '%s\n' "${FIND_OPTS:-}"
    exit 0
fi
if [[ "$*" == *"LABEL=Ventoy"* ]]; then
    [[ -n "${FIND_LABEL:-}" ]] && printf '%s\n' "$FIND_LABEL"
    exit 0
fi
[[ -n "${FIND_DEV:-}" ]] && printf '%s\n' "$FIND_DEV"
exit 0
EOF
cat >"${bin}/mount" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOUNT_LOG:?}"
exit 0
EOF
chmod 0755 "${bin}/findmnt" "${bin}/mount"

image_at() {
    local dir="$1"
    local name="${2:-openwrt-24.10.8-x86-64-generic-ext4-combined-efi.img.gz}"
    mkdir -p "${dir}/raw-disc-images"
    : >"${dir}/raw-disc-images/${name}"
}

run_mount() {
    PATH="${bin}:${PATH}" \
        FIND_LOG="$find_log" \
        MOUNT_LOG="${work}/mount.log" \
        FIND_DEV="${FIND_DEV:-}" \
        FIND_LABEL="${FIND_LABEL:-}" \
        MIST_LIVE_MEDIA="${work}/media" \
        MIST_LIVE_RUN_MEDIA="${work}/run-media" \
        MIST_VENTOY_MNT="${work}/mnt-ventoy" \
        ventoy_mount_point /dev/sda1
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

: >"$find_log"
: >"${work}/mount.log"
FIND_DEV="${work}/by-device"
image_at "$FIND_DEV"
got="$(run_mount)"
[[ "$got" == "$FIND_DEV" ]] || fail "device mount was skipped: ${got}"
[[ ! -s "${work}/mount.log" ]] || fail "device mount called mount"

: >"$find_log"
: >"${work}/mount.log"
FIND_DEV="${work}/empty-mount"
mkdir -p "$FIND_DEV"
FIND_LABEL=""
image_at "${work}/media/live/Ventoy"
got="$(run_mount)"
[[ "$got" == "${work}/media/live/Ventoy" ]] || fail "live desktop mount was skipped: ${got}"
[[ ! -s "${work}/mount.log" ]] || fail "live desktop mount called mount"

reason="$(refuse_reason /dev/sdb /dev/sdb KINGSTONOM8P0S3 /media/live/Ventoy "")"
[[ "$reason" == "refusing to write the Ventoy stick /dev/sdb" ]] || fail "ventoy disk was allowed: ${reason}"

reason="$(refuse_reason /dev/sda /dev/sdb WDS500G3X0C /media/live/Ventoy "")"
[[ "$reason" == *"expected a disk whose model contains OM8P0S3"* ]] || fail "wrong model was allowed: ${reason}"

reason="$(refuse_reason /dev/sda /dev/sdb KINGSTONOM8P0S3 /media/live/Ventoy $'/boot\n')"
[[ "$reason" == *"/dev/sda is mounted at /boot"* ]] || fail "boot disk was allowed: ${reason}"

reason="$(refuse_reason /dev/sda /dev/sdb KINGSTONOM8P0S3 /media/live/Ventoy /media/live/Ventoy)"
[[ "$reason" == *"That is the Ventoy stick."* ]] || fail "ventoy mount was allowed: ${reason}"

reason="$(refuse_reason /dev/sda /dev/sdb KINGSTONOM8P0S3 /media/live/Ventoy "")"
[[ -z "$reason" ]] || fail "router disk was refused: ${reason}"

img_dir="${work}/images"
image_at "$img_dir"
got="$(choose_image "$img_dir")"
[[ "$got" == "${img_dir}/raw-disc-images/openwrt-24.10.8-x86-64-generic-ext4-combined-efi.img.gz" ]] || fail "single image was skipped: ${got}"

image_at "$img_dir" "openwrt-25.12.5-x86-64-generic-ext4-combined-efi.img.gz"
if got="$(choose_image "$img_dir" </dev/null 2>"${work}/choose.err")"; then
    fail "two images were chosen without a terminal: ${got}"
fi
[[ -s "${work}/choose.err" ]] || fail "two images produced no error"

custom="${img_dir}/raw-disc-images/openwrt-25.12.5-x86-64-generic-ext4-combined-efi-mist-dragon.img.gz"
: >"$custom"
got="$(MIST_IMAGE="$custom" choose_image "$img_dir")"
[[ "$got" == "$custom" ]] || fail "MIST_IMAGE was ignored: ${got}"

: >"${img_dir}/raw-disc-images/haos.img.xz"
if got="$(MIST_IMAGE="${img_dir}/raw-disc-images/haos.img.xz" choose_image "$img_dir" 2>"${work}/bad-name.err")"; then
    fail "wrong image name was accepted: ${got}"
fi

printf 'abc\n' >"${work}/payload"
digest="$(sha256sum "${work}/payload" | awk '{print $1}')"
named="${work}/openwrt-24.10.8-x86-64-generic-ext4-combined-efi.img.gz"
cp "${work}/payload" "$named"
printf '%s  %s\n' "$KNOWN_SHA256_24_10_8" "$(basename "$named")" >"${named}.sha256"
if ( verify_image "$named" ) 2>"${work}/sha.err"; then
    fail "published checksum accepted a different file"
fi
printf '%s  %s\n' "$digest" "$(basename "$named")" >"${named}.sha256"
if ( verify_image "$named" ) 2>"${work}/side.err"; then
    fail "a sidecar was allowed to override the published checksum"
fi
rm -f "${named}.sha256"
side="${work}/openwrt-25.12.5-x86-64-generic-ext4-combined-efi-mist-dragon.img.gz"
cp "${work}/payload" "$side"
printf '%s  %s\n' "$digest" "$(basename "$side")" >"${side}.sha256"
verify_image "$side"

root="${work}/rootmnt"
mkdir -p "$root"
if ( copy_backup "$root" "${work}/missing.tar.gz" ) 2>"${work}/copy.err"; then
    fail "missing backup was copied"
fi
printf 'backup\n' >"${work}/ok.tar.gz"
copy_backup "$root" "${work}/ok.tar.gz"
[[ -f "${root}/root/mist-dragon-backup.tar.gz" ]] || fail "backup was not copied"
grep -q 'sysupgrade -r' "${root}/root/RECOVERY.txt" || fail "restore note is missing"

cat >"${bin}/lsblk" <<'EOF'
#!/usr/bin/env bash
if [[ "${LSBLK_EMPTY:-}" == 1 ]]; then
    exit 0
fi
printf '%s kernel vfat\n' /dev/sda1
printf '%s rootfs ext4\n' /dev/sda2
EOF
chmod 0755 "${bin}/lsblk"
got="$(PATH="${bin}:${PATH}" root_partition /dev/sda)"
[[ "$got" == /dev/sda2 ]] || fail "rootfs partition was skipped: ${got}"
if PATH="${bin}:${PATH}" LSBLK_EMPTY=1 root_partition /dev/sda; then
    fail "missing rootfs was accepted"
fi

printf 'mist reflash ok\n'
