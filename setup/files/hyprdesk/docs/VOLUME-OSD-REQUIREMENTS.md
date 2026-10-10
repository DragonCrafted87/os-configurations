# Volume overlay requirements

Normative rules for the hyprdesk volume overlay. Display and sink routing
stay in the Hypr config `REQUIREMENTS.md`. The start menu is
[`START-MENU-REQUIREMENTS.md`](START-MENU-REQUIREMENTS.md).

The keywords are SHALL, SHALL NOT, RECOMMENDED, NOT RECOMMENDED, and
OPTIONAL. They follow RFC 2119.

## Scope

hyprdesk draws this overlay when the default PipeWire sink changes level
or mute. The layer namespace is `hyprdesk-osd`. Keyboard volume keys still
call `wpctl`. The menu slider uses the same 2.5% step. Unmuted percent
text is shared with the menu. Mute copy is separate: the overlay says
`MUTE`, and the menu percent says `0%`.

## One overlay

1. hyprdesk SHALL keep a single overlay window and update it in place.
1. A second hyprdesk process SHALL NOT bind the desk socket, and it
   SHALL NOT open another overlay.
1. The overlay SHALL anchor to the top left with a 24px margin, on the
   overlay layer, and it SHALL NOT take keyboard focus.
1. The overlay SHALL open on the monitor that holds the cursor. That
   monitor's active workspace follows the cursor, so the overlay is on
   the active workspace. Each time the overlay is shown, hyprdesk SHALL
   place it on the monitor that holds the cursor then.
1. The overlay SHALL stay up for 5 seconds after the last sink change,
   then hide. A new change SHALL restart that timer.
1. A change the menu slider makes itself SHALL NOT pop the overlay.
1. The overlay SHALL match the blur rule for `^hyprdesk-osd$`.

## Label

1. The percent SHALL be centered at the top of the panel.
1. A muted sink SHALL show `MUTE`. Mute means the sink is actually muted.
1. A sink hyprdesk cannot read SHALL show `--%`. That label is not mute.
1. Otherwise the label SHALL be the sink level snapped to the 2.5% step,
   from `0%` through `150%`.
1. A step that is not a whole percent SHALL keep one decimal. `72.5%`
   SHALL stay `72.5%`. Whole percents SHALL omit the decimal (`50%`,
   `100%`, `150%`).
1. The label SHALL stay on one line. `112.5%` and `150%` SHALL be fully
   visible.

## Level bar

1. The track SHALL be the width of the `100%` label. That width SHALL
   stay fixed while the level changes.
1. The colored fill SHALL sit inside the track with a visible margin on
   every side. That margin SHALL remain when the level is `150%`.
1. Fill height SHALL follow the snapped level divided by `1.5`. Mute
   SHALL leave the track empty. An unreadable sink SHALL leave the track
   empty.
1. Above `100%`, the label, the panel border, and the fill SHALL use the
   overdrive red. At `100%` and below they SHALL use the palette text,
   border, and accent.

## Steps

1. The desk step SHALL be 2.5 percentage points. The maximum SHALL be
   `150%`.
1. The label, the fill, and the overdrive color SHALL show that snapped
   step, from `0%` through `150%`.

## Panel

1. The panel SHALL be as wide as the widest label, plus the margin
   between that label and the panel edge.
1. Colors come from `hyprtoolkit.conf`. The panel SHALL NOT add a second
   window opacity on top of the palette background alpha.
