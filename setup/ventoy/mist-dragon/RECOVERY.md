# mist-dragon recovery

mist-dragon is the GEEK+ G34 at 192.168.0.1. Its disk is a KINGSTON
OM8P0S3, about 119G. The boot console is HDMI (`tty1`) and serial
`ttyS0` at 115200 8N1. The house can stay offline through the reboots
below. Do not reflash while an upgrade is still rebooting to grow the
root partition. That grow is two extra reboots and can take several
minutes.

## The router boots, and the default route is wrong

From runewyrm:

```sh
ssh root@mist-dragon 'ip route show default'
```

A good route contains `dev eth0` and does not contain `dev tun0`. The
`via` address on `eth0` is whatever Starlink handed out. When the
default is `dev tun0`, delete those routes before changing anything
else:

```sh
ip route del default dev tun0
ip route del 0.0.0.0/1
ip route del 128.0.0.0/1
ip route show default
```

`/etc/hotplug.d/iface/99-no-tun-default` and
`/etc/hotplug.d/iface/98-vpn-reply` put that back on each tun0 ifup.
Both files are in the sysupgrade backup. Do not delete them, and do
not restart OpenVPN until the first script is on disk.

Then, from runewyrm:

```sh
ip route show default | grep -q 'via 192.168.0.1'
ping -c 2 -W 3 1.1.1.1
nslookup example.com 192.168.0.1
```

## The router does not boot

Boot the Ventoy stick from the firmware boot menu. Choose the
OpenMandriva live image. The desktop mounts the stick at
`/media/live/Ventoy`, and that mount is often `noexec`.

```sh
sudo su
bash /media/live/Ventoy/scripts/mist-dragon/reflash.sh
```

The script lists the images in `raw-disc-images/`. Pick from the
number it prints.

- `openwrt-24.10.8-x86-64-generic-ext4-combined-efi.img.gz` is the
  stock image for the release that was running. Use it when the
  25.12 image itself will not boot.
- `openwrt-25.12.5-x86-64-generic-ext4-combined-efi-mist-dragon.img.gz`
  is the owut build with this router's packages. Use it when a write
  was interrupted, or when you want 25.12 again without waiting on
  the build server.
- `openwrt-25.12.5-x86-64-generic-ext4-combined-efi.img.gz` is stock
  25.12.5. It does not contain unbound, OpenVPN, or the other
  packages in `scripts/mist-dragon/backup/owut-list.txt`.

Type the disk `lsblk` shows as `KINGSTON OM8P0S3`. The script refuses
the Ventoy stick, a disk that holds `/` or `/boot`, and any other
model. Then type `wipe mist-dragon`.

Unplug the stick and boot the internal disk. Wait through the resize
reboots before treating a quiet machine as a failed flash.

A fresh image answers at `192.168.1.1` with no root password. On
runewyrm:

```sh
link-bench static
ssh root@192.168.1.1
```

The script copies the newest file in
`scripts/mist-dragon/backup/` to `/root/mist-dragon-backup.tar.gz` on
the new root. Read `/root/RECOVERY.txt` on the router.

Two tars are in that directory. The newest,
`mist-dragon-25.12.5.tar.gz`, was taken after the 25.12.5 boot and
includes `/etc/init.d/vpn-relay`. The older
`mist-dragon-24.10.8-pre-25.12.tar.gz` does not. A loose copy of
that init script is `scripts/mist-dragon/vpn-relay`. If a restore
leaves `/etc/init.d/vpn-relay` missing, copy that file there,
`chmod 755` it, and run `/etc/init.d/vpn-relay enable`.

On the owut image, restore now:

```sh
sysupgrade -r /root/mist-dragon-backup.tar.gz
```

On a stock image, install the packages while the fresh image's DNS
still works, then restore. A restore puts unbound in charge of DNS,
and unbound is not on a stock image.

```sh
opkg update
opkg install $(tr ' ' '\n' </root/owut-list.txt | grep -v '^-')
sysupgrade -r /root/mist-dragon-backup.tar.gz
```

The stick copy of that list is
`scripts/mist-dragon/backup/owut-list.txt`. Copy it to `/root/`
before the install if it is not already there. 25.12 uses `apk`
instead of `opkg`. The list was taken on 24.10. On a stock 25.12
image, skip `acme`, `luci-app-acme`, and `kmod-ovpn-dco-v2`, and
add `kmod-ovpn-backports`. The owut image already has that set, so
it only needs `sysupgrade -r`.

After the restore reboot, the LAN is `192.168.0.1/16` again. On
runewyrm:

```sh
link-bench lan
```

Run the route check from the first section. Key login is the
DragonCrafted87 GitHub set in the backup. Password login stays off.
