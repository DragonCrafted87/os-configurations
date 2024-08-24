#!/usr/bin/env bash

hostname=$1
ip_address=$2

ssh-keygen -R "${ip_address}"

scp -o StrictHostKeyChecking=accept-new "${hostname}"/disk.sh "root@${ip_address}":/root/disk.sh
ssh -tt  "root@${ip_address}" 'bash -c /root/disk.sh'

if test -f "${hostname}"/hardware-configuration.nix; then
    ssh -tt "root@${ip_address}" 'bash -c "mkdir -p /mnt/etc/nixos"'
else
    ssh -tt "root@${ip_address}" 'bash -c "nixos-generate-config --root /mnt"'
    ssh -tt "root@${ip_address}" 'bash -c "rm /mnt/etc/nixos/configuration.nix"'
    scp "root@${ip_address}":/mnt/etc/nixos/hardware-configuration.nix "${hostname}"/hardware-configuration.nix
fi

scp "${hostname}"/*.nix     "root@${ip_address}":/mnt/etc/nixos/
scp common/*.nix            "root@${ip_address}":/mnt/etc/nixos/

ssh -tt "root@${ip_address}" 'bash -c "nixos-install"'
