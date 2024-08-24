{ config, lib, pkgs, modulesPath, ... }:

{
    imports =
    [
      ./hardware-configuration.nix
      ./common.nix
      ./ssh-user-keys.nix
    ];

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = true;
  };

  systemd.network.links."10-wan" = {
    matchConfig.PermanentMACAddress = "38:f7:cd:c0:50:54";
    linkConfig.Name = "wan";
  };

    systemd.network.links."20-lan" = {
    matchConfig.PermanentMACAddress = "38:f7:cd:c0:50:55";
    linkConfig.Name = "lan";
  };

  environment.systemPackages = [
    pkgs.nftables
  ];

  networking = {
    hostName = "router";
    domain = "stealthdragonland.net";
    defaultGateway = "192.168.0.1";
    nameservers = [ "192.168.0.1" ];
    firewall.enable = true;
    useDHCP = false;

    interfaces = {
      wan = {
        useDHCP = true;
      };
      lan = {
        ipv4.addresses = [{
          address = "192.168.1.1";
          prefixLength = 20;
        }];
      };
    };
    nftables = {
      enable = false;
      ruleset = ''
        table ip filter {
          chain input {
            type filter hook input priority 0; policy drop;

            iifname { "lan" } accept comment "Allow local network to access the router"
            iifname "wan" ct state { established, related } accept comment "Allow established traffic"
            iifname "wan" icmp type { echo-request, destination-unreachable, time-exceeded } counter accept comment "Allow select ICMP"
            iifname "wan" counter drop comment "Drop all other unsolicited traffic from wan"
          }
          chain forward {
            type filter hook forward priority 0; policy drop;
            iifname { "lan" } oifname { "wan" } accept comment "Allow trusted LAN to WAN"
            iifname { "wan" } oifname { "lan" } ct state established, related accept comment "Allow established back to LANs"
          }
        }

        table ip nat {
          chain postrouting {
            type nat hook postrouting priority 100; policy accept;
            oifname "wan" masquerade
          }
        }

        table ip6 filter {
          chain input {
            type filter hook input priority 0; policy drop;
          }
          chain forward {
            type filter hook forward priority 0; policy drop;
          }
        }
      '';
    };
  };

  services.dnsmasq = {
    enable = true;
    settings = {
      server = [ "192.168.0.1" ];
      #port = "0";
      domain-needed = true;
      domain  = "stealthdragonland.net";
      interface = "lan";
      dhcp-option = [
        "3,192.168.0.1" # Set default gateway
        "6,192.168.0.1" # Set DNS servers to announce
        "121,192.168.0.0/20,192.168.0.1"
        ];
      dhcp-range = [ "192.168.3.1,192.168.3.255" ];
      dhcp-host = [
        "74:ee:2a:bb:45:93,192.168.0.6" # DragonPrinter
        "e0:d5:5e:6f:40:d2,192.168.0.10" # DragonBase2
        "04:7b:cb:b6:2f:8c,192.168.0.12" # DragonMobile4
        "38:f7:cd:c0:50:55,192.168.0.14" # dragon-dev
        "00:aa:bb:cc:dd:10,192.168.0.20" # primary-ap
        "1c:69:7a:64:88:e0,192.168.0.51" # amd64node2
        "d0:17:c2:88:cf:33,192.168.0.53" # amd64node4
        "2c:f0:5d:77:5d:e4,192.168.0.54" # amd64node5
        "ec:fa:bc:71:fc:96,192.168.0.101" # WeatherStation
        "94:3c:c6:45:16:57,192.168.0.102" # WeatherHub
        "f0:82:c0:a3:a5:cc,192.168.0.111" # halo-sky
        ];
    };
  };

}
