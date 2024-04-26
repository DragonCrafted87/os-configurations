{ config, lib, pkgs, modulesPath, ... }:

{

  fileSystems."/srv/data" =
    {
      device = "/dev/disk/by-label/data";
      fsType = "ext4";
    };


  fileSystems."/mnt/dragonfire" = {
    device = "192.168.0.1:/srv/data/";
    fsType = "nfs";
  };

  networking = {
    hostName = "nfs";
    domain = "stealthdragonland.net";
    interfaces.eth0.ipv4.addresses = [
      {
        address = "192.168.0.200";
        prefixLength = 20;
      }
    ];
    defaultGateway = "192.168.0.1";
    nameservers = [ "192.168.0.1" ];
    firewall = {
      allowedTCPPorts = [ 111 2049 4000 4001 4002 20048 ];
      allowedUDPPorts = [ 111 2049 4000 4001 4002 20048 ];
    };
  };

  services.nfs.server = {
    enable = true;
    lockdPort = 4001;
    mountdPort = 4002;
    statdPort = 4000;
    exports = ''
      /srv/data 192.168.0.0/20(rw,no_root_squash,anonuid=99,anongid=99)
    '';
  };
}
