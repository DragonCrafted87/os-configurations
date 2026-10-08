#!/usr/bin/env bash
# Enable the Hyprland-related user units that are already in use.
# Distro audio/dbus sockets are left alone. These WantedBy
# graphical-session.target, which hyprland-session.service binds after
# login (ly -> Hyprland.desktop does not start that target).
# workstation-session.target / htpc-session.target hold role GUI apps.
# network-mounts.service is custom and is enabled in install-network-mounts.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user

enable_user_service hypridle.service
enable_user_service hyprpolkitagent.service
enable_user_service mako.service
enable_user_service hyprsunset-times.timer

# hyprpolkitagent is the session agent. Disable the desktop ones if a
# previous login left them enabled.
for unit in \
    polkit-gnome-authentication-agent-1.service \
    org.kde.polkit-kde-authentication-agent-1.service \
    plasma-polkit-agent.service
do
    disable_user_service "$unit"
done

# Desk vs HTPC GUI apps. graphical-session.target starts the enabled target.
# Drop the PR 59 oneshot unit names if they are still enabled.
role="$(saved_role)"
disable_user_service workstation-session.service
disable_user_service htpc-session.service
case "$role" in
    workstation)
        enable_user_service workstation-session.target
        disable_user_service htpc-session.target
        ;;
    htpc)
        enable_user_service htpc-session.target
        disable_user_service workstation-session.target
        ;;
    *)
        disable_user_service workstation-session.target
        disable_user_service htpc-session.target
        ;;
esac

# Desk chrome. The file in the dot-files tree is the source of truth.
# A missing or unknown value stays on Quickshell. The logged-in session
# is unchanged until the next role run and the next Hyprland start.
desk_shell_file="${CONFIG_SOURCE_DIR}/hypr/conf.d/shell.conf"
desk_shell="quickshell"
if [[ -f "$desk_shell_file" ]]; then
    desk_shell="$(
        grep -E '^DESK_SHELL=' "$desk_shell_file" | tail -n 1 | cut -d= -f2- | tr -d '[:space:]' || true
    )"
fi
case "$desk_shell" in
    hyprtoolkit)
        disable_user_service qs-startmenu.service
        enable_user_service hyprlauncher.service
        ;;
    *)
        enable_user_service qs-startmenu.service
        disable_user_service hyprlauncher.service
        ;;
esac
