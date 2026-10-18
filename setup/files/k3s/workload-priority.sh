#!/usr/bin/env bash
# Set k3s and BOINC slice weights for a workstation session.
#   workload-priority active   someone is at the machine
#   workload-priority idle     the session is idle
# Neither mode stops k3s or BOINC. Other roles leave the slices alone.

set -euo pipefail

role_file="${DOTFILES_ROLE_FILE:-${HOME}/.config/dot-files/role}"
mode="${1:-}"

case "$mode" in
    active | idle) ;;
    *)
        printf 'usage: %s active|idle\n' "${0##*/}" >&2
        exit 2
        ;;
esac

role=""
if [[ -f "$role_file" ]]; then
    role="$(tr -d '[:space:]' <"$role_file")"
fi
if [[ "$role" != "workstation" ]]; then
    exit 0
fi

if [[ "$mode" == "active" ]]; then
    systemctl set-property k3s.slice CPUWeight=20 IOWeight=20
    systemctl set-property boinc.slice CPUWeight=1 IOWeight=1
else
    systemctl set-property k3s.slice CPUWeight=100 IOWeight=50
    systemctl set-property boinc.slice CPUWeight=10 IOWeight=10
fi
