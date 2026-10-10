#!/usr/bin/env bash
# ly-blank-displays saves backlight state once, then restores it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
script="${HERE}/../files/ly-blank-displays.sh"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

sys="${work}/sys"
bl="${sys}/class/backlight/amdgpu_bl0"
dpms="${sys}/class/drm/card0-eDP-1/dpms"
mkdir -p "$bl" "$(dirname "$dpms")"
printf '32\n' >"${bl}/brightness"
printf '0\n' >"${bl}/bl_power"
printf 'On\n' >"$dpms"
chmod 444 "$dpms"

export LY_BLANK_SYS="$sys"
export LY_BLANK_STATE="${work}/state"

"$script" unblank
[[ ! -e "${work}/state/blanked" ]] || fail "unblank created a blanked flag"

"$script" blank
[[ "$(cat "${bl}/brightness")" == 0 ]] || fail "blank left brightness $(cat "${bl}/brightness")"
[[ "$(cat "${bl}/bl_power")" == 4 ]] || fail "blank left bl_power $(cat "${bl}/bl_power")"
[[ -f "${work}/state/blanked" ]] || fail "blank did not record state"
grep -qx 'amdgpu_bl0 32 0' "${work}/state/saved" || fail "saved state is wrong: $(cat "${work}/state/saved")"
[[ "$(cat "$dpms")" == On ]] || fail "read-only dpms node changed"

printf '1\n' >"${bl}/brightness"
"$script" blank
grep -qx 'amdgpu_bl0 32 0' "${work}/state/saved" || fail "second blank overwrote the saved brightness"
[[ "$(cat "${bl}/brightness")" == 1 ]] || fail "second blank wrote the backlight again"

"$script" unblank
[[ "$(cat "${bl}/brightness")" == 32 ]] || fail "unblank restored $(cat "${bl}/brightness")"
[[ "$(cat "${bl}/bl_power")" == 0 ]] || fail "unblank restored bl_power $(cat "${bl}/bl_power")"
[[ ! -e "${work}/state/blanked" ]] || fail "unblank left the blanked flag"
[[ ! -e "${work}/state/saved" ]] || fail "unblank left the saved state"

"$script" unblank

# A connected connector that stays On is not a finished blank.
# set_dpms does not run unless LY_BLANK_SYS is /sys.
live="${work}/live"
live_bl="${live}/class/backlight/amdgpu_bl0"
live_dpms="${live}/class/drm/card0-eDP-1/dpms"
live_state="${work}/live-state"
mkdir -p "$live_bl" "$(dirname "$live_dpms")" "$live_state"
printf '32\n' >"${live_bl}/brightness"
printf '0\n' >"${live_bl}/bl_power"
printf 'connected\n' >"${live}/class/drm/card0-eDP-1/status"
printf 'On\n' >"$live_dpms"
chmod 444 "$live_dpms"
: >"${live_state}/blanked"
printf 'stale\n' >"${live_state}/method"
export LY_BLANK_SYS="$live"
export LY_BLANK_STATE="$live_state"

"$script" blank
[[ ! -e "${live_state}/blanked" ]] || fail "blank recorded success while dpms stayed On"
[[ ! -e "${live_state}/method" ]] || fail "stale method survived a connector that stayed On"
[[ "$(cat "$live_dpms")" == On ]] || fail "fallback wrote the read-only dpms node"

printf '%s\n' "ly-blank-displays-test: ok"
