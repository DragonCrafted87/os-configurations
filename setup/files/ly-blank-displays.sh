#!/usr/bin/env bash
# Blank or restore the panels in front of Ly.
#
# Ly 1.1.0 draws the greeter itself, so kernel consoleblank never fires.
# The drm dpms node is read-only. On this panel, backlight brightness 0
# leaves the PWM at its floor, so the greeter stays visible. The DPMS
# property on the connector is what turns the panel off.
#
#   ly-blank-displays.sh            turn connected panels off
#   ly-blank-displays.sh unblank    turn them back on
#
# A second blank keeps the brightness saved by the first one.
# LY_BLANK_SYS and LY_BLANK_STATE redirect the sysfs root and the
# state directory for the testbed.

set -u

SYS="${LY_BLANK_SYS:-/sys}"
STATE="${LY_BLANK_STATE:-/run/ly-blank}"
cmd="${1:-blank}"

# Off is the DRM_MODE_DPMS_OFF enum value. On is 0. Confirmed on
# grotto-wyrm: property id 2 value 3 makes card0-eDP-1/dpms read Off,
# and ly does not turn it back on.
set_dpms() {
    local action="$1"
    [[ "$SYS" == /sys ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$action" <<'PY'
import ctypes
import fcntl
import glob
import os
import sys

def iowr(nr, size):
    return (3 << 30) | (size << 16) | (ord("d") << 8) | nr

GETCONNECTOR = iowr(0xA7, 80)
GETPROPERTY = iowr(0xAA, 64)
SETPROPERTY = iowr(0xAB, 16)

class Conn(ctypes.Structure):
    _fields_ = [
        ("encoders_ptr", ctypes.c_uint64),
        ("modes_ptr", ctypes.c_uint64),
        ("props_ptr", ctypes.c_uint64),
        ("prop_values_ptr", ctypes.c_uint64),
        ("count_modes", ctypes.c_uint32),
        ("count_props", ctypes.c_uint32),
        ("count_encoders", ctypes.c_uint32),
        ("encoder_id", ctypes.c_uint32),
        ("connector_id", ctypes.c_uint32),
        ("connector_type", ctypes.c_uint32),
        ("connector_type_id", ctypes.c_uint32),
        ("connection", ctypes.c_uint32),
        ("mm_width", ctypes.c_uint32),
        ("mm_height", ctypes.c_uint32),
        ("subpixel", ctypes.c_uint32),
        ("pad", ctypes.c_uint32),
    ]

class Prop(ctypes.Structure):
    _fields_ = [
        ("values_ptr", ctypes.c_uint64),
        ("enum_blob_ptr", ctypes.c_uint64),
        ("prop_id", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("name", ctypes.c_char * 32),
        ("count_values", ctypes.c_uint32),
        ("count_enum_blobs", ctypes.c_uint32),
    ]

class SetProp(ctypes.Structure):
    _fields_ = [
        ("value", ctypes.c_uint64),
        ("prop_id", ctypes.c_uint32),
        ("connector_id", ctypes.c_uint32),
    ]

def prop_name(fd, prop_id):
    prop = Prop()
    prop.prop_id = prop_id
    fcntl.ioctl(fd, GETPROPERTY, prop, True)
    return prop.name.split(b"\x00", 1)[0].decode(errors="replace")

def dpms_id(fd, connector_id):
    conn = Conn()
    conn.connector_id = connector_id
    conn.count_modes = 1
    fcntl.ioctl(fd, GETCONNECTOR, conn, True)
    count = conn.count_props
    if count <= 0:
        return None
    props = (ctypes.c_uint32 * count)()
    vals = (ctypes.c_uint64 * count)()
    encoders = (ctypes.c_uint32 * max(conn.count_encoders, 1))()
    conn.count_modes = 0
    conn.modes_ptr = 0
    conn.props_ptr = ctypes.addressof(props)
    conn.prop_values_ptr = ctypes.addressof(vals)
    conn.encoders_ptr = ctypes.addressof(encoders)
    fcntl.ioctl(fd, GETCONNECTOR, conn, True)
    for index in range(conn.count_props):
        if prop_name(fd, int(props[index])) == "DPMS":
            return int(props[index])
    return None

def connected():
    found = {}
    for path in glob.glob("/sys/class/drm/card*-*/status"):
        try:
            status = open(path, encoding="utf-8").read().strip()
        except OSError:
            continue
        if status != "connected":
            continue
        directory = os.path.dirname(path)
        name = os.path.basename(directory)
        card = name.split("-", 1)[0]
        try:
            connector_id = int(open(os.path.join(directory, "connector_id"), encoding="utf-8").read())
        except (OSError, ValueError):
            continue
        found.setdefault(card, []).append((connector_id, os.path.join(directory, "dpms")))
    return found

def main():
    action = sys.argv[1]
    want = "Off" if action == "off" else "On"
    value = 3 if action == "off" else 0
    groups = connected()
    if not groups:
        return 1
    changed = 0
    for card, connectors in groups.items():
        node = "/dev/dri/" + card
        try:
            fd = os.open(node, os.O_RDWR)
        except OSError:
            continue
        try:
            for connector_id, dpms_path in connectors:
                prop_id = dpms_id(fd, connector_id)
                if prop_id is None:
                    continue
                req = SetProp()
                req.value = value
                req.prop_id = prop_id
                req.connector_id = connector_id
                fcntl.ioctl(fd, SETPROPERTY, req)
                try:
                    got = open(dpms_path, encoding="utf-8").read().strip()
                except OSError:
                    got = ""
                if got == want:
                    changed += 1
        finally:
            os.close(fd)
    return 0 if changed else 1

sys.exit(main())
PY
}

# True when a connected connector is still scanning out. No connector
# is not "still on": the backlight fallback is the only switch there.
panel_still_on() {
    local status node
    for status in "${SYS}/class/drm"/card*-*/status; do
        [[ -f "$status" ]] || continue
        [[ "$(tr -d '[:space:]' <"$status")" == connected ]] || continue
        node="$(dirname "$status")/dpms"
        [[ -f "$node" ]] || continue
        [[ "$(tr -d '[:space:]' <"$node")" == Off ]] || return 0
    done
    return 1
}

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
    if [[ "$ok" -eq 1 ]] && ! panel_still_on; then
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
        # A backlight write can set the flag while the connector stays On.
        if [[ -f "${STATE}/blanked" ]] && ! panel_still_on; then
            exit 0
        fi
        if [[ -f "${STATE}/blanked" ]]; then
            rm -f "${STATE}/blanked" "${STATE}/method"
        fi
        if set_dpms off; then
            mkdir -p "$STATE"
            printf '%s\n' dpms >"${STATE}/method"
            : >"${STATE}/blanked"
            # setterm on the greeter VT does not blank this panel, and a
            # poke after DPMS can wake the connector again.
            exit 0
        fi
        if [[ -f "${STATE}/blanked" ]]; then
            exit 0
        fi
        blank_backlights
        poke_ttys blank
        ;;
    unblank)
        if [[ -f "${STATE}/method" ]] && [[ "$(tr -d '[:space:]' <"${STATE}/method")" == dpms ]]; then
            if set_dpms on; then
                rm -f "${STATE}/blanked" "${STATE}/method" "${STATE}/saved"
            fi
            poke_ttys unblank
            exit 0
        fi
        restore_backlights
        poke_ttys unblank
        ;;
    *)
        printf 'usage: %s [blank|unblank]\n' "$0" >&2
        exit 2
        ;;
esac
