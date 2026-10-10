#!/usr/bin/env python3
"""Blank the display while Ly is the foreground greeter and input is idle.

Ly 1.1.0 has no inactivity_cmd. This process waits on the greeter VT and
calls ly-blank-displays. A Wayland or X11 session keeps the backlight on
so hypridle remains the session blanker. inactivity_delay of 0 means off,
matching Ly. BLANK_SECONDS overrides that for a short proof run.
"""

import os
import select
import subprocess
import time

BLANK_BIN = os.environ.get("LY_BLANK_BIN", "/usr/local/sbin/ly-blank-displays")
STATE = os.environ.get("LY_BLANK_STATE", "/run/ly-blank")
POLL_SECONDS = 1.0
RESCAN_SECONDS = 30.0
SESSION_COMMS = {
    "Hyprland",
    "hyprland",
    "start-hyprland",
    "Xorg",
    "X",
    "sway",
    "cage",
    "labwc",
    "weston",
    "gnome-shell",
    "kwin_wayland",
    "plasmashell",
}


def ly_config_value(key, default):
    """Return the first Ly assignment for key, without a trailing comma."""
    for path in ("/etc/ly/config.ini", "/etc/ly/config.lua"):
        try:
            lines = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with lines:
            for raw in lines:
                line = raw.split("--", 1)[0].split("#", 1)[0].strip().rstrip(",")
                if not line or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                if name.strip() != key:
                    continue
                return value.strip().strip('"').strip("'")
    return default


def configured_delay():
    """Seconds to wait, or None when Ly's inactivity_delay disables blanking."""
    override = os.environ.get("BLANK_SECONDS")
    if override:
        return max(1, int(override))
    raw = ly_config_value("inactivity_delay", "900")
    try:
        value = int(raw)
    except ValueError:
        return 900
    if value <= 0:
        return None
    return value


def ly_tty_name():
    raw = ly_config_value("tty", "2")
    digits = "".join(ch for ch in raw if ch.isdigit())
    return "tty" + (digits or "2")


def active_tty():
    try:
        with open("/sys/class/tty/tty0/active", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def tty_comms(tty):
    try:
        out = subprocess.check_output(
            ["ps", "-t", tty, "-o", "comm="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return set()
    return {line.strip() for line in out.splitlines() if line.strip()}


def graphical_session():
    """True when a user is in a Wayland or X11 session."""
    try:
        listing = subprocess.check_output(
            ["loginctl", "list-sessions", "--no-legend"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    for line in listing.splitlines():
        parts = line.split()
        if not parts:
            continue
        try:
            info = subprocess.check_output(
                [
                    "loginctl",
                    "show-session",
                    parts[0],
                    "-p",
                    "Type",
                    "-p",
                    "Active",
                    "-p",
                    "State",
                    "--value",
                ],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            continue
        fields = info.splitlines()
        if len(fields) < 3:
            continue
        kind, active, state = fields[0], fields[1], fields[2]
        if kind in ("wayland", "x11") and active == "yes" and state == "active":
            return True
    return False


def greeter_visible():
    tty = ly_tty_name()
    if active_tty() != tty:
        return False
    comms = tty_comms(tty)
    if "ly" not in comms:
        return False
    if comms & SESSION_COMMS:
        return False
    if graphical_session():
        return False
    return True


def event_nodes():
    """Input nodes that carry keys, relative motion, or a pointing device.

    EV bits in /proc/bus/input/devices are hex: bit 1 KEY, bit 2 REL,
    bit 3 ABS. ABS-only firmware nodes spam events and would hold the
    backlight on, so those stay closed unless the name is a pointer.
    """
    try:
        text = open("/proc/bus/input/devices", encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    nodes = []
    for block in text.split("\n\n"):
        name = ""
        handlers = ""
        ev_hex = ""
        for line in block.splitlines():
            if line.startswith("N: Name="):
                name = line.split("=", 1)[1].strip().strip('"')
            elif line.startswith("H: Handlers="):
                handlers = line.split("=", 1)[1]
            elif line.startswith("B: EV="):
                ev_hex = line.split("=", 1)[1].strip()
        if not ev_hex or not handlers:
            continue
        try:
            bits = int(ev_hex, 16)
        except ValueError:
            continue
        lname = name.lower()
        if "unknown" in lname:
            continue
        useful = bool(bits & 0x2 or bits & 0x4)
        if bits & 0x8 and any(tok in lname for tok in ("touch", "pad", "mouse", "track")):
            useful = True
        if not useful:
            continue
        for token in handlers.split():
            if token.startswith("event"):
                nodes.append("/dev/input/" + token)
    return nodes


def open_inputs():
    opened = []
    for path in event_nodes():
        try:
            opened.append(os.open(path, os.O_RDONLY | os.O_NONBLOCK))
        except OSError:
            continue
    return opened


def drain(fds):
    for fd in fds:
        try:
            while os.read(fd, 4096):
                pass
        except OSError:
            pass


def close_all(fds):
    for fd in fds:
        try:
            os.close(fd)
        except OSError:
            pass


def run_display(arg):
    subprocess.run([BLANK_BIN, arg], check=False)


def state_blanked():
    return os.path.exists(os.path.join(STATE, "blanked"))


def main():
    fds = None
    last_rescan = 0.0
    last_input = time.monotonic()
    blanked = False
    if state_blanked():
        run_display("unblank")

    while True:
        now = time.monotonic()
        if fds is None or now - last_rescan >= RESCAN_SECONDS:
            if fds:
                close_all(fds)
            fds = open_inputs()
            drain(fds)
            last_rescan = now

        delay = configured_delay()
        if delay is None or not greeter_visible():
            if blanked or state_blanked():
                run_display("unblank")
                blanked = False
            last_input = time.monotonic()
            time.sleep(POLL_SECONDS)
            continue

        if not fds:
            time.sleep(POLL_SECONDS)
            continue

        try:
            ready, _, _ = select.select(fds, [], [], POLL_SECONDS)
        except (OSError, ValueError):
            close_all(fds)
            fds = None
            continue

        if ready:
            for fd in ready:
                try:
                    os.read(fd, 4096)
                except OSError:
                    pass
            last_input = time.monotonic()
            if blanked or state_blanked():
                run_display("unblank")
                blanked = False
            continue

        if not blanked and time.monotonic() - last_input >= delay:
            run_display("blank")
            blanked = state_blanked()


if __name__ == "__main__":
    main()
