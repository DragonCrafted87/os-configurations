{ config, lib, pkgs, modulesPath, ... }:

{
    imports =
    [
      ./hardware-configuration.nix
      ../common/common.nix
      ../commonssh-user-keys.nix
    ];

  networking = {
    hostName = "data-hoard";
    domain = "stealthdragonland.net";
    interfaces.enp2s0.ipv4.addresses = [
      {
        address = "192.168.0.50";
        prefixLength = 20;
      }
    ];
    defaultGateway = "192.168.0.1";
    nameservers = [ "192.168.0.1" ];
    firewall = {
      allowedTCPPorts = [ ];
      allowedUDPPorts = [ ];
    };
  };


  boot.kernelPackages = pkgs.zfs.latestCompatibleLinuxPackages;

}
