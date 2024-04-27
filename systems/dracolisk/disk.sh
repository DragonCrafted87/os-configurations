#!/usr/bin/env bash

umount --all-targets --recursive --force /mnt 2>/dev/null
swapoff /dev/sdb1 2>/dev/null

#root drive
parted --script --align optimal /dev/sda \
    mklabel gpt \
    mkpart root ext4 512MiB 100% \
    mkpart ESP fat32 1MiB 512MiB \
    set 2 esp on \
    print
mkfs.ext4 -L nixos /dev/sda1
mkfs.fat -F 32 -n boot /dev/sda2

# swap drive
parted --script --align optimal /dev/sdb \
    mklabel gpt \
    mkpart swap linux-swap 1MiB 100% \
    set 1 swap on \
    print
mkswap -L swap /dev/sdb1
swapon /dev/sdb1

# home drive
parted --script --align optimal /dev/sdc \
    mklabel gpt \
    mkpart home ext4 1MiB 100% \
    print
mkfs.ext4 -L home /dev/sdc1

# mount drives
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=077 /dev/disk/by-label/boot /mnt/boot
mkdir -p /mnt/home
mount /dev/disk/by-label/home /mnt/home
