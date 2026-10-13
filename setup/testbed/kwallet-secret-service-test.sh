#!/usr/bin/env bash
# configure-brave-keyring turns off KWallet's Secret Service API.
# A dry run leaves kwalletrc alone. A real run sets apiEnabled=false
# and keeps the rest of the file. A second run does not rewrite it.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repo="$(realpath "$repo")"
module="${repo}/setup/modules/desktop/configure-brave-keyring.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

home="${work}/home"
dots="${work}/dots"
mkdir -p "${dots}/bashrc.d" "${home}/.config/dot-files"
printf 'dot-files=%s\nmachine-setup=%s\n' "$(realpath "$dots")" "$repo" \
    >"${home}/.config/dot-files/checkouts"
export DOTFILES_HOME="$home"
export DOTFILES_USER="$(id -un)"
export HOME="$home"
export DOTFILES_TEST_SOURCE=1
unset DOTFILES_LIB_LOADED
unset DOTFILES_DRY_RUN

# shellcheck disable=SC1090
. "$module"

file="${home}/.config/kwalletrc"
mkdir -p "${home}/.config"
cat >"$file" <<'EOF'
[Wallet]
Enabled=true
Idle Timeout=10

[org.freedesktop.secrets]
apiEnabled=true
EOF
before="$(cat "$file")"

DOTFILES_DRY_RUN=1
disable_kwallet_secret_service
[[ "$(cat "$file")" == "$before" ]] || fail "dry-run changed kwalletrc"

DOTFILES_DRY_RUN=0
disable_kwallet_secret_service
grep -F "Enabled=true" "$file" >/dev/null || fail "wallet Enabled was dropped"
grep -F "Idle Timeout=10" "$file" >/dev/null || fail "wallet Idle Timeout was dropped"
grep -F "apiEnabled=false" "$file" >/dev/null || fail "apiEnabled was not set false"
[[ "$(grep -c '^apiEnabled=' "$file")" == "1" ]] || fail "apiEnabled appears more than once"
written="$(cat "$file")"
disable_kwallet_secret_service
[[ "$(cat "$file")" == "$written" ]] || fail "second run rewrote kwalletrc"

printf '[Wallet]\nEnabled=true\n\n[org.freedesktop.secrets]\napiEnabled = true\n' >"$file"
disable_kwallet_secret_service
grep -F "apiEnabled=false" "$file" >/dev/null || fail "spaced apiEnabled was left true"
[[ "$(grep -c 'apiEnabled' "$file")" == "1" ]] || fail "spaced apiEnabled was duplicated"

rm -f "$file"
disable_kwallet_secret_service
[[ -f "$file" ]] || fail "missing kwalletrc was not created"
grep -F "[org.freedesktop.secrets]" "$file" >/dev/null || fail "new kwalletrc has no secrets section"
grep -F "apiEnabled=false" "$file" >/dev/null || fail "new kwalletrc left the default enabled"

printf '[Wallet]\nEnabled=true\n' >"$file"
disable_kwallet_secret_service
grep -F "Enabled=true" "$file" >/dev/null || fail "section append dropped the wallet"
grep -F "apiEnabled=false" "$file" >/dev/null || fail "section append did not add apiEnabled"
