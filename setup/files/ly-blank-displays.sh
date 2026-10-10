#!/usr/bin/env bash
# Blank or restore the panels in front of Ly.
#
# Ly 1.1.0 draws the greeter itself, so kernel consoleblank never fires.
# amdgpu exposes connector dpms as a read-only sysfs node, so the write
# that used to live here does not change the panel. The backlight does.
#
#   ly-blank-displays.sh            power the backlight down
#   ly-blank-displays.sh unblank    restore the saved brightness
#
# A second blank keeps the brightness saved by the first one.
# LY_BLANK_SYS and LY_BLANK_STATE redirect the sysfs root and the
# state directory for the testbed.

set -u

SYS="${LY_BLANK_SYS:-/sys}"
STATE="${LY_BLANK_STATE:-/run/ly-blank}"
cmd="${1:-blank}"

write_sys() {
    local path="$1"
    local value="$2"
    [[ -e "$path" ]] || return 1
    # The shell reports a refused open itself. Redirecting printf does
    # not catch that, and amdgpu's dpms node refuses the open.
    { printf '%s\n' "$value" >"$path"; } 2>/dev/null
}

blank_backlights() {
    local bl name bright power ok=0
    mkdir -p "$STATE"
    : >"${STATE}/saved"
    for bl in "${SYS}/class/backlight"/*; do
        [[ -d "$bl" ]] || continue
        name="$(basename "$bl")"
        bright="$(cat "${bl}/brightness" 2>/dev/null || echo 0)"
        power="$(cat "${bl}/bl_power" 2>/dev/null || echo 0)"
        printf '%s %s %s\n' "$name" "$bright" "$power" >>"${STATE}/saved"
        if write_sys "${bl}/bl_power" 4; then
            ok=1
        fi
        if write_sys "${bl}/brightness" 0; then
            ok=1
        fi
    done
    for node in "${SYS}/class/drm"/card*-*/dpms; do
        [[ -e "$node" ]] || continue
        if write_sys "$node" Off; then
            ok=1
        fi
    done
    if [[ "$ok" -eq 1 ]]; then
        : >"${STATE}/blanked"
    fi
}

restore_backlights() {
    local name bright power bl
    [[ -f "${STATE}/blanked" ]] || return 0
    name=""
    bright=""
    power=""
    if [[ -f "${STATE}/saved" ]]; then
        while read -r name bright power || [[ -n "${name:-}" ]]; do
            [[ -n "$name" ]] || continue
            bl="${SYS}/class/backlight/${name}"
            [[ -d "$bl" ]] || continue
            write_sys "${bl}/bl_power" "$power" || true
            write_sys "${bl}/brightness" "$bright" || true
        done <"${STATE}/saved"
    fi
    for node in "${SYS}/class/drm"/card*-*/dpms; do
        [[ -e "$node" ]] || continue
        write_sys "$node" On || true
    done
    rm -f "${STATE}/blanked" "${STATE}/saved"
}

poke_ttys() {
    local action="$1"
    local tty
    [[ "$SYS" == /sys ]] || return 0
    command -v setterm >/dev/null 2>&1 || return 0
    for tty in /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty7; do
        [[ -c "$tty" ]] || continue
        if [[ "$action" == blank ]]; then
            setterm --blank force --powersave powerdown <"$tty" >"$tty" 2>/dev/null || true
        else
            setterm --blank poke <"$tty" >"$tty" 2>/dev/null || true
        fi
    done
}

case "$cmd" in
    blank)
        if [[ -f "${STATE}/blanked" ]]; then
            exit 0
        fi
        blank_backlights
        poke_ttys blank
        ;;
    unblank)
        restore_backlights
        poke_ttys unblank
        ;;
    *)
        printf 'usage: %s [blank|unblank]\n' "$0" >&2
        exit 2
        ;;
esac
