#!/usr/bin/env bash

parted /dev/sda --script -- mklabel gpt
parted /dev/sda --script -- mkpart root ext4 512MB 100%
parted /dev/sda --script -- mkpart ESP fat32 1MB 512MB
parted /dev/sda --script -- set 2 esp on
parted /dev/sda --script -- print

mkfs.ext4 -L nixos /dev/sda1
mkfs.fat -F 32 -n boot /dev/sda2

mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=077 /dev/disk/by-label/boot /mnt/boot
nixos-generate-config --root /mnt

rm /mnt/etc/nixos/configuration.nix

nano /mnt/etc/nixos/configuration.nix
nano /mnt/etc/nixos/common.nix
nano /mnt/etc/nixos/ssh-user-keys.nix
