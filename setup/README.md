# setup

One control script at this directory root applies a machine role by
calling modules under `modules/<area>/`.
Re-running a role is the intended
upgrade path. What each role runs is listed in `roles.conf`.
`roles.conf` stores module basenames; `setup/lib/lib.sh` looks each one up.
On an htpc or server the checkout is `~/machine-setup`. On a
workstation it is `~/git-workspace/homelab/machine-setup`. The
examples below use `~/machine-setup`.

```bash
~/machine-setup/setup/role.sh workstation
~/machine-setup/setup/role.sh workstation --enable-subrole laptop
~/machine-setup/setup/role.sh htpc
~/machine-setup/setup/role.sh server
~/machine-setup/setup/role.sh --target root@192.168.0.51 haos
```

```bash
~/machine-setup/setup/role.sh --hostname study workstation --enable-subrole laptop
~/machine-setup/setup/role.sh --dry-run server
```

## Hostname

The installer records a short name. A role run sets the static hostname
to that name plus `stealthdragonland.net`, for example
`runewyrm.stealthdragonland.net`. `--hostname` takes the short name, a
`.lan` name, or that FQDN. `/etc/hosts` keeps `127.0.1.1` on the short
name, and DNS keeps the FQDN on the machine's address.

## First boot

From a computer that already works, against a fresh box that has a user
and sshd:

```bash
./setup/init-remote.sh dragon@newbox.lan workstation
```

`init-remote.sh` opens one SSH master and then:

1. Installs this computer's SSH public keys on the new box
1. Copies the secrets list onto the new box
1. Installs `git` and `curl` on the new box, and writes
   `/etc/sudoers.d/<user>` with `NOPASSWD: ALL` for that user. The
   reset install boot has no terminal, so that drop-in is what later
   `sudo` calls use.
1. Generates `~/.ssh/id_ed25519` on the new box if it is missing
1. Prints the public key and registers it with GitHub using `gh` on
   this computer
1. Clones both checkouts and writes `~/.config/dot-files/role` and
   `~/.config/dot-files/checkouts`. A workstation clones
   `git@github.com:DragonCrafted87/homelab.git` to
   `~/git-workspace/homelab`, runs `git submodule update --init`
   with no path list, and links `~/dot-files` and `~/machine-setup`
   when each path is absent. An htpc or server clones
   `git@github.com:DragonCrafted87/dot-files.git` to `~/dot-files`
   and `git@github.com:DragonCrafted87/os-configurations.git` to
   `~/machine-setup`.

Same role names as `role.sh`: `workstation`, `htpc`, `server`.
`haos` is the Home Assistant OS appliance. Run that with
`role.sh --target`, which is the section below. Laptop is a subrole
(`--enable-subrole laptop`), not a top-level role.
After the clone, SSH in and run the helper with no role argument:

```bash
~/dot-files/setup/role.sh
```

The helper execs this checkout's `role.sh`.

## Hardware control

From a workstation, walk the machines that already have a saved role.
The inventory file is not in this public repo. Pass it with
`--inventory`. `list` prints each section and does not open SSH.
`dry-run` prints the two `git pull --ff-only` lines and runs
`role.sh --dry-run`. `apply` runs `git pull --ff-only` in the
`dot-files` and `machine-setup` checkouts when both are
porcelain-clean, then runs `setup/role.sh` from the machine-setup
path in `~/.config/dot-files/checkouts`. A dirty checkout stops
that host. A missing `role.sh` stops that host and names the path.
The controller does not pull a dirty tree, and it does not pass
`--reset`.

`ward-drake` stays on `role.sh --target`.

```bash
~/machine-setup/setup/control/fabric.py \
  --inventory ~/git-workspace/homelab/control/inventory.conf \
  list
~/machine-setup/setup/control/fabric.py \
  --inventory ~/git-workspace/homelab/control/inventory.conf \
  dry-run --host roost-drake
~/machine-setup/setup/control/fabric.py \
  --inventory ~/git-workspace/homelab/control/inventory.conf \
  apply --host roost-drake
```

The first run creates `~/.local/share/machine-setup/control-venv`
and installs `fabric==3.2.3` there. When `python3 -m venv` cannot
bootstrap pip, the controller uses `virtualenv`. The other machines
do not install it.

## Reset without reinstalling

`--reset` shows the removal preview, asks for approval, then asks about
the role and subroles. The last yes reboots. Later boots remove
packages, run the normal role update, and reboot once more. Workstation
and HTPC stop at Ly. Server stops at the text console.

Quitting the pager or answering no schedules nothing. `--force` is not
a reset flag. A failed phase reboots once and retries. A second failure
stays on the console until `--reset-abort`. The install boot waits until
`mirror.openmandriva.org` resolves before it runs the role, so a slow
DNS startup does not spend both attempts.

```bash
./setup/role.sh --reset
./setup/role.sh --reset --role htpc
./setup/role.sh --dry-run --reset
./setup/role.sh --reset-abort
```

`/home` stays. The remove boot drops other user-installed rpms and extra
Flatpaks. Add names to `files/packages/never-remove.list` if something
you want is listed.

Installer changes can be tried in the OpenMandriva container, and a
role reset in the libvirt clone, before they run on a live machine.
See [testbed/README.md](testbed/README.md).

A single module can be run on its own:

```bash
~/machine-setup/setup/modules/common/link-user-config.sh
```

## Module areas

Scripts sit under `modules/<area>/` so the tree shows why they exist.
`roles.conf` still lists the basename.

| Area      | What lives there                                                                       |
| --------- | -------------------------------------------------------------------------------------- |
| `common`  | ssh, sudoers, repos, timezone, locale, plasma removal, links, XDG dirs, Dolphin places |
| `desktop` | Hyprland, Brave, Flatpak, CUPS, gaming, MIME, VS Code                                  |
| `network` | mounts, bluetooth, NFS server                                                          |
| `compute` | BOINC, k3s, python-dev, MakeMKV, artifact/docker stubs                                 |
| `host`    | `configure-laptop` / `htpc` / `server`, Hyper-V guest                                  |

Do not name folders after roles. Laptop is a workstation overlay.

## Roles

Edit `roles.conf` to change the module lists. `[common]` runs for
`workstation`, `htpc`, and `server`. `[haos]` does not run `[common]`.
`laptop` is `[subrole.laptop]` on top of `workstation`.

| Role          | Extra modules                                                                                                   |
| ------------- | --------------------------------------------------------------------------------------------------------------- |
| `workstation` | Hyprland, desktop apps, Brave, Grok Bot, VS Code, LibreOffice, CUPS, Steam, MakeMKV, KDE Connect, BOINC Manager |
| `htpc`        | Hyprland, desktop apps, Brave, k3s, BOINC client. Couch build-out: `../../docs/htpc-role.md`                    |
| `server`      | CLI baseline, k3s, BOINC client; no GUI session                                                                 |
| `haos`        | SSH keys and the short hostname on a Home Assistant OS appliance                                                |

`enable-subrole laptop` adds `configure-laptop` (power-profiles-daemon).

`enable-subrole nfs-server` installs the NFS server, creates `/srv/data`,
and exports that path to `192.168.0.0/20` (`255.255.240.0`) with
`rw,no_root_squash,no_subtree_check`. The line lives in
`setup/files/network/nfs-server.exports`. A later run rewrites
`/etc/exports.d/dot-files.exports` when the file drifts. The module
does not partition a disk or copy data onto `/srv/data`. When firewalld
is already running it allows the `nfs`, `mountd`, and `rpc-bind`
services. It does not install or start firewalld.

`[server]` includes `@subrole.hyperv-guest`. The module returns
before it changes the machine unless `systemd-detect-virt` prints
`microsoft`. On a Hyper-V guest it installs `hyperv-tools` and
`chrony`, runs `chronyd -n` so the OpenMandriva forking unit does not
wait for a pid file chronyd 4.6 never writes, points the KVP, VSS, and
file-copy units at `/usr/bin/hv_kvp_daemon`, `hv_vss_daemon`, and
`hv_fcopy_uio_daemon`, and forces `hv_vmbus`, `hv_storvsc`, `hv_netvsc`,
and `hv_utils` into the initramfs. A vmbus device that is already
present is triggered through udev before its unit starts. A missing
device is skipped. Another role can use the same `@` line or
`--enable-subrole hyperv-guest`.

`configure-xdg-user-dirs` pins `~/.config/user-dirs.dirs` to the
lowercase directories (`~/desktop`, `~/downloads`, `~/templates`,
`~/public`, `~/documents`, `~/music`, `~/pictures`, `~/videos`) and
sets `enabled=False` in `user-dirs.conf`, so login does not recreate
the English CamelCase names. `~/network` stays with
`install-network-mounts`. The same step rewrites
`~/.local/share/user-places.xbel` when a bookmark `href` is a `file://`
URL under `$HOME` whose first directory is one of those CamelCase
names. A name whose CamelCase directory is still in `$HOME` after the
move is left alone. Trash, remote, network, and recent places stay as
they are. A second run that already has the lowercase href does not
rewrite the file.

Dolphin is the Hyprland file manager (`SUPER+E`). After
`remove-plasma-sddm` strips Plasma, it has no KService/MIME map unless
`install-desktop-packages` installs `plasma6-dolphin` plus KIO extras and
`configure-mime-defaults` writes `~/.config/mimeapps.list` and runs
`kbuildsycoca6`. Text and Markdown go to the installed VS Code entry.
An existing list keeps handlers whose desktop file is still on disk;
missing ones are filled in, and handlers that name a removed desktop
file are replaced. The other half is `config/hypr/lua/env.lua`
(`XDG_CURRENT_DESKTOP=Hyprland:KDE`) so KIO treats LibreOffice and Okular
as valid "Open with" targets.

`configure-secret-portal` runs on workstation and htpc. It symlinks
`~/.config/xdg-desktop-portal/hyprland-portals.conf` at the shipped file,
which keeps `default=hyprland;gtk` and selects gnome-keyring for the
Secret portal. The KDE half of that desktop name makes the portal's
UseIn fallback pick `kwallet.portal`. Nothing on this session provides
that name, so Chromium cannot store an encryption key.

`configure-brave-keyring` runs on those same roles. It writes
`~/.config/kwalletrc` so `[org.freedesktop.secrets] apiEnabled` is
`false`, and it leaves every other line in that file alone. KWallet
stays available to KDE apps. It does not export the Secret Service, so
the login keyring stays the only provider on that bus. A missing
`kwalletrc` still gets the key, because KWallet's default for it is
true.

`install-grok-bot` runs on workstation, after MIME defaults. It copies
the pinned AppImage to `~/.local/share/grok-bot/Grok_Bot.AppImage` when
the hash differs, including from `~/downloads` when that file already
matches, and extracts that file next to it. `~/.local/bin/grok-bot`
starts the extracted binary with `--password-store=gnome-libsecret`
and leaves `APPIMAGE` unset. Launching the AppImage itself rewrites
the desktop file without that flag, and this session then selects
KWallet, so the saved login cannot be read. `grok-bot --help` prints
usage and does not start Grok Bot. The desktop file handles
`x-scheme-handler/grokbot` and `x-scheme-handler/sand`.

The chosen role is written to `~/.config/dot-files/role`. An `haos`
run leaves that file alone.

Rock extra / restricted / non-free are enabled on every role. Architecture
is AMD family 23+ → `znver1`, otherwise `x86_64` (ISO `rpm %{_arch}` is
usually `x86_64` even on Zen). The opposite arch is disabled.

`point-rock-repos-at-pulp` runs after the Rock repos are enabled. It
rewrites the baseurl of the eight Rock ids for this machine's
architecture to `https://pulp.stealthdragonland.net/pulp/content/rock/`.
`gpgcheck` and `gpgkey` stay. The second public mirror is dropped. A
matching file is left alone. A dry run prints the rewrite and does
not write. `distro-release-repos` replaces that file when it updates,
and the next role run points it at Pulp again.

`enable-pulp-repo` runs on every role after that. It writes
`/etc/yum.repos.d/homelab-pulp.repo` with baseurl
`https://pulp.stealthdragonland.net/pulp/content/homelab/`. Packages in
that distribution are unsigned, so the file sets `gpgcheck=0`.
`skip_if_unavailable=1` lets a later `dnf` install continue from Rock
when Pulp does not answer. A second run leaves a matching file alone.

Brave, Visual Studio Code, and Temurin 25 install from the same Pulp
host. Their base paths are `brave/x86_64/`, `vscode/`, and
`adoptium/rhel/9/x86_64/`. The vendor gpg keys stay on the vendor
hosts. Flatpak, the k3s install script, and the tarball downloads are
not pointed at Pulp.

Harvest printer queues on the current workstation, then commit them:

```bash
sudo ~/machine-setup/setup/utility/harvest-cups.sh
```

That copies `/etc/cups/printers.conf` and `/etc/cups/ppd/` into
`setup/files/cups/`.
Workstation and laptop replay those
files.

## Home Assistant OS (ward-drake)

`ward-drake` is the Home Assistant OS image on the NUC that was
`amd64node2.lan`. The disk image step is
`setup/ventoy/ward-drake/install-haos.sh`. After that image boots, run
this from a machine that already has the repo:

```bash
./setup/role.sh --target root@192.168.0.51 haos
```

That is the run. `[haos]` does not run `[common]`, and it does not
change the saved role on the machine where you type it.

The run uses Home Assistant OS host SSH on port 22222. Key login
installs the GitHub keys into `/root/.ssh/authorized_keys` on the host
and sets the short hostname to `ward-drake`. That file is the host
login list. The Terminal & SSH app does not own it. When nothing is
listening on the port, the command writes
`~/.cache/dot-files/haos-config/authorized_keys` and stops. Copy that
file onto a USB partition named `CONFIG`, import it (`ha os import`,
or reboot with the stick attached), and run the command again.

The same run installs the key updater and the console lock under
`/mnt/overlay/dot-files`. The root filesystem is erofs, and
`/etc/systemd/system` is on that filesystem, so the role does not
install unit files there. A udev rule starts `haos-supervise.sh`
after the overlay is mounted. The supervisor refreshes the GitHub
keys two minutes after boot and every twelve hours after a successful
fetch. A bad or empty fetch leaves the current `authorized_keys` in
place and retries in two minutes. The script is `/bin/sh`. The
workstation updater stays
`/usr/local/bin/sync-github-authorized-keys.sh` and still runs as
`dragon`.

The HDMI console starts `ha-cli@tty1`, which accepts commands with no
password. The run adds `systemd.mask=ha-cli@tty1.service` and
`systemd.mask=getty@tty1.service` to `/mnt/boot/cmdline.txt`, keeping
`console=tty0`, and masks both units for the current boot. The
supervisor holds tty1. The screen says the console is locked and
names SSH port 22222. Host SSH on that port stays up. The cmdline
change applies on the next boot.

`init-remote.sh` rejects `haos` and prints that `role.sh --target`
command. DNS for `ward-drake.stealthdragonland.net` stays on
`192.168.0.1`. Until that name resolves, pass the address to
`--target`. `ssh ward-drake` uses `root` on port 22222 once the name
resolves and `ssh-config` is the file the client is reading.

## OpenWrt keys (mist-dragon, beacon-dragon, wicket-dragon, bailey-dragon)

Dropbear on these boxes reads `/etc/dropbear/authorized_keys` for root.
`~/.ssh/authorized_keys` is not that file. The updater is
`setup/files/ssh/openwrt-sync-github-keys.sh`. It is `/bin/sh`. Copy it
to `/usr/bin/openwrt-sync-github-keys.sh` and run it from root's crontab
every twelve hours:

```cron
0 */12 * * * /usr/bin/openwrt-sync-github-keys.sh
```

A bad or empty fetch leaves the current file. A fetch that contains
none of the keys already in the file also leaves it, so a router with
password login off cannot lose its only key. The AP is an EnGenius
EAP1300 on OpenWrt 22.03. It has `uclient-fetch` and no curl. The
script tries `uclient-fetch`, then curl, then wget. No extra package.

Copy secrets onto a new box without going through `init-remote.sh`:

```bash
~/machine-setup/setup/utility/transfer-secrets.sh dragon@newbox.lan
```

## OpenWrt host status (mist-dragon, beacon-dragon, wicket-dragon, bailey-dragon)

`setup/files/status/host-status.sh` is the collector. It is a byte copy
of the host-status image script. Copy it to `/usr/bin/host-status.sh`.
`setup/files/status/host-status.init` is the procd script. Copy it to
`/etc/init.d/host-status`, then enable it and start it. Install
`mosquitto-client-nossl`. The init script publishes to `192.168.8.21`.
Add both installed paths to `/etc/sysupgrade.conf`:

- `/usr/bin/host-status.sh`
- `/etc/init.d/host-status`

## Hyprland from source

`install-hyprland-session` enables Ly and the user session units. It
does not install the OpenMandriva Hyprland rpms, uwsm, or
pavucontrol-qt. Role reset removes the distro `hyprland` package.
`install-hyprland-source` (workstation / laptop / htpc) exits 0 while
a distro `hyprland` package is installed. Vendor `homelab` is our
package. When that version matches the pin, the module leaves it
installed. Otherwise it installs the homelab RPMs, which place files
in `/usr/local`. dnf 4 stops when that path is already on disk and no
package owns it, so the module downloads the transaction and runs
`rpm -Uvh --replacefiles`. The download asks only for this machine's
arch (`znver1` on Zen, `x86_64` otherwise). `dnf download` otherwise
resolves both builds of the same version.
Pins live in `setup/versions.conf` next to the BOINC and MakeMKV
versions. Current pin is **v0.56.2**. Do not set the prefix to `/usr`.
`rpms/` builds one RPM per source project, for `x86_64` and `znver1`.
The workstation role installs `rpm-build` and `x11-util-macros` so that
machine can run `rpms/build.sh`.

Ly session name is **Hyprland**, with
`Exec=/usr/local/bin/start-hyprland`. The desktop file is
`/usr/share/wayland-sessions/hyprland.desktop`.
`hypridle`, `hyprpolkitagent`, the Hyprland portal, `hyprsunset`, and
`hyprpaper` exec `/usr/local`. hyprpwcenter is the volume UI.
hyprdesk is the start menu and volume OSD. `hyprdesk.service` starts
it after `hyprland-session.service`. Super+Space runs
`/usr/local/bin/hyprdesk --toggle`. The xkb data link
`/usr/local/share/X11/xkb` stays a role step. It points at the distro
`/usr/share/X11/xkb`.

```bash
~/machine-setup/setup/modules/desktop/install-hyprland-source.sh
~/machine-setup/rpms/build.sh
```

Override a pin in the environment; an exported value wins over
`versions.conf`. The Hyprland packages are built with GCC. Clang 19
crashes the compositor at launch. BOINC is built with Clang.

## Home Assistant notifications

`install-ntfy-server` is on the haos role. It serves ntfy 2.29.0 on
ward-drake, published at
`http://ward-drake.stealthdragonland.net:2586`, topic `workstations`.
Passwords are written once to `/mnt/data/ntfy/credentials` on that
host. A later run reuses the bcrypt hashes already in `server.yml`
and leaves the container up when that file is unchanged.

`install-ntfy-subscribe` is on workstation. It installs the same ntfy
client and enables `ntfy-workstations.service` on
`workstation-session.target`. The unit starts when
`~/.config/ntfy/client.yml` exists. That path is on the secrets list.
The haos role writes it on the machine that runs `--target`. Copy it
to the other workstation with `setup/utility/transfer-secrets.sh`.
Each message is handed to `notify-send`, so mako shows it. The saved
message id is where the next start continues, and the first start
asks for the last 24 hours. The htpc role does not subscribe.

Home Assistant publishes with `notify.send_message` on
`notify.workstations`. The integration account is `homeassistant`.
Desktops use the read-only `workstation` account.

## KDE Connect / GrapheneOS SMS

`install-kdeconnect` is on workstation (and therefore laptop). It
installs the `kdeconnect` rpm plus `android-tools`, and opens firewalld
ports 1714-1764 (or the packaged `kdeconnect` service if present).
Hyprland starts the daemon from `config/hypr/scripts/start-kdeconnect.sh`.

Pair the GrapheneOS phone yourself. Steps are in
`setup/files/kdeconnect/README.md`. Short version: F-Droid KDE Connect,
same Wi-Fi, pair, grant SMS/contacts/notifications, enable the SMS
plugin. Sent messages that never show up on the desktop need:

```bash
adb shell appops set --uid org.kde.kdeconnect_tp READ_RESTRICTED_MESSAGES allow
adb shell am force-stop org.kde.kdeconnect_tp
```

## MakeMKV

`install-makemkv` is on workstation (and therefore laptop). It exits
immediately if no optical drive is present (`/dev/sr*` with
`ID_CDROM=1`). Otherwise it builds MakeMKV 1.18.4 from the official
oss+bin tarballs using `clang`/`clang++` and `lld`, against distro
ffmpeg/Qt5 devel packages. Override the version with
`MAKEMKV_VERSION=1.18.4`.

Login autostart runs `~/bin/sync-makemkv-desktops.sh`, which writes one
`~/desktop/MakeMKV-srN.desktop` per attached drive and deletes stale
ones. Re-run that script after plugging in a USB Blu-ray drive.

```bash
~/machine-setup/setup/modules/compute/install-makemkv.sh
~/bin/sync-makemkv-desktops.sh
```

## ScummVM / Quest for Glory

`install-scummvm-quest-for-glory` is an optional module (not part of any
role). It installs the distro `scummvm` package, links the binary under
`~/games/scummvm`, copies Quest for Glory data out of the Steam
collection, and writes Desktop plus applications-menu launchers.

Expected Steam path:

```text
~/games/steam-library/steamapps/common/Quest for Glory Collection/
```

Override with `STEAM_QFG`. Game data lands in `~/games/quest-for-glory/`
(DOSBox binaries are not copied). Isolated config and saves live in
`~/games/scummvm/`. Icons come from the official scummvm-icons repo.
QFG5 is copied when present; a launcher is created only if that ScummVM
build lists the game.

```bash
~/machine-setup/setup/modules/desktop/install-scummvm-quest-for-glory.sh
```

## BOINC

Every role installs the homelab `boinc` RPM, version 8.2.13 from
`setup/versions.conf`. Override with `BOINC_VERSION`. A matching
homelab version is left installed. The manager still needs the wxGTK
3.2 runtime libraries (`lib64wx_baseu3.2_0`, `lib64wx_baseu_net3.2_0`,
`lib64wx_gtk3u_core3.2_0`, `lib64wx_gtk3u_html3.2_0`,
`lib64wx_gtk3u_webview3.2_0`). GPU detection needs Mesa Rusticl
(`lib64RusticlOpenCL`), which provides `/etc/OpenCL/vendors/rusticl.icd`.
The client unit sets `RUSTICL_ENABLE=radeonsi,r600` so that platform
exposes Navi and the Caicos Radeon HD 7450.
The RPM links `libboinc_opencl` to `libOpenCL`. Reset removes Rusticl,
so every live role run installs the wxGTK libraries and Rusticl again.
An RPM version match does not count until `ldd` shows `libOpenCL.so`
on `libboinc_opencl.so`.

The `boinc` package is built with Clang. The `znver1` RPM uses
`-march=znver1`. The `x86_64` RPM uses `-march=x86-64`.

```text
/etc/systemd/system/boinc-client.service
~/.local/share/boinc/                     data dir
/usr/local/bin/boinc{,mgr,cmd}
/usr/local/bin/boinc-config
/usr/local/bin/boinc-gpu
/usr/local/bin/boinc-status
/usr/local/bin/boinc-status-all
```

Repo copies of the helpers keep the `.sh` suffix under
`setup/files/boinc/`.
PATH names do not.

`loginctl enable-linger` keeps the user unit
running after logout so servers and the HTPC still crunch without a
desktop session.

```bash
boincmgr
boinc-config
boinc-status
boinc-status-all
systemctl --user status boinc-client.service
```

Fill `files/boinc/hosts.list` with real hostnames so each client allows
GUI RPC from the others. Role prefs live in `files/boinc/prefs/<role>.xml`
and are linked to `~/.local/share/boinc/global_prefs_override.xml`.

`boinc-config` always retargets that override from the role XML and tells
the client `--read_global_prefs_override`. After prefs are applied it
attaches Science United if the secret file has a login. `BOINC_REPLACE=1`
detaches and reattaches.

`~/.config/dot-files/boinc-rpc.password` holds `rpc_password`,
`science_united_user` (the Science United **email**), and
`science_united_password`. `utility/transfer-secrets.sh` copies that
file.

In the manager: Advanced → Select computer → `127.0.0.1` + that
password. Do not let the manager start a second client; the system unit
already owns port 31416.

`k3s.slice` and `boinc.slice` sit beside `user.slice`. BOINC keeps
`Nice=10` and `lower_client_priority`. Wine (`wine`, `wine64`, `wineserver`) pauses
BOINC via `cc_config.xml` exclusive apps. Browsers are not exclusive
apps so long-lived Brave/Firefox windows do not park the client.
RAM limits must use `ram_max_used_idle_pct` / `ram_max_used_busy_pct` /
`vm_max_used_pct` (percent 0-100). The old `*_frac` tags are ignored.

Native BOINC honors `run_if_user_active`, `run_gpu_if_user_active`, and
`idle_time_to_run` directly. Desktop roles keep CPU on while the session
is busy, leave the GPU off until the displays blank, and use the
idle/busy RAM split. Hyprland does not swap pref files. `boinc-gpu`
(from `idle-display-off.sh` / `idle-display-on.sh`, and from
`graphical-session.sh` at login and logout) sets GPU mode to `always`
or `never`. A server has no hypridle session, so its GPU follows the
role XML.

Current `global_preferences` overrides:

| Role          | CPU while active | CPU cap | CPU limit | Suspend if other CPU | Idle delay | RAM idle/busy | GPU while active |
| ------------- | ---------------- | ------- | --------- | -------------------- | ---------- | ------------- | ---------------- |
| `workstation` | yes              | 35%     | 50%       | 20%                  | 3 min      | 40% / 25%     | no               |
| `laptop`      | yes              | 30%     | 50%       | 20%                  | 3 min      | 30% / 15%     | no               |
| `htpc`        | yes              | 60%     | 80%       | 35%                  | 3 min      | 40% / 20%     | no               |
| `server`      | yes              | 80%     | 100%      | 30%                  | 0          | 40% / 30%     | yes              |

None of the roles run on battery. Edit the XML under `files/boinc/prefs/`
and re-run `install-boinc.sh` or `boinc-config`.

Docker image manager is a standalone placeholder, not part of every server:

```bash
~/machine-setup/setup/modules/compute/install-docker-image-manager.sh
```

## Config links

`modules/common/link-user-config.sh` links every directory in repo
`config/` into `~/.config` with the same name:

```text
config/hyprland    ->  ~/.config/hyprland
config/kitty       ->  ~/.config/kitty
```

Drop another folder under `config/` and the next role run links it. No
module edit. Loose files in `config/` are ignored. A real file or
directory already sitting at the destination is not overwritten.
