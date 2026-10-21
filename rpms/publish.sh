#!/usr/bin/env bash
# Create the single homelab Pulp RPM repository and publish rpms/out.
# Both arches go into this one repository. Run it when Pulp answers.
# A role run does not call this script.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
name="${PULP_RPM_REPO:-homelab}"
base="${PULP_API:-https://pulp.stealthdragonland.net}"

if ! command -v pulp >/dev/null 2>&1; then
    printf 'pulp is not on PATH\n' >&2
    exit 1
fi

pulp --base-url "$base" rpm repository create --name "$name" || true

find "${root}/out" -type f -name '*.rpm' -print0 |
while IFS= read -r -d '' rpm; do
    pulp --base-url "$base" rpm content upload --repository "$name" --file "$rpm"
done

publication="$(pulp --base-url "$base" rpm publication create --repository "$name" | awk '/^href:/ { print $2; exit }')"
[[ -n "$publication" ]] || {
    printf 'Pulp did not return a publication href\n' >&2
    exit 1
}
pulp --base-url "$base" rpm distribution create \
    --name "$name" \
    --base-path "$name" \
    --publication "$publication" ||
pulp --base-url "$base" rpm distribution update \
    --name "$name" \
    --publication "$publication"
