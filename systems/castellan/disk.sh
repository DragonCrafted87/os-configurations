#!/usr/bin/env bash

umount --all-targets --recursive --force /mnt

#root drive
parted --script --align optimal /dev/disk/by-id/scsi-SNVMe_KINGSTON_SFYRSK50000_0000_0000_0000_0026_B728_345F_CB85. \
    mklabel gpt \
    mkpart root ext4 512MiB 100% \
    mkpart boot fat32 1MiB 512MiB \
    set 2 bios_grub on \
    print
mkfs.ext4 -F -L root /dev/disk/by-id/scsi-SNVMe_KINGSTON_SFYRSK50000_0000_0000_0000_0026_B728_345F_CB85.-part1
mkfs.fat -F 32 -n boot /dev/disk/by-id/scsi-SNVMe_KINGSTON_SFYRSK50000_0000_0000_0000_0026_B728_345F_CB85.-part2


# mount drives
mount /dev/disk/by-label/root /mnt
