# run command:
# nix --experimental-features "nix-command flakes" run github:nix-community/disko -- --mode disko /tmp/disk-config.nix
{
  disko.devices = {
    disk = {
      disk0 = {
        device = "/dev/disk/by-id/ata-KINGSTON_OM8P0S3128B-A0_50026B768430C41F";
        type = "disk";
        content = {
          type = "table";
          format = "gpt";
          partitions = [
            {
              name = "ESP";
              start = "1MiB";
              end = "500MiB";
              bootable = true;
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            }
            {
              name = "root";
              start = "500MiB";
              end = "100%";
              part-type = "primary";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            }
          ];
        };
      };
    };
  };
}
