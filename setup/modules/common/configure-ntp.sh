#!/usr/bin/env bash
# Point the NTP client at mist-dragon. OpenMandriva's compiled
# timesyncd fallback lists _gateway and then the public pool, and the
# running client stays on the pool. chrony on a Hyper-V guest ships
# the same pool. 192.168.0.1 is mist-dragon's LAN address.

set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/lib.sh"

require_user
ensure_timesyncd_ntp
ensure_chrony_ntp
