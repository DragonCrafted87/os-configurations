#!/usr/bin/env bash
# Write an OpenWrt combined-efi image onto mist-dragon's internal disk.
# Boot the OpenMandriva live image from Ventoy on the GEEK+ G34. The
# desktop mounts the stick at /media/live/Ventoy, and that mount is
# often noexec, so ./reflash.sh does not run. Open a root shell and run
# bash on the script:
#
#   sudo su
#   bash /media/live/Ventoy/scripts/mist-dragon/reflash.sh
#
# The steps are in RECOVERY.md next to this script. A fresh image
# answers at 192.168.1.1 with no root password. This script copies the
# newest config backup onto that root so the next boot can restore it
# with sysupgrade -r.

set -euo pipefail

EXPECT_MODEL="${MIST_EXPECT_MODEL:-OM8P0S3}"
CONFIRM='wipe mist-dragon'
KNOWN_SHA256_24_10_8='1abb90f522f40990ba6507a936dace792668514025d2319d3e6173ec8d6dada3'
KNOWN_SHA256_25_12_5='c8ee59ce7b0f635a6b50c1b7307b07ee7785214a6faf2af42280dd4ef4310290'
IMAGE_GLOB='openwrt-*-x86-64-generic-ext4-combined-efi*.img.gz'

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

is_live() {
    if grep -Eqw 'rd.live|liveimg|overlay' /proc/cmdline 2>/dev/null; then
        return 0
    fi
    if findmnt -n -o FSTYPE / 2>/dev/null | grep -Eq 'overlay|squashfs'; then
        return 0
    fi
    [[ -d /run/initramfs/live || -d /run/rootfsbase ]]
}

parent_disk() {
    local node="$1"
    local pk
    pk="$(lsblk -no PKNAME "$node" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$pk" ]]; then
        printf '/dev/%s\n' "$pk"
    else
        printf '%s\n' "$node"
    fi
}

ventoy_partition() {
    local name label
    while read -r name label; do
        if [[ "$label" == "Ventoy" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done < <(lsblk -rpno NAME,LABEL)
    return 1
}

ventoy_has_image() {
    local dir="$1"
    local found=()
    [[ -d "$dir" ]] || return 1
    shopt -s nullglob
    found=("${dir}/raw-disc-images/"${IMAGE_GLOB})
    shopt -u nullglob
    [[ ${#found[@]} -gt 0 ]]
}

# findmnt by device node misses the OpenMandriva live desktop mount.
# That mount is /media/<user>/Ventoy, and the live user is live.
ventoy_mount_point() {
    local part="$1"
    local mp dest
    local -a candidates=()
    local -A seen=()
    while read -r mp; do
        [[ -n "$mp" ]] && candidates+=("$mp")
    done < <(findmnt -rn -o TARGET -S "$part" || true)
    while read -r mp; do
        [[ -n "$mp" ]] && candidates+=("$mp")
    done < <(findmnt -rn -o TARGET -S LABEL=Ventoy || true)
    shopt -s nullglob
    for mp in \
        "${MIST_LIVE_MEDIA:-/media}/live/Ventoy" \
        "${MIST_LIVE_RUN_MEDIA:-/run/media}/live/Ventoy" \
        "${MIST_LIVE_MEDIA:-/media}/"*/Ventoy \
        "${MIST_LIVE_RUN_MEDIA:-/run/media}/"*/Ventoy; do
        candidates+=("$mp")
    done
    shopt -u nullglob
    for mp in "${candidates[@]+"${candidates[@]}"}"; do
        [[ -n "${seen[$mp]:-}" ]] && continue
        seen[$mp]=1
        if ventoy_has_image "$mp"; then
            printf '%s\n' "$mp"
            return 0
        fi
    done
    dest="${MIST_VENTOY_MNT:-/mnt/ventoy}"
    mkdir -p "$dest"
    mount -o ro "$part" "$dest"
    printf '%s\n' "$dest"
}

require_terminal() {
    [[ -t 0 && -t 1 ]] || die "this asks before it erases a disk. Open a terminal, run sudo su, then: bash $0"
}

reexec_if_noexec() {
    local script opts copy
    [[ "${MIST_INSTALL_REEXEC:-}" == 1 ]] && return 0
    script="$(readlink -f "$0")"
    opts="$(findmnt -n -o OPTIONS -T "$script" 2>/dev/null || true)"
    grep -qw noexec <<<"$opts" || return 0
    copy="$(mktemp)"
    cp "$script" "$copy"
    chmod 755 "$copy"
    export MIST_INSTALL_REEXEC=1
    exec bash "$copy" "$@"
}

known_sha256() {
    case "$(basename "$1")" in
        openwrt-24.10.8-x86-64-generic-ext4-combined-efi.img.gz) printf '%s\n' "$KNOWN_SHA256_24_10_8" ;;
        openwrt-25.12.5-x86-64-generic-ext4-combined-efi.img.gz) printf '%s\n' "$KNOWN_SHA256_25_12_5" ;;
        *) printf '\n' ;;
    esac
}

image_allowed() {
    local base
    base="$(basename "$1")"
    [[ "$base" == $IMAGE_GLOB ]]
}

list_images() {
    local dir="$1"
    local found=()
    shopt -s nullglob
    found=("${dir}/raw-disc-images/"${IMAGE_GLOB})
    shopt -u nullglob
    [[ ${#found[@]} -gt 0 ]] || die "no ${IMAGE_GLOB} under ${dir}/raw-disc-images"
    printf '%s\n' "${found[@]}" | sort -V
}

choose_image() {
    local dir="$1"
    local image
    local -a found=()
    if [[ -n "${MIST_IMAGE:-}" ]]; then
        image="$MIST_IMAGE"
        [[ -f "$image" ]] || die "image not found: ${image}"
        image_allowed "$image" || die "refusing ${image}; want ${IMAGE_GLOB}"
        printf '%s\n' "$image"
        return 0
    fi
    mapfile -t found < <(list_images "$dir")
    if [[ ${#found[@]} -eq 1 ]]; then
        printf '%s\n' "${found[0]}"
        return 0
    fi
    [[ -t 0 && -t 1 ]] || die "more than one image under ${dir}/raw-disc-images. Re-run with MIST_IMAGE set to one of them."
    printf 'Images:\n'
    local i=1
    for image in "${found[@]}"; do
        printf '  %d) %s\n' "$i" "$(basename "$image")"
        i=$((i + 1))
    done
    printf '24.10.8 is the image that was running. The mist-dragon file is the owut build.\n'
    printf 'Image number: '
    local pick
    read -r pick
    [[ "$pick" =~ ^[0-9]+$ ]] || die "not an image number: ${pick}"
    [[ "$pick" -ge 1 && "$pick" -le ${#found[@]} ]] || die "no image ${pick}"
    printf '%s\n' "${found[$((pick - 1))]}"
}

expect_sha256() {
    local image="$1"
    local known side
    known="$(known_sha256 "$image")"
    side=""
    if [[ -f "${image}.sha256" ]]; then
        side="$(awk 'NF { print $1; exit }' "${image}.sha256")"
    fi
    if [[ -n "$known" && -n "$side" && "$known" != "$side" ]]; then
        die "sidecar checksum for $(basename "$image") does not match the published checksum"
    fi
    if [[ -n "$known" ]]; then
        printf '%s\n' "$known"
        return 0
    fi
    if [[ -n "$side" ]]; then
        printf '%s\n' "$side"
        return 0
    fi
    die "no checksum for $(basename "$image"). Put one in ${image}.sha256"
}

verify_image() {
    local image="$1"
    local expect actual
    image_allowed "$image" || die "refusing ${image}; want ${IMAGE_GLOB}"
    [[ -f "$image" ]] || die "image not found: ${image}"
    expect="$(expect_sha256 "$image")"
    actual="$(sha256sum "$image" | awk '{print $1}')"
    [[ "$actual" == "$expect" ]] || die "checksum mismatch for ${image}"
}

# Prints a refusal reason, or nothing when the disk may be written.
refuse_reason() {
    local target_real="$1"
    local ventoy_real="$2"
    local model="$3"
    local ventoy_mnt="$4"
    local mount_list="$5"
    local mp
    if [[ "$target_real" == "$ventoy_real" ]]; then
        printf 'refusing to write the Ventoy stick %s\n' "$ventoy_real"
        return 0
    fi
    while read -r mp; do
        [[ -z "$mp" ]] && continue
        if [[ -n "$ventoy_mnt" && "$mp" == "$ventoy_mnt" ]]; then
            printf '%s is mounted at %s. That is the Ventoy stick.\n' "$target_real" "$mp"
            return 0
        fi
        case "$mp" in
            / | /boot | /boot/efi | /home | /run)
                printf '%s is mounted at %s. That is not the router disk.\n' "$target_real" "$mp"
                return 0
                ;;
        esac
    done <<<"$mount_list"
    if [[ "$model" != *"$EXPECT_MODEL"* ]]; then
        printf '%s model is %s, expected a disk whose model contains %s. Set MIST_EXPECT_MODEL only when lsblk shows the router disk.\n' \
            "$target_real" "$model" "$EXPECT_MODEL"
        return 0
    fi
    return 0
}

root_partition() {
    local disk="$1"
    local name label fstype dev line
    while read -r name label fstype; do
        if [[ "$label" == "rootfs" && "$fstype" == "ext4" ]]; then
            printf '%s\n' "$name"
            return 0
        fi
    done < <(lsblk -rpno NAME,LABEL,FSTYPE "$disk")
    # lsblk can miss a label until blkid has read the new partition.
    while read -r dev; do
        [[ "$dev" == "$disk" ]] && continue
        line="$(blkid -o export "$dev" 2>/dev/null || true)"
        label="$(printf '%s\n' "$line" | awk -F= '$1=="LABEL" { print $2; exit }')"
        fstype="$(printf '%s\n' "$line" | awk -F= '$1=="TYPE" { print $2; exit }')"
        if [[ "$label" == "rootfs" && "$fstype" == "ext4" ]]; then
            printf '%s\n' "$dev"
            return 0
        fi
    done < <(lsblk -rpno NAME "$disk")
    return 1
}

newest_backup() {
    local dir="$1"
    local found=()
    local best
    [[ -n "${MIST_BACKUP:-}" ]] && {
        [[ -f "$MIST_BACKUP" ]] || die "backup not found: ${MIST_BACKUP}"
        printf '%s\n' "$MIST_BACKUP"
        return 0
    }
    [[ -d "$dir" ]] || return 1
    shopt -s nullglob
    found=("${dir}/"*.tar.gz)
    shopt -u nullglob
    [[ ${#found[@]} -gt 0 ]] || return 1
    best="$(ls -1t "${found[@]}" | head -n 1)"
    printf '%s\n' "$best"
}

copy_backup() {
    local root_mnt="$1"
    local backup="$2"
    [[ -f "$backup" ]] || die "backup missing: ${backup}"
    mkdir -p "${root_mnt}/root"
    cp "$backup" "${root_mnt}/root/mist-dragon-backup.tar.gz"
    chmod 600 "${root_mnt}/root/mist-dragon-backup.tar.gz" || true
    local list
    list="$(dirname "$backup")/owut-list.txt"
    if [[ -f "$list" ]]; then
        cp "$list" "${root_mnt}/root/owut-list.txt"
    fi
    cat >"${root_mnt}/root/RECOVERY.txt" <<'EOF'
The config backup is /root/mist-dragon-backup.tar.gz.
This image's LAN is 192.168.1.1 and root has no password.

On the owut image (the file name contains mist-dragon), restore now:

  sysupgrade -r /root/mist-dragon-backup.tar.gz

On a stock image, install the extra packages while DNS still works,
then restore. Skip any name that starts with a dash.

  opkg update
  opkg install $(tr ' ' '\n' </root/owut-list.txt | grep -v '^-')
  sysupgrade -r /root/mist-dragon-backup.tar.gz

25.12 uses apk instead of opkg. The names are the same.
That reboots. LAN returns to 192.168.0.1/16.
On runewyrm, run: link-bench lan

If the main default route is dev tun0, delete it before anything else:

  ip route del default dev tun0
  ip route del 0.0.0.0/1
  ip route del 128.0.0.0/1

The root partition may reboot twice while it grows to fill the disk.
EOF
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

[[ "$(id -u)" -eq 0 ]] || die "run as root from a terminal: sudo su, then bash $0"
require_terminal
reexec_if_noexec "$@"

is_live || die "this only runs from the OpenMandriva live image, not an installed system"

command -v gzip >/dev/null 2>&1 || die "gzip is missing"
command -v dd >/dev/null 2>&1 || die "dd is missing"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is missing"

VENTOY_PART="$(ventoy_partition)" || die "no partition labeled Ventoy. Plug the stick in and try again."
VENTOY_DISK="$(parent_disk "$VENTOY_PART")"
VENTOY_MNT="$(ventoy_mount_point "$VENTOY_PART")"
log "Ventoy is ${VENTOY_DISK} mounted at ${VENTOY_MNT}"

IMAGE="$(choose_image "$VENTOY_MNT")"
log "checking $(basename "$IMAGE")"
verify_image "$IMAGE"

log "disks:"
lsblk -d -o NAME,SIZE,MODEL,TRAN,TYPE | sed 's/^/    /'

if [[ -n "${1:-}" ]]; then
    TARGET="$1"
else
    printf 'Whole disk to overwrite (the router disk is KINGSTON OM8P0S3): '
    read -r TARGET
fi
[[ -n "$TARGET" ]] || die "no disk given"
[[ "$TARGET" != /dev/* ]] && TARGET="/dev/${TARGET}"
[[ -b "$TARGET" ]] || die "${TARGET} is not a block device"
[[ "$(lsblk -dno TYPE "$TARGET")" == "disk" ]] || die "${TARGET} is not a whole disk. Do not pass a partition."

target_real="$(readlink -f "$TARGET")"
ventoy_real="$(readlink -f "$VENTOY_DISK")"
model="$(lsblk -ndo MODEL "$TARGET" | tr -d '[:space:]')"
mount_list="$(lsblk -nr -o MOUNTPOINT "$TARGET")"
reason="$(refuse_reason "$target_real" "$ventoy_real" "$model" "$VENTOY_MNT" "$mount_list")"
[[ -z "$reason" ]] || die "$reason"

printf '\nThis erases %s (%s, %s) and writes %s\n' \
    "$TARGET" "$model" "$(lsblk -ndo SIZE "$TARGET")" "$(basename "$IMAGE")"
printf 'Type "%s" to continue: ' "$CONFIRM"
read -r answer
[[ "$answer" == "$CONFIRM" ]] || die "aborted"

while read -r dev mp; do
    [[ -z "$mp" ]] && continue
    if [[ "$mp" == "[SWAP]" ]]; then
        [[ -n "$dev" ]] || die "swap on ${TARGET} has no device path"
        log "swapoff ${dev}"
        swapoff "$dev"
        continue
    fi
    log "unmounting ${mp}"
    umount "$mp"
done < <(lsblk -nrp -o NAME,MOUNTPOINT "$TARGET")

log "writing image"
gzip -dc "$IMAGE" | dd of="$TARGET" bs=4M conv=fsync status=progress
sync
if command -v partx >/dev/null 2>&1; then
    partx -u "$TARGET" 2>/dev/null || true
else
    blockdev --rereadpt "$TARGET" 2>/dev/null || true
fi
if command -v udevadm >/dev/null 2>&1; then
    udevadm settle || true
fi
sleep 2

backup_dir="${VENTOY_MNT}/scripts/mist-dragon/backup"
if backup="$(newest_backup "$backup_dir")"; then
    root_part="$(root_partition "$TARGET")" || die "image is written, but no ext4 partition labeled rootfs was found. Mount it and copy ${backup} to /root/mist-dragon-backup.tar.gz"
    root_mnt="$(mktemp -d)"
    if mount -o rw "$root_part" "$root_mnt"; then
        copy_backup "$root_mnt" "$backup"
        umount "$root_mnt"
        log "copied $(basename "$backup") to /root/mist-dragon-backup.tar.gz"
    else
        log "image is written. Mount the rootfs partition and copy ${backup} to /root/mist-dragon-backup.tar.gz"
    fi
    rmdir "$root_mnt" 2>/dev/null || true
else
    log "image is written. No backup tar under ${backup_dir}"
fi

log "done. Unplug Ventoy and boot the internal disk."
log "A fresh image is https://192.168.1.1/ with no root password."
log "On runewyrm, run: link-bench static"
log "Then: ssh root@192.168.1.1"
log "Then: sysupgrade -r /root/mist-dragon-backup.tar.gz"
log "After that reboot, run: link-bench lan"
