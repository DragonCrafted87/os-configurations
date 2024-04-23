{ config, lib, pkgs, ... }:

{
  environment.etc."ssh/ssh-user-keys.sh" = {
    mode = "0555";
    text = ''
      #!/run/current-system/sw/bin/bash
      # https://gist.github.com/sivel/c68f601137ef9063efd7

      case "$1" in
      dragon|root)
          USERNAME="dragoncrafted87"
          ;;
      *)
          USERNAME="$1"
          ;;
      esac

      /run/current-system/sw/bin/curl -sf "https://github.com/$USERNAME.keys"
    '';
  };
}
