{ config, lib, pkgs, modulesPath, ... }:

{
    imports =
    [
      ./hardware-configuration.nix
      ./common.nix
      ./ssh-user-keys.nix
    ];

  systemd.network.links."10-lan" = {
    matchConfig.PermanentMACAddress = "00:15:5d:00:0a:01";
    linkConfig.Name = "lan";
  };

  fileSystems."/mnt/castellan" = {
    device = "192.168.0.200:/srv/data/";
    fsType = "nfs";
  };

  networking = {
    hostName = "dracolisk";
    domain = "stealthdragonland.net";
    interfaces.lan.ipv4.addresses = [
      {
        address = "192.168.0.201";
        prefixLength = 20;
      }
    ];
    defaultGateway = "192.168.0.1";
    nameservers = [ "192.168.0.1" ];
  };
}
