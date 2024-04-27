{ config, lib, pkgs, ... }:

{
  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.networkmanager.enable = true;
  networking.usePredictableInterfaceNames = true;

  # Set your time zone.
  time.timeZone = "America/Chicago";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.mutableUsers = false;
  users = {
    allowNoPasswordLogin = true;
    groups = {
      sudo = {
        name = "sudo";
      };
    };
    users = {
      dragon = {
        uid = 1000;
        createHome = true;
        isNormalUser = true;
        extraGroups = [ "wheel" "sudo" ];
        packages = with pkgs; [
        ];
      };
    };
  };

  # Needed for VS Code Server to work
  programs.nix-ld.enable = true;
  environment.systemPackages = [
    pkgs.nixpkgs-fmt
    pkgs.oh-my-posh
  ];

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    ports = [ 22 ];
    authorizedKeysCommand = "/etc/ssh/ssh-user-keys.sh";
    authorizedKeysCommandUser = "root";
    settings = {
      PasswordAuthentication = false;
      AllowUsers = null; # Allows all users by default. Can be [ "user1" "user2" ]
      UseDns = true;
      X11Forwarding = false;
      PermitRootLogin = "prohibit-password"; # "yes", "without-password", "prohibit-password", "forced-commands-only", "no"
    };
  };
  security = {
    pam = {
      enableSSHAgentAuth = true;
    };
    sudo = {
      execWheelOnly = true;
      extraRules = [
        {
          groups = [ "sudo" ];
          commands = [{
            command = "ALL";
            options = [ "SETENV" "NOPASSWD" ];
          }];
        }
      ];
    };
  };

  nix = {
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
    optimise = {
      automatic = true;
      dates = [
        "monthly"
      ];
    };
  };

  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    channel = "https://channels.nixos.org/nixos-23.11-small";
  };



  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?

}
