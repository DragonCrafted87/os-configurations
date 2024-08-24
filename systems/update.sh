#!/usr/bin/env bash

hostname=$1

scp "root@192.168.1.1":/etc/nixos/hardware-configuration.nix "router"/hardware-configuration.nix

scp "router"/*.nix      "root@192.168.1.1":/etc/nixos/
scp common/*.nix        "root@192.168.1.1":/etc/nixos/

ssh -tt "root@192.168.1.1" 'bash -c "nixos-rebuild switch"'
