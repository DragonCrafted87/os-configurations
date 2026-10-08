#!/usr/bin/env bash
# ssh reads stdin. The secrets loop used to lose every path after the
# first mkdir. boinc-rpc.password is one of those paths.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/../init-remote.sh"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bin="${work}/bin"
mkdir -p "$bin"
cat >"${bin}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log="${SSH_LOG:?}"
dest="${SSH_DEST:?}"
has_n=0
has_t=0
cmd=""
for arg in "$@"; do
    [[ "$arg" == "-n" ]] && has_n=1
    [[ "$arg" == "-t" ]] && has_t=1
    cmd="$arg"
done
printf 'n=%s t=%s %s\n' "$has_n" "$has_t" "$cmd" >>"$log"
if [[ "$has_n" -eq 1 ]]; then
    exit 0
fi
if [[ "$cmd" == "cat > "* ]]; then
    rel="${cmd#cat > }"
    mkdir -p "${dest}/$(dirname "$rel")"
    cat >"${dest}/${rel}"
    exit 0
fi
cat >/dev/null
EOF
chmod 0755 "${bin}/ssh"

export PATH="${bin}:${PATH}"
export SSH_LOG="${work}/ssh.log"
export SSH_DEST="${work}/remote"
export HOME="${work}/home"
target="dragon@192.0.2.20"
sock="${work}/sock"
: >"$SSH_LOG"
mkdir -p "$SSH_DEST"

list="${work}/secrets.list"
cat >"$list" <<'EOF'
# comment

.smbcredentials
.config/rclone/rclone.conf
.config/missing.conf
.config/dot-files/boinc-rpc.password
EOF
mkdir -p "${HOME}/.config/rclone" "${HOME}/.config/dot-files"
printf 'smb\n' >"${HOME}/.smbcredentials"
printf 'rclone\n' >"${HOME}/.config/rclone/rclone.conf"
printf 'rpc\n' >"${HOME}/.config/dot-files/boinc-rpc.password"

out="$(copy_listed_secrets "$list" "$target")"
printf '%s\n' "$out" | grep -F '==> copied 3, skipped 1' >/dev/null \
    || fail "copy count: ${out}"
printf '%s\n' "$out" | grep -F 'skip (missing):' >/dev/null \
    || fail "missing secret was not skipped: ${out}"
[[ "$(cat "${SSH_DEST}/.smbcredentials")" == "smb" ]] || fail "smbcredentials body"
[[ "$(cat "${SSH_DEST}/.config/rclone/rclone.conf")" == "rclone" ]] || fail "rclone body"
[[ "$(cat "${SSH_DEST}/.config/dot-files/boinc-rpc.password")" == "rpc" ]] \
    || fail "boinc rpc password was not copied"
grep -F 'n=1 t=0 mkdir -p -- .config/rclone' "$SSH_LOG" >/dev/null \
    || fail "mkdir ssh read stdin: $(cat "$SSH_LOG")"
grep -F 'n=1 t=0 mkdir -p -- .config/dot-files' "$SSH_LOG" >/dev/null \
    || fail "boinc directory ssh read stdin: $(cat "$SSH_LOG")"
grep -F 'n=0 t=0 cat > .config/dot-files/boinc-rpc.password' "$SSH_LOG" >/dev/null \
    || fail "password copy did not forward stdin: $(cat "$SSH_LOG")"

: >"$SSH_LOG"
keys="${work}/keys"
printf 'k1\nk2\nk3\n' >"$keys"
while IFS= read -r line || [[ -n "${line:-}" ]]; do
    remote "install-key ${line}"
done <"$keys"
[[ "$(grep -c '^n=1 t=0 install-key ' "$SSH_LOG")" -eq 3 ]] \
    || fail "key loop lost lines: $(cat "$SSH_LOG")"

: >"$SSH_LOG"
remote -t 'sudo dnf install -y git curl'
grep -F 'n=0 t=1 sudo dnf install -y git curl' "$SSH_LOG" >/dev/null \
    || fail "sudo prompt lost the terminal: $(cat "$SSH_LOG")"

printf 'init-remote secrets ok\n'
