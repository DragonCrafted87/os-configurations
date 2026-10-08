#!/usr/bin/env bash
# haos-serve.sh reuses bcrypt hashes. A new salt on every run would
# rewrite server.yml and recreate the container. docker is a stub.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${repo}/setup/files/ntfy/haos-serve.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "${work}/bin" "${work}/root"
cat >"${work}/bin/docker" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$DOCKER_LOG"
cmd="$1"
shift
case "$cmd" in
    image)
        if [ "${DOCKER_HAVE_IMAGE}" = "1" ] || [ -f "${DOCKER_IMAGE_STATE}" ]; then
            exit 0
        fi
        exit 1
        ;;
    pull)
        : >"${DOCKER_IMAGE_STATE}"
        ;;
    inspect)
        if [ "${1:-}" = "-f" ]; then
            [ "${DOCKER_EXISTS}" = "1" ]
            printf '%s\n' "${DOCKER_RUNNING}"
            exit 0
        fi
        [ "${DOCKER_EXISTS}" = "1" ]
        ;;
    rm) ;;
    run)
        if printf '%s' "$*" | grep -q 'user hash'; then
            [ "${DOCKER_ALLOW_HASH}" = "1" ]
            cat >/dev/null
            printf '%s\n' 'password: confirm: $2a$10$abcdefghijklmnopqrstuu0123456789ABCDEFGHIJKLMNOPQR'
            exit 0
        fi
        ;;
    *)
        printf 'unexpected docker %s\n' "$cmd" >&2
        exit 1
        ;;
esac
EOF
chmod 0755 "${work}/bin/docker"

umask 077
printf 'ha_password=%s\nworkstation_password=%s\n' \
    'aaaaaaaaaaaaaaaaaaaaaaaa' 'bbbbbbbbbbbbbbbbbbbbbbbb' \
    >"${work}/root/credentials"

export PATH="${work}/bin:${PATH}"
export NTFY_ROOT="${work}/root"
export DOCKER_HAVE_IMAGE=0
export DOCKER_EXISTS=0
export DOCKER_RUNNING=false
export DOCKER_ALLOW_HASH=1
export DOCKER_IMAGE_STATE="${work}/image-present"
hash='$2a$10$abcdefghijklmnopqrstuu0123456789ABCDEFGHIJKLMNOPQR'

run_serve() {
    local name="$1"
    export DOCKER_LOG="${work}/${name}.log"
    : >"$DOCKER_LOG"
    NTFY_ROOT="$NTFY_ROOT" "$script" >"${work}/${name}.out"
}

count() {
    local file="$1"
    local pattern="$2"
    grep -c -e "$pattern" "$file" || true
}

run_serve fresh
grep -qx 'ntfy container started' "${work}/fresh.out"
[[ "$(count "${work}/fresh.log" 'user hash')" == "2" ]]
[[ "$(count "${work}/fresh.log" '^pull ')" == "1" ]]
[[ "$(count "${work}/fresh.log" '^run -d ')" == "1" ]]
grep -q "${work}/root/server.yml:/etc/ntfy/server.yml:ro" "${work}/fresh.log"
grep -q "${work}/root/data:/var/lib/ntfy" "${work}/fresh.log"
grep -F "homeassistant:${hash}:user" "${work}/root/server.yml" >/dev/null
grep -F "workstation:${hash}:user" "${work}/root/server.yml" >/dev/null
[[ "$(stat -c '%a' "${work}/root/server.yml")" == "600" ]]
! grep -q 'aaaaaaaaaaaaaaaaaaaaaaaa' "${work}/root/server.yml"
cp "${work}/root/server.yml" "${work}/server.fresh"

export DOCKER_HAVE_IMAGE=1 DOCKER_EXISTS=1 DOCKER_RUNNING=true DOCKER_ALLOW_HASH=0
run_serve steady
grep -qx 'ntfy already serving this config' "${work}/steady.out"
cmp -s "${work}/server.fresh" "${work}/root/server.yml"
[[ "$(count "${work}/steady.log" 'user hash')" == "0" ]]
[[ "$(count "${work}/steady.log" '^pull ')" == "0" ]]
[[ "$(count "${work}/steady.log" '^run -d ')" == "0" ]]
[[ "$(count "${work}/steady.log" '^rm ')" == "0" ]]

sed -i 's|ward-drake.stealthdragonland.net:2586|example.invalid:1|' \
    "${work}/root/server.yml"
export DOCKER_RUNNING=true
run_serve drift
grep -qx 'ntfy container started' "${work}/drift.out"
grep -q 'ward-drake.stealthdragonland.net:2586' "${work}/root/server.yml"
grep -F "homeassistant:${hash}:user" "${work}/root/server.yml" >/dev/null
[[ "$(count "${work}/drift.log" 'user hash')" == "0" ]]
[[ "$(count "${work}/drift.log" '^rm ')" == "1" ]]
[[ "$(count "${work}/drift.log" '^run -d ')" == "1" ]]

export DOCKER_RUNNING=false
run_serve stopped
grep -qx 'ntfy container started' "${work}/stopped.out"
[[ "$(count "${work}/stopped.log" 'user hash')" == "0" ]]
[[ "$(count "${work}/stopped.log" '^rm ')" == "1" ]]
[[ "$(count "${work}/stopped.log" '^run -d ')" == "1" ]]

printf 'ntfy haos-serve hash reuse ok\n'
