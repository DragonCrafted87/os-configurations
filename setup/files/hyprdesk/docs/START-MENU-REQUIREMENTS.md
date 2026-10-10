# Start menu requirements

Normative rules for the hyprdesk start menu. The volume overlay is
[`VOLUME-OSD-REQUIREMENTS.md`](VOLUME-OSD-REQUIREMENTS.md). `DESK_SHELL`
in `conf.d/shell.conf` chooses the shell. The git value stays
`quickshell`.

The keywords are SHALL, SHALL NOT, RECOMMENDED, NOT RECOMMENDED, and
OPTIONAL. They follow RFC 2119.

## Scope

Super+Space runs `scripts/desk-shell.sh toggle`. When `DESK_SHELL` is
`hyprtoolkit`, that toggle talks to hyprdesk. The menu layer namespace
is `hyprdesk`. The app flyout is `hyprdesk-flyout`. A tray popup is
`hyprdesk-menu`.

## Open and close

1. The menu SHALL open at the pointer on the focused monitor, and it
   SHALL stay inside that monitor.
1. The menu width SHALL be `max(380, min(460, round(monitor width * 0.22)))`.
1. Escape, a click on the empty area outside the menu, and another toggle
   SHALL close the menu.
1. The menu SHALL take keyboard input on demand. It SHALL NOT take an
   exclusive grab, so Super+Space still reaches Hyprland.
1. Opening the menu SHALL focus the search field and SHALL open the All
   apps flyout.

## Categories and search

1. The categories SHALL be All, Accessories, Development, Games,
   Graphics, Internet, Multimedia, Office, Settings, and System.
1. Hovering a category SHALL open its flyout without a click. Hover
   SHALL NOT change a pinned category.
1. A click SHALL pin that category. A second click on the pinned category
   SHALL unpin it and close the flyout.
1. Typing in the search field SHALL list matches from every category and
   SHALL title the flyout Search.
1. The flyout SHALL show each matching app by name. An empty result SHALL
   say that no apps match.
1. A left click on an app SHALL focus a window that is already open for
   that app, on the workspace that was current when the menu opened.
   Otherwise it SHALL launch the app there.
1. The flyout SHALL scroll when the list is taller than the monitor
   allows.

## Windows

1. The menu SHALL list client windows from `hyprctl clients`.
1. The menu SHALL open on minimized windows. When none are minimized, the
   list SHALL show every window instead.
1. Min and All SHALL switch that filter. Refresh SHALL reread the clients.
1. A left click SHALL restore that window onto the workspace that was
   current when the menu opened, then close the menu.
1. A right click SHALL close that window.
1. An empty list SHALL say so. A long title SHALL ellipsize instead of
   stretching the menu.

## Tray

1. hyprdesk SHALL own `org.kde.StatusNotifierWatcher` while it runs.
1. A left click SHALL activate the item. A middle click SHALL send the
   secondary action. A vertical scroll SHALL scroll the item.
1. A right click SHALL open that item's menu at the pointer. The popup
   SHALL be only as large as its entries, and it SHALL stay on the
   monitor under the pointer.
1. A submenu SHALL replace the popup contents and SHALL offer Back.
1. When the item has no menu layout, a fallback to the item's own context
   menu at the pointer is OPTIONAL.

## Volume row

1. The row SHALL show a mute control, a slider, and the percent.
1. The slider SHALL run from 0 to 150% in 2.5% steps. Dragging or
   scrolling it SHALL set the default sink and SHALL clear mute.
1. The percent SHALL use the same text as the volume overlay, including
   `72.5%`.
1. The mute control SHALL toggle mute. Muted SHALL read MUTE on the
   control and `0%` on the percent.
1. Above 100% the percent SHALL use the overdrive red.
1. Moving this slider SHALL NOT show the volume overlay.

## Clock and power

1. The menu SHALL show CPU, memory, GPU, and network, then the clock and
   the date. The date SHALL sit fully above the power row.
1. The power row SHALL show lock, logout, suspend, reboot, and shutdown,
   each wide enough to read, in that order.
1. Each power button SHALL run `scripts/session-control.sh` with that
   action, then close the menu.

## Appearance

1. Colors, rounding, and fonts SHALL come from `hyprtoolkit.conf`.
1. The menu and the flyout SHALL match the blur rules for `^hyprdesk$`
   and `^hyprdesk-flyout$`. The dismiss layer SHALL NOT be blurred.
