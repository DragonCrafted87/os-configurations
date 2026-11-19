#!/bin/bash
# Build Rust against the installed homelab LLVM and install it under a prefix.
# The tree stays outside rpmbuild so a second run reuses the stage 2 compiler.
set -euo pipefail

version=""
prefix="/usr/local"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            version="$2"
            shift 2
            ;;
        --prefix)
            prefix="$2"
            shift 2
            ;;
        *)
            printf 'unknown argument %s\n' "$1" >&2
            exit 1
            ;;
    esac
done
[[ -n "$version" ]] || {
    printf 'pass --version\n' >&2
    exit 1
}

root="${HOMELAB_RUST_BUILD:-${HOME}/builds/homelab-rust/${version}}"
src="${HOMELAB_RUST_SRC:-${HOME}/builds/rust-stable}"
stage2="${src}/build/x86_64-unknown-linux-gnu/stage2/bin/rustc"
install_prefix="${root}/prefix"
mkdir -p "$root"

if [[ ! -x "$stage2" ]] || ! "$stage2" --version | grep -q " ${version} "; then
    [[ -x /usr/local/bin/llvm-config ]] || {
        printf 'homelab llvm-config is not installed\n' >&2
        exit 1
    }
    [[ -d "$src" ]] || {
        git clone --depth 1 --branch "${version}" https://github.com/rust-lang/rust.git "$src" \
            || git clone --depth 1 --branch stable https://github.com/rust-lang/rust.git "$src"
    }
    cat >"${src}/bootstrap.toml" <<EOF
change-id = "ignore"
profile = "dist"

[llvm]
download-ci-llvm = false
link-shared = true

[build]
extended = true
tools = ["cargo", "clippy", "rustfmt", "rust-analyzer"]
docs = false
compiler-docs = false
cargo-native-static = false

[rust]
channel = "stable"
lld = false
llvm-tools = false

[install]
prefix = "${install_prefix}"
sysconfdir = "etc"

[target.x86_64-unknown-linux-gnu]
cc = "/usr/local/bin/clang"
cxx = "/usr/local/bin/clang++"
linker = "/usr/local/bin/clang"
llvm-config = "/usr/local/bin/llvm-config"
EOF
    (
        cd "$src"
        ./x.py build --stage 2 library compiler cargo rustfmt clippy rust-analyzer
    )
fi

mkdir -p "${install_prefix}/etc"
(
    cd "$src"
    ./x.py install --stage 2 \
        --set "install.prefix=${install_prefix}" \
        --set "install.sysconfdir=etc" \
        library compiler cargo rustfmt clippy rust-analyzer
)
[[ -x "${install_prefix}/bin/rustc" ]] || {
    printf 'install missing %s\n' "${install_prefix}/bin/rustc" >&2
    exit 1
}
