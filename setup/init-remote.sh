#!/usr/bin/env bash
# Run from a working computer. Opens one SSH master, copies secrets,
# installs git and curl, writes a passwordless sudoers drop-in for the
# remote user, generates a key on the new box, registers that key with
# the local gh session, clones both checkouts, and writes
# ~/.config/dot-files/role. It does not apply the role.
#
#   ./setup/init-remote.sh dragon@newbox.lan workstation

write_saved_role() {
    local role="$1"
    local dir="${HOME}/.config/dot-files"
    local path="${dir}/role"
    local current=""
    mkdir -p "$dir"
    if [[ -f "$path" ]]; then
        current="$(tr -d '[:space:]' <"$path")"
        if [[ "$current" == "$role" ]]; then
            return 0
        fi
    fi
    printf '%s\n' "$role" >"$path"
}

# ssh joins this into one login-shell command. An unquoted function
# is word-split there, and the parentheses are a syntax error.
remote_role_script() {
    local role="$1"
    declare -f write_saved_role
    printf 'write_saved_role %q\n' "$role"
}

# Commands run on the new machine after its SSH key can clone.
# A submodule checkout has a .git file, so this uses git -C rather than
# a test that the .git entry is a directory.
remote_checkout_script() {
    local role="$1"
    local dotfiles_url="${DOTFILES_REPO_URL:-git@github.com:DragonCrafted87/dot-files.git}"
    local setup_url="${MACHINE_SETUP_REPO_URL:-git@github.com:DragonCrafted87/os-configurations.git}"
    local homelab_url="${HOMELAB_REPO_URL:-git@github.com:DragonCrafted87/homelab.git}"
    case "$role" in
        workstation)
            cat <<EOF
if ! git -C ~/git-workspace/homelab rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mkdir -p ~/git-workspace
    git clone ${homelab_url} ~/git-workspace/homelab
    git -C ~/git-workspace/homelab submodule update --init
fi
if [[ ! -e ~/dot-files ]]; then
    ln -sfn ~/git-workspace/homelab/dot-files ~/dot-files
fi
dots="\$(realpath ~/git-workspace/homelab/dot-files)"
setup="\$(realpath ~/git-workspace/homelab/machine-setup)"
EOF
            ;;
        htpc | server)
            cat <<EOF
if ! git -C ~/dot-files rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git clone ${dotfiles_url} ~/dot-files
fi
if ! git -C ~/machine-setup rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git clone ${setup_url} ~/machine-setup
fi
dots="\$(realpath ~/dot-files)"
setup="\$(realpath ~/machine-setup)"
EOF
            ;;
        *)
            printf 'error: unknown role %s\n' "$role" >&2
            return 1
            ;;
    esac
    cat <<'EOF'
mkdir -p ~/.config/dot-files
printf 'dot-files=%s\nmachine-setup=%s\n' "$dots" "$setup" > ~/.config/dot-files/checkouts
EOF
}

# ssh forwards stdin. A while-read loop's stdin is the file it is
# reading, so a remote command without -n consumes the rest of that
# file. --stdin is the copy, which brings its own redirect. -t is the
# sudo prompt, which needs the terminal.
remote() {
    local tty=()
    local forward_stdin=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t)
                tty=(-t)
                shift
                ;;
            --stdin)
                forward_stdin=1
                shift
                ;;
            *)
                break
                ;;
        esac
    done
    local n=()
    if [[ "$forward_stdin" -eq 0 && ${#tty[@]} -eq 0 ]]; then
        n=(-n)
    fi
    ssh "${n[@]}" "${tty[@]}" \
        -o ControlMaster=auto \
        -o ControlPath="$sock" \
        -o ControlPersist=10m \
        -o ForwardX11=no \
        -o ForwardX11Trusted=no \
        -o PreferredAuthentications=password,keyboard-interactive,publickey \
        "$target" "$@"
}

copy_listed_secrets() {
    local list="$1"
    local target="$2"
    local rel src remote_dir copied=0 skipped=0
    if [[ -f "$list" ]]; then
        while IFS= read -r rel || [[ -n "${rel:-}" ]]; do
            [[ -z "$rel" || "$rel" == \#* ]] && continue
            src="${HOME}/${rel}"
            if [[ ! -e "$src" ]]; then
                printf 'skip (missing): %s\n' "$src"
                skipped=$((skipped + 1))
                continue
            fi
            remote_dir="$(dirname "$rel")"
            if [[ "$remote_dir" != "." ]]; then
                remote "mkdir -p -- $(printf '%q' "$remote_dir")"
            fi
            printf 'copy %s -> %s:%s\n' "$src" "$target" "$rel"
            remote --stdin "cat > $(printf '%q' "$rel")" <"$src"
            copied=$((copied + 1))
        done <"$list"
    fi
    printf '==> copied %s, skipped %s\n' "$copied" "$skipped"
}

# Root script for the one sudo password prompt. The drop-in has to be
# on disk before a reset: the install boot has no terminal, and the
# prune removes packages init-remote added.
remote_bootstrap_script() {
    local user="$1"
    local line dest
    if [[ ! "$user" =~ ^[A-Za-z_][-A-Za-z0-9_]*$ ]]; then
        printf 'error: remote user %s is not a sudoers name\n' "$user" >&2
        return 1
    fi
    line="${user} ALL=(ALL) NOPASSWD: ALL"
    dest="/etc/sudoers.d/${user}"
    cat <<EOF
set -euo pipefail
tmp=\$(mktemp)
printf '%s\\n' $(printf '%q' "$line") >"\$tmp"
chmod 440 "\$tmp"
visudo -cf "\$tmp"
install -m 0440 "\$tmp" $(printf '%q' "$dest")
rm -f "\$tmp"
dnf install -y git curl
EOF
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list="${here}/files/secrets.list"
target="${1:-}"
role="${2:-}"

if [[ -z "$target" || -z "$role" ]]; then
    printf 'usage: %s user@host workstation|htpc|server\n' "$0" >&2
    exit 1
fi

case "$role" in
    workstation | htpc | server) ;;
    haos)
        printf 'error: apply haos with role.sh --target %s haos\n' "$target" >&2
        exit 1
        ;;
    *)
        printf 'error: unknown role %s\n' "$role" >&2
        exit 1
        ;;
esac

if ! command -v gh >/dev/null 2>&1; then
    printf 'error: gh must be installed and logged in on this computer\n' >&2
    exit 1
fi
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    printf 'error: run gh auth login on this computer first\n' >&2
    exit 1
fi

ctl_dir="$(mktemp -d "${TMPDIR:-/tmp}/omv-init-ssh.XXXXXX")"
sock="${ctl_dir}/sock"
cleanup() {
    ssh -o ControlPath="$sock" -O exit "$target" >/dev/null 2>&1 || true
    rm -rf "$ctl_dir"
}
trap cleanup EXIT

printf '==> open ssh master to %s (one password prompt)\n' "$target"
ssh -fN \
    -o ControlMaster=yes \
    -o ControlPath="$sock" \
    -o ControlPersist=10m \
    -o ForwardX11=no \
    -o ForwardX11Trusted=no \
    "$target"
ssh -o ControlPath="$sock" -O check "$target"

printf '==> install SSH public keys on %s\n' "$target"
remote 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
install_remote_key() {
    local key="$1"
    key="$(printf '%s' "$key" | tr -d '\r')"
    [[ -z "$key" || "$key" == \#* ]] && return 0
    remote "grep -Fqx $(printf '%q' "$key") ~/.ssh/authorized_keys || printf '%s\n' $(printf '%q' "$key") >> ~/.ssh/authorized_keys"
}
if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    install_remote_key "$(cat "${HOME}/.ssh/id_ed25519.pub")"
fi
if [[ -f "${HOME}/.ssh/authorized_keys" ]]; then
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        install_remote_key "$line"
    done <"${HOME}/.ssh/authorized_keys"
fi
repo_keys="${here}/files/ssh/authorized_keys"
if [[ -f "$repo_keys" ]]; then
    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        install_remote_key "$line"
    done <"$repo_keys"
fi

printf '==> copy secrets\n'
copy_listed_secrets "$list" "$target"

remote_user="${target%%@*}"
printf '==> bootstrap git and passwordless sudo for %s\n' "$remote_user"
remote -t "sudo bash -c $(printf '%q' "$(remote_bootstrap_script "$remote_user")")"
remote 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
remote 'if [[ ! -f ~/.ssh/id_ed25519 ]]; then ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -C "$(id -un)@$(hostname -s)" -N ""; chmod 600 ~/.ssh/id_ed25519; chmod 644 ~/.ssh/id_ed25519.pub; fi'

pubkey="$(remote 'cat ~/.ssh/id_ed25519.pub')"
printf '==> public key:\n%s\n' "$pubkey"
printf '%s\n' "$pubkey" >"${ctl_dir}/newhost.pub"

if gh ssh-key list 2>/dev/null | grep -Fq "$(awk '{print $2}' "${ctl_dir}/newhost.pub")"; then
    printf '==> key already on GitHub\n'
else
    title="$(remote 'hostname -s')-$(date +%F)"
    printf '==> gh ssh-key add on this computer as %s\n' "$title"
    gh ssh-key add "${ctl_dir}/newhost.pub" --title "$title"
fi

printf '==> clone checkouts for %s\n' "$role"
remote bash -c "$(printf '%q' "$(remote_checkout_script "$role")")"

printf '==> record role %s\n' "$role"
remote bash -c "$(printf '%q' "$(remote_role_script "$role")")"
