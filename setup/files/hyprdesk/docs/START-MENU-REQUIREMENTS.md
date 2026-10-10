# Start menu requirements

Normative rules for the hyprdesk start menu. The volume overlay is
[`VOLUME-OSD-REQUIREMENTS.md`](VOLUME-OSD-REQUIREMENTS.md). `DESK_SHELL`
in `conf.d/shell.conf` chooses the shell. The git value stays
`quickshell`.

The keywords are shall, shall not, recommended, not recommended, and
optional.

## Scope

Super+Space runs `scripts/desk-shell.sh toggle`. When `DESK_SHELL` is
`hyprtoolkit`, that toggle talks to hyprdesk. The menu layer namespace
is `hyprdesk`. The app flyout is `hyprdesk-flyout`. A tray popup is
`hyprdesk-menu`.

## Open and close

1. The menu shall open at the pointer on the focused monitor, and it
   shall stay inside that monitor.
1. The menu width shall be `max(380, min(460, round(monitor width * 0.22)))`.
1. Escape, a click on the empty area outside the menu, and another toggle
   shall close the menu.
1. The menu shall take keyboard input on demand. It shall not take an
   exclusive grab, so Super+Space still reaches Hyprland.
1. Opening the menu shall focus the search field and shall open the All
   apps flyout.

## Categories and search

1. The categories shall be All, Accessories, Development, Games,
   Graphics, Internet, Multimedia, Office, Settings, and System.
1. Hovering a category shall open its flyout without a click. Hover shall
   not change a pinned category.
1. A click shall pin that category. A second click on the pinned category
   shall unpin it and close the flyout.
1. Typing in the search field shall list matches from every category and
   shall title the flyout Search.
1. The flyout shall show each matching app by name. An empty result shall
   say that no apps match.
1. A left click on an app shall focus a window that is already open for
   that app, on the workspace that was current when the menu opened.
   Otherwise it shall launch the app there.
1. The flyout shall scroll when the list is taller than the monitor
   allows.

## Windows

1. The menu shall list client windows from `hyprctl clients`.
1. The menu shall open on minimized windows. When none are minimized, the
   list shall show every window instead.
1. Min and All shall switch that filter. Refresh shall reread the clients.
1. A left click shall restore that window onto the workspace that was
   current when the menu opened, then close the menu.
1. A right click shall close that window.
1. An empty list shall say so. A long title shall ellipsize instead of
   stretching the menu.

## Tray

1. hyprdesk shall own `org.kde.StatusNotifierWatcher` while it runs.
1. A left click shall activate the item. A middle click shall send the
   secondary action. A vertical scroll shall scroll the item.
1. A right click shall open that item's menu at the pointer. The popup
   shall be only as large as its entries, and it shall stay on the
   monitor under the pointer.
1. A submenu shall replace the popup contents and shall offer Back.
1. When the item has no menu layout, a fallback to the item's own context
   menu at the pointer is optional.

## Volume row

1. The row shall show a mute control, a slider, and the percent.
1. The slider shall run from 0 to 150% in 2.5% steps. Dragging or
   scrolling it shall set the default sink and shall clear mute.
1. The percent shall use the same text as the volume overlay, including
   `72.5%`.
1. The mute control shall toggle mute. Muted shall read MUTE on the
   control and `0%` on the percent.
1. Above 100% the percent shall use the overdrive red.
1. Moving this slider shall not show the volume overlay.

## Clock and power

1. The menu shall show CPU, memory, GPU, and network, then the clock and
   the date. The date shall sit fully above the power row.
1. The power row shall show lock, logout, suspend, reboot, and shutdown,
   each wide enough to read, in that order.
1. Each power button shall run `scripts/session-control.sh` with that
   action, then close the menu.

## Appearance

1. Colors, rounding, and fonts shall come from `hyprtoolkit.conf`.
1. The menu and the flyout shall match the blur rules for `^hyprdesk$`
   and `^hyprdesk-flyout$`. The dismiss layer shall not be blurred.
