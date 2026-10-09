#!/usr/bin/env bash
# init-remote writes the remote user's NOPASSWD drop-in in the same
# root script that installs git. The install boot has no password prompt.
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

script="$(remote_bootstrap_script dragon)"
printf '%s\n' "$script" | bash -n
printf '%s\n' "$script" | grep -F 'install -m 0440 "$tmp" /etc/sudoers.d/dragon' >/dev/null \
    || fail "drop-in path: ${script}"
printf '%s\n' "$script" | grep -F 'dnf install -y git curl' >/dev/null \
    || fail "script does not install git and curl"
drop_line="$(printf '%s\n' "$script" | grep -n 'NOPASSWD' | cut -d: -f1)"
dnf_line="$(printf '%s\n' "$script" | grep -n 'dnf install' | cut -d: -f1)"
[[ "$drop_line" -lt "$dnf_line" ]] || fail "sudoers drop-in is written after dnf"

bin="${work}/bin"
mkdir -p "$bin"
drop="${work}/drop-in"
cat >"${bin}/mktemp" <<EOF
#!/usr/bin/env bash
printf '%s\n' '${work}/fragment'
EOF
visudo_bin="$(command -v visudo)"
cat >"${bin}/visudo" <<EOF
#!/usr/bin/env bash
exec $(printf '%q' "$visudo_bin") -cf "\$2"
EOF
cat >"${bin}/install" <<EOF
#!/usr/bin/env bash
cp "\$3" '${drop}'
EOF
cat >"${bin}/dnf" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '${work}/dnf.log'
EOF
chmod 0755 "${bin}/mktemp" "${bin}/visudo" "${bin}/install" "${bin}/dnf"
PATH="${bin}:${PATH}" bash -c "$script" >/dev/null
[[ "$(cat "$drop")" == "dragon ALL=(ALL) NOPASSWD: ALL" ]] \
    || fail "drop-in contents: $(cat "$drop")"
[[ "$(cat "${work}/dnf.log")" == "install -y git curl" ]] \
    || fail "dnf args: $(cat "${work}/dnf.log")"

set +e
bad="$(remote_bootstrap_script 'dragon.wyrm' 2>&1)"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]] || fail "a dotted user was accepted"
printf '%s\n' "$bad" | grep -F 'not a sudoers name' >/dev/null \
    || fail "bad user error: ${bad}"

bin="${work}/bin"
mkdir -p "$bin"
cat >"${bin}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
has_n=0
has_t=0
cmd=""
for arg in "$@"; do
    [[ "$arg" == "-n" ]] && has_n=1
    [[ "$arg" == "-t" ]] && has_t=1
    cmd="$arg"
done
printf 'n=%s t=%s %s\n' "$has_n" "$has_t" "$cmd" >>"${SSH_LOG:?}"
EOF
chmod 0755 "${bin}/ssh"
export PATH="${bin}:${PATH}"
export SSH_LOG="${work}/ssh.log"
target="dragon@192.0.2.20"
sock="${work}/sock"
: >"$SSH_LOG"
remote -t "sudo bash -c $(printf '%q' "$(remote_bootstrap_script dragon)")"
grep -F 'n=0 t=1 sudo bash -c ' "$SSH_LOG" >/dev/null \
    || fail "bootstrap did not keep the sudo tty: $(cat "$SSH_LOG")"
grep -F 'NOPASSWD:' "$SSH_LOG" >/dev/null \
    || fail "bootstrap command omitted NOPASSWD: $(cat "$SSH_LOG")"
grep -F '/etc/sudoers.d/dragon' "$SSH_LOG" >/dev/null \
    || fail "bootstrap command omitted the drop-in path: $(cat "$SSH_LOG")"

printf 'init-remote bootstrap ok\n'
