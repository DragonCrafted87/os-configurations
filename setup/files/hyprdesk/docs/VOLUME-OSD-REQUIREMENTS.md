# Volume overlay requirements

Normative rules for the hyprdesk volume overlay. Display and sink routing
stay in the Hypr config `REQUIREMENTS.md`. The start menu is
[`START-MENU-REQUIREMENTS.md`](START-MENU-REQUIREMENTS.md).

The keywords are shall, shall not, recommended, not recommended, and
optional.

## Scope

hyprdesk draws this overlay when the default PipeWire sink changes level
or mute. The layer namespace is `hyprdesk-osd`. Keyboard volume keys still
call `wpctl`. The menu slider follows the start menu document and uses
the same step and the same percent text.

## One overlay

1. hyprdesk shall keep a single overlay window and update it in place.
1. A second hyprdesk process shall not bind the desk socket, and it shall
   not open another overlay.
1. The overlay shall anchor to the top left with a 24px margin, on the
   overlay layer, and it shall not take keyboard focus.
1. The overlay shall stay up for 5 seconds after the last sink change,
   then hide. A new change shall restart that timer.
1. A change the menu slider makes itself shall not pop the overlay.

## Label

1. The percent shall be centered at the top of the panel.
1. A muted sink, or a sink hyprdesk cannot read, shall show `MUTE`.
1. Otherwise the label shall be the sink level snapped to the 2.5% step,
   from `0%` through `150%`.
1. A step that is not a whole percent shall keep one decimal. `72.5%`
   shall stay `72.5%`. Whole percents shall omit the decimal (`50%`,
   `100%`, `150%`).
1. The label shall stay on one line. `112.5%` and `150%` shall be fully
   visible.

## Level bar

1. The track shall be the width of the `100%` label. That width shall
   stay fixed while the level changes.
1. The colored fill shall sit inside the track with a visible margin on
   every side. That margin shall remain when the level is `150%`.
1. Fill height shall follow the snapped level divided by `1.5`. Mute
   shall leave the track empty.
1. Above `100%`, the label, the panel border, and the fill shall use the
   overdrive red. At `100%` and below they shall use the palette text,
   border, and accent.

## Steps

1. The desk step shall be 2.5 percentage points. The maximum shall be
   `150%`.
1. `wpctl get-volume` prints two decimal places, so `0.725` comes back as
   `0.73`. The label, the fill, and the overdrive color shall use the
   2.5% step recovered from that print.

## Panel

1. A panel about three quarters of a 96px width is recommended when the
   widest label still fits, with a margin between the track and the
   panel edge.
1. If that width would clip a label, the panel shall grow until the label
   fits.
1. Colors come from `hyprtoolkit.conf`. The panel shall not add a second
   window opacity on top of the palette background alpha.
