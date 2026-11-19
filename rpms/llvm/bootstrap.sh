#!/usr/bin/env bash
# Stage 3 is the compiler that gets installed. Stage 1 is built by the
# host compiler. An instrumented Clang then compiles Clang to produce the
# IR profile. Stage 2 and stage 3 both apply that profile with ThinLTO.
# Stage 3 is built by stage 2, so the installed compiler was built by Clang.
# Shipping waits until stage 2 and stage 3 clang and lld match, and until
# check-clang and check-llvm pass on stage 3.
set -euo pipefail

tag=""
prefix="/usr/local"
march="znver1"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --tag)
            tag="$2"
            shift 2
            ;;
        --prefix)
            prefix="$2"
            shift 2
            ;;
        --march)
            march="$2"
            shift 2
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

[[ -n "$tag" ]] || {
    printf 'missing --tag\n' >&2
    exit 2
}
version="${tag#llvmorg-}"
root="${HOMELAB_LLVM_BUILD:-${HOME}/builds/homelab-llvm/${version}}"
src="${root}/src/llvm-project-${version}.src"
url="https://github.com/llvm/llvm-project/releases/download/${tag}/llvm-project-${version}.src.tar.xz"
log="${root}/bootstrap.log"
compile_jobs="${HOMELAB_LLVM_JOBS:-16}"
link_jobs="${HOMELAB_LLVM_LINK_JOBS:-1}"

mkdir -p "$root"
printf '%s\n' "$$" >"${root}/bootstrap.pid"
exec 9>"${root}/bootstrap.lock"
flock -n 9 || {
    printf 'bootstrap already running for %s\n' "$root" >&2
    exit 1
}

if [[ -z "${HOMELAB_LLVM_LOGGING:-}" ]]; then
    export HOMELAB_LLVM_LOGGING=1
    exec > >(tee -a "$log") 2>&1
fi

stage_start() {
    printf 'STAGE start %s\n' "$1"
}

stage_done() {
    mkdir -p "${root}/stamps"
    date -Is >"${root}/stamps/$1"
    printf 'STAGE done %s\n' "$1"
}

have_stage() {
    [[ -f "${root}/stamps/$1" ]]
}

map_flags() {
    local builddir="$1"
    printf '%s\n' "-march=${march} -ffile-prefix-map=${src}=/llvm-src -ffile-prefix-map=${builddir}=/llvm-stage -fdebug-prefix-map=${src}=/llvm-src -fdebug-prefix-map=${builddir}=/llvm-stage"
}

# Stage 1 Clang's default triple does not match OpenMandriva's GCC
# directory, so it never searches /usr/include/c++. The config file is
# what the installed compiler loads. The same flag is passed while
# building so CMake's libstdc++ probe sees the headers too.
gcc_triple="--gcc-triple=x86_64-openmandriva-linux-gnu"

write_gcc_cfg() {
    local bindir="$1"
    mkdir -p "$bindir"
    # These are the installed compiler's defaults. Compiling them into
    # the driver makes z/OS unit tests abort and changes bare-metal
    # driver output, so the test run sets CLANG_NO_DEFAULT_CONFIG.
    printf '%s\n' \
        "$gcc_triple" \
        "-stdlib=libstdc++" \
        "-rtlib=libgcc" \
        "-unwindlib=libgcc" \
        "-fuse-ld=lld" \
        >"${bindir}/clang.cfg"
    cp "${bindir}/clang.cfg" "${bindir}/clang++.cfg"
}

configure_llvm() {
    local builddir="$1"
    local cc="$2"
    local cxx="$3"
    local projects="$4"
    local runtimes="$5"
    shift 5
    local flags
    local -a archive_tools=()
    flags="$(map_flags "$builddir")"
    if [[ "$cc" != /usr/bin/gcc && "$cc" != gcc ]]; then
        flags="${flags} ${gcc_triple}"
        # ThinLTO objects are bitcode. Distro llvm-ar 19 cannot read
        # LLVM 23 bitcode. Prefer the tools beside this compiler, and
        # fall back to stage 1 when that compiler did not build them.
        local ar_dir="${cc%/*}"
        if [[ ! -x "${ar_dir}/llvm-ar" || ! -x "${ar_dir}/llvm-ranlib" || ! -x "${ar_dir}/llvm-nm" ]]; then
            ar_dir="${stage1}/bin"
        fi
        if [[ ! -x "${ar_dir}/llvm-ar" || ! -x "${ar_dir}/llvm-ranlib" || ! -x "${ar_dir}/llvm-nm" ]]; then
            printf 'compiler %s needs llvm-ar, llvm-ranlib, and llvm-nm\n' "$cc" >&2
            exit 1
        fi
        archive_tools=(
            -DCMAKE_AR="${ar_dir}/llvm-ar"
            -DCMAKE_RANLIB="${ar_dir}/llvm-ranlib"
            -DCMAKE_NM="${ar_dir}/llvm-nm"
        )
    fi
    cmake -G Ninja -S "${src}/llvm" -B "$builddir" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$cc" \
        -DCMAKE_CXX_COMPILER="$cxx" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_INSTALL_LIBDIR=lib64 \
        -DCMAKE_C_FLAGS="$flags" \
        -DCMAKE_CXX_FLAGS="$flags" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DLLVM_APPEND_VC_REV=OFF \
        -DLLVM_ENABLE_ASSERTIONS=OFF \
        -DLLVM_TARGETS_TO_BUILD=X86 \
        -DLLVM_ENABLE_PROJECTS="$projects" \
        -DLLVM_ENABLE_RUNTIMES="$runtimes" \
        -DLLVM_ENABLE_BINDINGS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_ENABLE_Z3_SOLVER=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF \
        -DLLVM_PARALLEL_LINK_JOBS="$link_jobs" \
        "${archive_tools[@]}" \
        "$@"
}

build_targets() {
    local builddir="$1"
    shift
    local args=()
    local target
    for target in "$@"; do
        args+=(--target "$target")
    done
    cmake --build "$builddir" --parallel "$compile_jobs" "${args[@]}"
}

if ! have_stage source; then
    stage_start source
    tarball="${root}/llvm-project-${version}.src.tar.xz"
    if [[ ! -f "$tarball" ]]; then
        curl -fL --retry 3 -o "$tarball" "$url"
    fi
    if [[ ! -f "${src}/llvm/CMakeLists.txt" ]]; then
        mkdir -p "${root}/src"
        tar -xJf "$tarball" -C "${root}/src"
    fi
    [[ -f "${src}/llvm/CMakeLists.txt" ]] || {
        printf 'source tree missing %s\n' "${src}/llvm/CMakeLists.txt" >&2
        exit 1
    }
    stage_done source
fi

stage1="${root}/stage1"
write_gcc_cfg "${stage1}/bin"
if ! have_stage stage1; then
    stage_start stage1
    configure_llvm "$stage1" /usr/bin/gcc /usr/bin/g++ "clang;lld" "compiler-rt" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF
    build_targets "$stage1" clang lld llvm-profdata llvm-ar llvm-ranlib llvm-nm compiler-rt
    stage_done stage1
fi

# The instrumented link needs stage 1's profile runtime, and later
# stages need stage 1's llvm-ar. A resumed stage 1 stamp may predate both.
profile_lib_present() {
    local path
    for path in "${stage1}"/lib/clang/*/lib/*/libclang_rt.profile.a; do
        [[ -f "$path" ]] && return 0
    done
    return 1
}
if ! profile_lib_present || [[ ! -x "${stage1}/bin/llvm-ar" || ! -x "${stage1}/bin/llvm-ranlib" || ! -x "${stage1}/bin/llvm-nm" ]]; then
    stage_start stage1-profile
    build_targets "$stage1" llvm-ar llvm-ranlib llvm-nm compiler-rt
    profile_lib_present || {
        printf 'stage1 did not produce libclang_rt.profile.a\n' >&2
        exit 1
    }
    stage_done stage1-profile
fi

instrumented="${root}/stage2-instrumented"
if ! have_stage stage2-instrumented; then
    stage_start stage2-instrumented
    PATH="${stage1}/bin:${PATH}" \
        configure_llvm "$instrumented" "${stage1}/bin/clang" "${stage1}/bin/clang++" \
        "clang;lld" "compiler-rt" \
        -DLLVM_BUILD_INSTRUMENTED=IR \
        -DLLVM_ENABLE_LTO=Thin \
        -DLLVM_ENABLE_LLD=ON \
        -DCLANG_DEFAULT_LINKER=lld \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF
    PATH="${stage1}/bin:${PATH}" build_targets "$instrumented" clang lld
    write_gcc_cfg "${instrumented}/bin"
    stage_done stage2-instrumented
fi
write_gcc_cfg "${instrumented}/bin"

profdata="${root}/clang.profdata"
if ! have_stage profdata; then
    stage_start profdata
    train="${root}/train"
    rm -rf "${root}/prof" "$train"
    mkdir -p "${root}/prof"
    PATH="${instrumented}/bin:${stage1}/bin:${PATH}" \
        LLVM_PROFILE_FILE="${root}/prof/%p.profraw" \
        configure_llvm "$train" "${instrumented}/bin/clang" "${instrumented}/bin/clang++" \
        "clang" "" \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF \
        -DLLVM_BUILD_TOOLS=OFF
    PATH="${instrumented}/bin:${stage1}/bin:${PATH}" \
        LLVM_PROFILE_FILE="${root}/prof/%p.profraw" \
        build_targets "$train" clang
    mapfile -d '' profraws < <(find "${root}/prof" -name '*.profraw' -print0)
    cleaned=()
    for one in "${profraws[@]}"; do
        [[ -n "$one" ]] && cleaned+=("$one")
    done
    profraws=("${cleaned[@]}")
    [[ "${#profraws[@]}" -gt 0 ]] || {
        printf 'training produced no profraw files\n' >&2
        exit 1
    }
    merged="${root}/prof-merged"
    rm -rf "$merged"
    mkdir -p "$merged"
    batch=300
    index=0
    part=0
    while [[ "$index" -lt "${#profraws[@]}" ]]; do
        "${stage1}/bin/llvm-profdata" merge -sparse \
            -output="${merged}/part-${part}.profdata" \
            "${profraws[@]:index:batch}"
        index=$((index + batch))
        part=$((part + 1))
    done
    "${stage1}/bin/llvm-profdata" merge -sparse -output="$profdata" "${merged}"/*.profdata
    stage_done profdata
fi

final_projects="clang;clang-tools-extra;lld"
final_runtimes="compiler-rt;libcxx;libcxxabi;libunwind"
final_extra=(
    -DLLVM_ENABLE_LTO=Thin
    -DLLVM_ENABLE_LLD=ON
    -DLLVM_ENABLE_FATLTO=OFF
    -DCLANG_DEFAULT_LINKER=
    -DCLANG_DEFAULT_CXX_STDLIB=
    -DCLANG_DEFAULT_RTLIB=
    -DLLVM_PROFDATA_FILE="$profdata"
    -DLLVM_INCLUDE_TESTS=ON
    -DCLANG_INCLUDE_TESTS=ON
    -DRUNTIMES_CMAKE_ARGS=-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON
    -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON
)
toolchain_bins=(
    llvm-ar llvm-cov llvm-cxxfilt llvm-dwp llvm-nm llvm-objcopy llvm-objdump
    llvm-profdata llvm-ranlib llvm-readobj llvm-size llvm-strings llvm-strip
    llvm-symbolizer
)

stage2="${root}/stage2"
if ! have_stage stage2; then
    stage_start stage2
    PATH="${stage1}/bin:${PATH}" \
        configure_llvm "$stage2" "${stage1}/bin/clang" "${stage1}/bin/clang++" \
        "$final_projects" "$final_runtimes" "${final_extra[@]}"
    PATH="${stage1}/bin:${PATH}" \
        build_targets "$stage2" clang lld "${toolchain_bins[@]}"
    # The runtime build invokes this clang before ninja returns, so the
    # OpenMandriva config has to exist first. The runtime project sets
    # LLVM_USE_LINKER itself, so RUNTIMES_CMAKE_ARGS must not also set
    # LLVM_ENABLE_LLD.
    write_gcc_cfg "${stage2}/bin"
    PATH="${stage1}/bin:${PATH}" \
        build_targets "$stage2" clang-tidy clangd clang-format runtimes
    stage_done stage2
fi
write_gcc_cfg "${stage2}/bin"

stage3="${root}/stage3"
if ! have_stage stage3; then
    stage_start stage3
    PATH="${stage2}/bin:${PATH}" \
        configure_llvm "$stage3" "${stage2}/bin/clang" "${stage2}/bin/clang++" \
        "$final_projects" "$final_runtimes" "${final_extra[@]}"
    PATH="${stage2}/bin:${PATH}" \
        build_targets "$stage3" clang lld "${toolchain_bins[@]}"
    write_gcc_cfg "${stage3}/bin"
    PATH="${stage2}/bin:${PATH}" \
        build_targets "$stage3" clang-tidy clangd clang-format runtimes
    stage_done stage3
fi
write_gcc_cfg "${stage3}/bin"

compare_one() {
    local rel="$1"
    local left="${stage2}/${rel}"
    local right="${stage3}/${rel}"
    if [[ ! -e "$left" && ! -e "$right" ]]; then
        return 0
    fi
    if [[ ! -e "$left" || ! -e "$right" ]]; then
        printf 'compare missing %s\n' "$rel" >&2
        return 1
    fi
    if cmp -s "$left" "$right"; then
        printf 'compare match %s\n' "$rel"
        return 0
    fi
    printf 'compare differ %s\n' "$rel" >&2
    return 1
}

if ! have_stage compare; then
    stage_start compare
    compare_ok=0
    compare_one "bin/clang" || compare_ok=1
    compare_one "bin/clang++" || compare_ok=1
    compare_one "bin/clang-${version%%.*}" || compare_ok=1
    compare_one "bin/lld" || compare_ok=1
    compare_one "bin/ld.lld" || compare_ok=1
    [[ "$compare_ok" -eq 0 ]] || exit 1
    stage_done compare
fi

if ! have_stage tests; then
    stage_start tests
    CLANG_NO_DEFAULT_CONFIG=1 \
        PATH="${stage3}/bin:${PATH}" \
        build_targets "$stage3" check-clang check-llvm
    stage_done tests
fi

destdir="${root}/destdir"
if ! have_stage install; then
    stage_start install
    rm -rf "$destdir"
    mkdir -p "$destdir"
    DESTDIR="$destdir" cmake --install "$stage3"
    write_gcc_cfg "${destdir}${prefix}/bin"
    [[ -x "${destdir}${prefix}/bin/clang" ]] || {
        printf 'install missing %s\n' "${destdir}${prefix}/bin/clang" >&2
        exit 1
    }
    stage_done install
fi

printf 'STAGE done bootstrap\n'
