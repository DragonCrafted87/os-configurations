# Start menu requirements

Normative rules for the hyprdesk start menu. The volume overlay is
[`VOLUME-OSD-REQUIREMENTS.md`](VOLUME-OSD-REQUIREMENTS.md). Super+Space
runs `/usr/local/bin/hyprdesk --toggle`.

The keywords are SHALL, SHALL NOT, RECOMMENDED, NOT RECOMMENDED, and
OPTIONAL. They follow RFC 2119.

## Scope

That toggle opens or closes this menu. The menu layer namespace is
`hyprdesk`. The app flyout is `hyprdesk-flyout`. A tray popup is
`hyprdesk-menu`. The icon-name label is `hyprdesk-tip`.

## Open and close

1. The menu SHALL open at the pointer, on the monitor that holds the
   cursor. That monitor's active workspace follows the cursor. The menu
   SHALL stay on that monitor after it opens, including when the cursor
   later moves. The flyout, the dismiss layer, a tray popup opened from
   the menu, and the icon-name label SHALL stay on that same monitor.
   The menu SHALL stay inside that monitor.
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
1. The search field and those category buttons SHALL stay fully
   visible, without scrolling, when the menu has room for them and the
   rows below them. The window list SHALL shrink and scroll before
   that block does.
1. Hovering a category SHALL open its flyout without a click. Hover
   SHALL NOT change a pinned category.
1. The pointer entering the windows, tray, volume, status, or power
   section SHALL close an unpinned flyout.
1. A click SHALL pin that category. A second click on the pinned category
   SHALL unpin it and close the flyout.
1. Typing in the search field SHALL list matches from every category and
   SHALL title the flyout Search.
1. The flyout SHALL show each matching app by name, left aligned. When the
   desktop entry has an icon, the row SHALL show that icon and then the
   name. The icon SHALL come from the theme named by `Theme` under
   `[Icons]` in `${XDG_CONFIG_HOME:-~/.config}/kdeglobals`, then from
   the themes named by that theme's `Inherits`, then from hicolor under
   the XDG data directories. hyprdesk SHALL prefer the closest size to the
   row. Within one size, a bitmap SHALL be used ahead of an SVG. A
   bitmap of a different size SHALL NOT hide a closer SVG. An empty
   result SHALL say that no apps match.
1. A left click on an app SHALL focus a window that is already open for
   that app and move it to the workspace that was current on the monitor
   under the menu. Otherwise it SHALL launch the app on that workspace.
1. The flyout SHALL be no taller than its rows, and SHALL NOT be taller
   than the menu. It SHALL scroll when the rows still do not fit.

## Windows

1. The menu SHALL list client windows from `hyprctl clients`.
1. Each window row SHALL show that window's workspace.
1. The menu SHALL open on minimized windows. When none are minimized, the
   list SHALL show every window instead.
1. Min and All SHALL switch that filter. Refresh SHALL reread the clients.
   The Refresh label SHALL stay on one line.
1. A left click SHALL move that window onto the workspace that was
   current on the menu's monitor when the menu opened, then focus it,
   then close the menu. The window SHALL end focused on that workspace.
   The minimized workspace SHALL NOT be left visible.
1. A right click SHALL close that window.
1. An empty list SHALL say so. A long title SHALL ellipsize instead of
   stretching the menu.

## Tray

1. hyprdesk SHALL own `org.kde.StatusNotifierWatcher` while it runs.
1. The tray row SHALL stay visible, including when no items are
   registered. An empty tray SHALL still show one full row. A long
   window list SHALL shrink and scroll instead of pushing the tray out
   of the menu. Items that register while the menu is open SHALL appear
   without closing the menu.
1. Each item SHALL show its theme icon when that icon exists, and
   otherwise the image from its `IconPixmap`. The button SHALL NOT cover
   that image with the item id.
1. A left click SHALL activate the item. When that item's action is a
   menu, the left click SHALL open the same popup a right click opens.
   A middle click SHALL send the secondary action. A vertical scroll
   SHALL scroll the item. Activate and the secondary action SHALL use
   the pointer position.
1. A right click SHALL open that item's menu at the pointer. The popup
   SHALL grow to hold its entries. An empty popup SHALL still show one
   full row. The popup SHALL stay on the monitor the start menu was
   opened on.
1. A submenu SHALL open beside its parent when the pointer hovers that
   row. Parent menus SHALL stay open until the pointer leaves the whole
   menu tree, or until the pointer enters another part of the start menu.
   Those menus SHALL NOT close or free themselves in the same pointer
   event that opened them.
1. The name of a tray icon SHALL be shown beside the pointer. That label
   SHALL NOT close or free itself in the same pointer event that opened
   it. The label SHALL stay on the monitor the start menu was opened on.
1. A left click on a menu entry that is not a submenu SHALL close the
   start menu.
1. When the item has no menu layout, a fallback to the item's own context
   menu at the pointer is OPTIONAL.

## Volume row

1. The row SHALL show a mute control, a slider, and the percent.
1. The slider SHALL run from 0 to 150% in 2.5% steps. Dragging or
   scrolling it SHALL set the default sink and SHALL clear mute.
1. The percent SHALL use the same numeric text as an unmuted volume
   overlay, including `72.5%`. A muted sink SHALL show `0%`. A sink
   hyprdesk cannot read SHALL show `--%`.
1. The mute control SHALL toggle mute. A muted sink SHALL read `MUTE`
   on the control. An unreadable sink SHALL read `--` on the control.
   That caption is not mute.
1. Above 100% the percent SHALL use the overdrive red.
1. Moving this slider SHALL NOT show the volume overlay. Scrolling it
   SHALL NOT scroll the menu.

## Clock and power

1. The menu SHALL show CPU, memory, GPU, and network, then the clock and
   the date. The clock and the date SHALL use the same font size, and
   both SHALL stay fully visible when the menu is against the bottom of
   the screen. Each status field SHALL have a fixed width sized for its
   maximum value, so a change in digits SHALL NOT move the other fields.
   Those maxima are `cpu 100%`, memory used as wide as the total,
   `gpu 100%`, `100°` when a temperature is shown, and a network state
   at least as wide as `unknown`.
1. The power row SHALL be the bottom row of the menu. It SHALL show
   lock, logout, suspend, reboot, and shutdown, each wide enough to
   read, in that order.
1. Category buttons and power buttons SHALL NOT use the accent fill.
1. Each power button SHALL run `scripts/session-control.sh` with that
   action, then close the menu.

## Appearance

1. Colors, rounding, and fonts SHALL come from `hyprtoolkit.conf`.
1. The menu and the flyout SHALL match the blur rules for `^hyprdesk$`
   and `^hyprdesk-flyout$`. The dismiss layer SHALL NOT be blurred.
