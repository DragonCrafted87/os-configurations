#!/usr/bin/env bash
# The htpc role installs the Bluetooth pad and not the wireless dongle.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
roles="${HERE}/../roles.conf"
bluetooth="${HERE}/../modules/network/configure-bluetooth-login.sh"
pad="${HERE}/../modules/desktop/configure-xbox-bluetooth.sh"
dongle="${HERE}/../modules/desktop/configure-xbox-controller.sh"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

section() {
    local name="$1"
    awk -v section="$name" '
        $0 == "[" section "]" { on = 1; next }
        $0 ~ /^\[/ { on = 0 }
        on && $0 !~ /^#/ && $0 !~ /^$/ { print }
    ' "$roles"
}

htpc="$(section htpc)"
gaming="$(section "subrole.gaming")"

grep -qx configure-bluetooth-login <<<"$htpc" || fail "htpc does not run configure-bluetooth-login"
grep -qx configure-xbox-bluetooth <<<"$htpc" || fail "htpc does not run configure-xbox-bluetooth"
grep -qx configure-xbox-controller <<<"$htpc" && fail "htpc runs the dongle module"
grep -qx configure-xbox-controller <<<"$gaming" || fail "gaming does not run configure-xbox-controller"

grep -q 'set_ini_key "$main_conf" General Privacy device' "$bluetooth" \
    || fail "bluetooth login does not set Privacy=device"
grep -q 'configure-xbox-bluetooth.sh' "$dongle" || fail "dongle module does not call the bluetooth module"
grep -q 'modprobe hid-xpadneo' "$pad" || fail "bluetooth module does not load hid-xpadneo"
grep -q 'install.sh --release' "$pad" && fail "bluetooth module installs the dongle driver"

printf '%s\n' "htpc xbox bluetooth ok"
