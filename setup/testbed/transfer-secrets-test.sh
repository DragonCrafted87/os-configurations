#!/usr/bin/env bash
# transfer-secrets.sh mkdir goes through ssh. Without -n that ssh reads
# the secrets list and the later paths, including boinc-rpc.password,
# are never copied.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${HERE}/../utility/transfer-secrets.sh"
list="${HERE}/../files/secrets.list"

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bin="${work}/bin"
mkdir -p "$bin"
export HOME="${work}/home"
export SSH_LOG="${work}/ssh.log"
export SCP_LOG="${work}/scp.log"
: >"$SSH_LOG"
: >"$SCP_LOG"

cat >"${bin}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
has_n=0
for arg in "$@"; do
    [[ "$arg" == "-n" ]] && has_n=1
done
printf '%s\n' "$*" >>"${SSH_LOG:?}"
if [[ "$has_n" -eq 0 ]]; then
    cat >/dev/null
fi
EOF
cat >"${bin}/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd=""
for arg in "$@"; do
    cmd="$arg"
done
printf '%s\n' "$cmd" >>"${SCP_LOG:?}"
EOF
chmod 0755 "${bin}/ssh" "${bin}/scp"

expected=0
while IFS= read -r rel || [[ -n "${rel:-}" ]]; do
    [[ -z "$rel" || "$rel" == \#* ]] && continue
    mkdir -p "${HOME}/$(dirname "$rel")"
    printf 'x\n' >"${HOME}/${rel}"
    expected=$((expected + 1))
done <"$list"
[[ "$expected" -ge 1 ]] || fail "secrets list is empty"

out="$(PATH="${bin}:${PATH}" bash "$script" dragon@192.0.2.20)"
printf '%s\n' "$out" | grep -F "==> copied ${expected}, skipped 0" >/dev/null \
    || fail "transfer count: ${out}"
[[ "$(wc -l <"$SCP_LOG")" -eq "$expected" ]] || fail "scp count: $(cat "$SCP_LOG")"
[[ -s "$SSH_LOG" ]] || fail "mkdir never called ssh"
while IFS= read -r line; do
    [[ "$line" == "-n "* ]] || fail "mkdir ssh read the list: ${line}"
done <"$SSH_LOG"
grep -F 'boinc-rpc.password' "$SCP_LOG" >/dev/null \
    || fail "boinc rpc password was not transferred: $(cat "$SCP_LOG")"

printf 'transfer-secrets ok\n'
