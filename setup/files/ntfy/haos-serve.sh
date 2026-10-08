#!/bin/sh
# Run on Home Assistant OS as root. Credentials stay in
# /mnt/data/ntfy/credentials. server.yml holds bcrypt hashes only.
# A later run reuses those hashes. A fresh bcrypt salt would change
# server.yml and recreate the container on every role run.
# NTFY_ROOT overrides the data directory for the testbed.

set -eu

root="${NTFY_ROOT:-/mnt/data/ntfy}"
cred="${root}/credentials"
data="${root}/data"
server="${root}/server.yml"
image=binwiederhier/ntfy:v2.29.0

if [ ! -f "$cred" ]; then
    echo "missing ${cred}" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$cred"

if [ -z "${ha_password:-}" ] || [ -z "${workstation_password:-}" ]; then
    echo "credentials file is incomplete" >&2
    exit 1
fi

existing_hash() {
    user="$1"
    [ -f "$server" ] || return 0
    sed -n 's/.*"'"${user}"':\(\$2[^:]*\):user".*/\1/p' "$server" | head -n 1
}

ensure_image() {
    if docker image inspect "$image" >/dev/null 2>&1; then
        return 0
    fi
    docker pull "$image" >/dev/null
}

hash_pass() {
    printf '%s\n%s\n' "$1" "$1" \
        | docker run --rm -i --entrypoint ntfy "$image" user hash \
        | tr ' \t' '\n' \
        | awk '/^\$2/{print; exit}'
}

ha_hash="$(existing_hash homeassistant)"
ws_hash="$(existing_hash workstation)"
if [ -z "$ha_hash" ] || [ -z "$ws_hash" ]; then
    ensure_image
    [ -n "$ha_hash" ] || ha_hash="$(hash_pass "$ha_password")"
    [ -n "$ws_hash" ] || ws_hash="$(hash_pass "$workstation_password")"
fi
if [ -z "$ha_hash" ] || [ -z "$ws_hash" ]; then
    echo "ntfy user hash returned nothing" >&2
    exit 1
fi

mkdir -p "$data/attachments"
umask 077
tmp="$(mktemp "${root}/server.yml.XXXXXX")"
cat >"$tmp" <<EOF
base-url: "http://ward-drake.stealthdragonland.net:2586"
listen-http: ":80"
cache-file: "/var/lib/ntfy/cache.db"
cache-duration: "24h"
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
enable-login: true
auth-users:
  - "homeassistant:${ha_hash}:user"
  - "workstation:${ws_hash}:user"
auth-access:
  - "homeassistant:workstations:read-write"
  - "workstation:workstations:read-only"
EOF

changed=0
if [ ! -f "$server" ] || ! cmp -s "$tmp" "$server"; then
    mv "$tmp" "$server"
    chmod 600 "$server"
    changed=1
else
    rm -f "$tmp"
fi

state="$(docker inspect -f '{{.State.Running}}' ntfy 2>/dev/null || true)"
exists=0
running=0
if [ -n "$state" ]; then
    exists=1
fi
if [ "$state" = "true" ]; then
    running=1
fi

if [ "$changed" -eq 0 ] && [ "$running" -eq 1 ]; then
    echo "ntfy already serving this config"
    exit 0
fi

ensure_image

if [ "$exists" -eq 1 ]; then
    docker rm -f ntfy >/dev/null
fi

docker run -d \
    --name ntfy \
    --restart unless-stopped \
    -p 2586:80 \
    -v "${root}/server.yml:/etc/ntfy/server.yml:ro" \
    -v "${root}/data:/var/lib/ntfy" \
    "$image" \
    serve >/dev/null

echo "ntfy container started"
