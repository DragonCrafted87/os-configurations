#!/usr/bin/env bash

hostname=$1
ip_address=$2

ssh-keygen -R "${ip_address}"

ssh -t -o StrictHostKeyChecking=accept-new root@"${ip_address}" 'bash -s' < "${hostname}"/disk.sh
ssh -t root@"${ip_address}" 'bash -s' <<'ENDSSH'
nixos-generate-config --root /mnt
rm /mnt/etc/nixos/configuration.nix
ENDSSH

scp root@"${ip_address}":/mnt/etc/nixos/hardware-configuration.nix "${hostname}"/hardware-configuration.nix

scp "${hostname}"/*.nix     root@"${ip_address}":/mnt/etc/nixos/
scp common/*.nix            root@"${ip_address}":/mnt/etc/nixos/

ssh -t root@"${ip_address}" 'bash -s' <<'ENDSSH'
nixos-install
ENDSSH
