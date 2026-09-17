#!/usr/bin/env bash
# Build LLVM/clang for one cross target. Driven entirely by env vars so it runs
# identically in CI and in `docker run`.
#
#   PLATFORM    bionic | linux | bsd | windows | macos
#   TARGET      target triple, e.g.
#                 aarch64-linux-android        (bionic)
#                 x86_64-linux-gnu / -musl     (linux)
#                 aarch64-freebsd-none         (bsd)
#                 x86_64-w64-mingw32           (windows)
#                 arm64-apple-darwin           (macos)
#   PROJECTS    LLVM_ENABLE_PROJECTS (default: bolt;clang;clang-tools-extra;lld;polly)
#   ROOTDIR     work dir (default: cwd)
#   ANDROID_API bionic API level (default: 24, riscv64 forced to 35 if lower)
#   EXTRA_CMAKE_FLAGS  optional extra -D flags for the zstd + LLVM configures
#   LLVM_BUILD_ID      build id for the vendor string (CI passes the Actions run id)
#   LLVM_LTO           LLVM_ENABLE_LTO (default: Thin); forced off on macos
#   LLVM_PROFDATA_FILE optional PGO profile
#   TENSORFLOW_AOT_PATH  tensorflow pip dir; with MLGO_DIR it enables MLGO for
#                      targets whose triple the AOT compiler accepts
#   CLANG_VENDOR       overrides the composed vendor string outright
#   ZLIB_VERSION / ZSTD_VERSION  bundled dependency versions
#   BUILD_PROFDATA     1 = generate the PGO profile for this llvm revision and
#                      exit, instead of cross building. Needs only NDK_VERSION
#                      (via fetch-source.sh); PLATFORM/TARGET are unused.
#
# Reads $ROOTDIR/.build-env (written by fetch-source.sh) for SRC, NDK_DIR,
# LLVM_VERSION, LLVM_REV, LLVM_TARGETS, the CLANG_RELEASE the vendor string is
# "based on", and the resolved LLVM_PROFDATA_FILE / MLGO_DIR.
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
PROJECTS="${PROJECTS:-bolt;clang;clang-tools-extra;lld;polly}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PATCHES_DIR="${PATCHES_DIR:-$SCRIPT_DIR/../patches}"

# shellcheck disable=SC1091
[ -f "$ROOTDIR/.build-env" ] && . "$ROOTDIR/.build-env"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- PGO profile generation -------------------------------------------------
# BUILD_PROFDATA=1 makes this a native instrumented build and training run
# instead of a cross build, leaving $ROOTDIR/<llvm rev>.profdata.xz behind.
#
# No stage1: this instruments a compiler to count how often clang runs each
# function, it doesn't bootstrap one. A frontend profile keys on function name
# and CFG hash, so one profile per tree serves every target built from it.
if [ "${BUILD_PROFDATA:-0}" = 1 ]; then
  : "${LLVM_REV:?set LLVM_REV (run fetch-source.sh first)}"
  PROF_BUILD="${PROF_BUILD:-$ROOTDIR/instr}"
  SRC="${SRC:-$ROOTDIR/llvm-project}"
  # The NDK's clang, not the image's: RawInstrProfReader wants an exact match
  # between the runtime that writes the raw profile and this tree's
  # llvm-profdata. The NDK is the same LLVM release as the tree; raw versions run
  # 8 for r25/r26, 9 for r27, 10 from r28 on, and the image clang only fits 10.
  _ndk_clang="${NDK_DIR:-/nonexistent}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
  if [ -z "${PROF_CC:-}" ] && [ -x "$_ndk_clang" ]; then
    PROF_CC="$_ndk_clang"
  fi
  PROF_CC="${PROF_CC:-clang}"
  # handles both spellings: .../bin/clang -> clang++, and clang-20 -> clang++-20
  PROF_CXX="${PROF_CXX:-$(echo "$PROF_CC" | sed -E 's@clang(-[0-9]+)?$@clang++\1@')}"
  log "Instrumented build for $LLVM_REV (LLVM ${LLVM_VERSION:-?}) with $PROF_CC"
  # Only r26/r27 ship a host libclang_rt.profile; elsewhere clang links against a
  # path the NDK doesn't have. Build it from this tree rather than borrow one, so
  # the raw version still matches llvm-profdata, and ask clang for the path --
  # the resource dir moved from lib/linux to lib/<triple> around r29.
  _rt="$("$PROF_CC" -fprofile-instr-generate -x c /dev/null -o /dev/null -### 2>&1 \
         | tr ' ' '\n' | tr -d '"' | grep -m1 'libclang_rt\.profile' || true)"
  if [ -n "$_rt" ] && [ ! -f "$_rt" ]; then
    log "NDK has no host profile runtime, building it -> $_rt"
    cmake -S "$SRC/llvm" -B "$ROOTDIR/crt" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$PROF_CC" -DCMAKE_CXX_COMPILER="$PROF_CXX" \
      -DLLVM_ENABLE_PROJECTS=compiler-rt \
      -DLLVM_TARGETS_TO_BUILD=X86 \
      -DCOMPILER_RT_BUILD_PROFILE=ON \
      -DCOMPILER_RT_BUILD_BUILTINS=OFF -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
      -DCOMPILER_RT_BUILD_XRAY=OFF -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
      -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF \
      -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF -DCOMPILER_RT_INCLUDE_TESTS=OFF
    cmake --build "$ROOTDIR/crt" --target profile
    _built="$(find "$ROOTDIR/crt" -name 'libclang_rt.profile*.a' | head -n1)"
    [ -n "$_built" ] || { echo "compiler-rt built no profile runtime" >&2; exit 1; }
    mkdir -p "$(dirname "$_rt")"
    cp "$_built" "$_rt"
  fi
  # LLVM_PROFDATA is the merge tool, not a build input, so pointing it into this
  # tree is fine: it only has to exist by the time the merge step runs, and being
  # the same revision as the instrumentation keeps the profraw format readable.
  cmake -S "$SRC/llvm" -B "$PROF_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$PROF_CC" -DCMAKE_CXX_COMPILER="$PROF_CXX" \
    -DLLVM_ENABLE_PROJECTS=clang \
    -DLLVM_TARGETS_TO_BUILD="${LLVM_TARGETS:-AArch64;ARM;BPF;RISCV;WebAssembly;X86}" \
    -DLLVM_BUILD_INSTRUMENTED=ON \
    -DLLVM_INCLUDE_TESTS=ON \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_ENABLE_RTTI=OFF -DLLVM_ENABLE_EH=OFF -DLLVM_ENABLE_WARNINGS=OFF \
    -DLLVM_PROFDATA="$PROF_BUILD/bin/llvm-profdata"
  cmake --build "$PROF_BUILD" --target llvm-profdata
  cmake --build "$PROF_BUILD" --target generate-profdata
  _prof="$(find "$PROF_BUILD" -name clang.profdata | head -n1)"
  [ -n "$_prof" ] || { echo "generate-profdata produced no clang.profdata" >&2; exit 1; }
  xz -T0 -c "$_prof" > "$ROOTDIR/$LLVM_REV.profdata.xz"
  log "Done -> $ROOTDIR/$LLVM_REV.profdata.xz ($(du -h "$ROOTDIR/$LLVM_REV.profdata.xz" | cut -f1))"
  exit 0
fi

: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}"
SRC="${SRC:-$ROOTDIR/llvm-project}"
BUILD_DIR="${BUILD_DIR:-$ROOTDIR/build/$TARGET}"
INSTALL_DIR="${INSTALL_DIR:-$ROOTDIR/deps/$TARGET}"
OUT="${OUT:-$ROOTDIR/llvm-$TARGET}"

# Download with retries: re-run aria2c on any failure so transient GitHub errors
# recover. Pass aria2c args, e.g. fetch --dir=/tmp -o f.zip URL.
fetch() {
  local i=0
  until aria2c --console-log-level=error --check-certificate=false \
               --max-tries=5 --retry-wait=2 --connect-timeout=15 \
               --allow-overwrite=true --auto-file-renaming=false "$@"; do
    i=$((i + 1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; return 1; }
    echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2
  done
}

# Unpack ARCHIVE into DEST, picking the tool from the extension.
unpack() {
  case "$1" in
    *.tar.gz|*.tgz) tar -xzf "$1" -C "$2" ;;
    *.tar.xz)       tar -xJf "$1" -C "$2" ;;
    *.tar.bz2)      tar -xjf "$1" -C "$2" ;;
    *.zip)          unzip -qq -o "$1" -d "$2" ;;
    *) echo "unpack: don't know how to unpack $1" >&2; return 1 ;;
  esac
}

# Download URL to ARCHIVE and unpack it into DEST (default: the current
# directory), re-downloading when the unpack fails. ARCHIVE is removed on the
# way out. Usage: fetch_unpack URL ARCHIVE [DEST]
#
# aria2c's own retries cannot see a truncated download. Endpoints that generate
# archives on the fly (gitiles' +archive, codeload) stream them chunked with no
# Content-Length, so there is no expected size to compare against: aria2 exits 0
# on a 600KiB truncation of a 200MiB archive and the damage surfaces later as
# "gzip: stdin: unexpected end of file". Unpacking is the only integrity check,
# so the retry wraps download and unpack together.
fetch_unpack() {
  local url="$1" archive="$2" dest="${3:-.}" i=0
  mkdir -p "$dest"
  while :; do
    rm -f "$archive" "$archive.aria2"
    if fetch --dir="$(dirname "$archive")" -o "$(basename "$archive")" "$url" \
       && unpack "$archive" "$dest"; then
      rm -f "$archive"
      return 0
    fi
    i=$((i + 1))
    [ "$i" -ge 8 ] && { echo "fetch_unpack: $url still incomplete after $i attempts" >&2; return 1; }
    echo "fetch_unpack: $(basename "$archive") came down incomplete, retry $i/8 in $((15 * i))s..." >&2
    sleep $((15 * i))
  done
}

# --- toolchain + platform-specific flags -----------------------------------
export ZIG_TARGET="$TARGET"
# ppc64le glibc: clang's IEEE-128 long double makes libc++ call
# glibc's __*ieee128 printf entries, which arrived in 2.32.
case "$TARGET" in powerpc64le-*-gnu*) export ZIG_TARGET="$TARGET.2.32" ;; esac
CROSS_CFLAGS="-fno-sanitize=undefined"; CROSS_CXXFLAGS="$CROSS_CFLAGS"; CROSS_LDFLAGS=""; SYSTEM_NAME="Linux"; TRIPLE="$TARGET"
# LLVM_BUILD_STATIC: ON for fully-static targets (bionic/musl), OFF otherwise.
LLVM_STATIC=OFF
# LLVM_ENABLE_PIC: OFF everywhere except macOS. arm64/arm64e Mach-O *requires* PIE.
LLVM_PIC=OFF

case "$PLATFORM" in
  bionic)
    API="${ANDROID_API:-24}"; [ "$TARGET" = riscv64-linux-android ] && [ "$API" -lt 35 ] && API=35
    TC="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    CROSS_CC="$TC/bin/${TARGET}${API}-clang"; CROSS_CXX="${CROSS_CC}++"
    CROSS_AR="$TC/bin/llvm-ar"; CROSS_RANLIB="$TC/bin/llvm-ranlib"; CROSS_STRIP="$TC/bin/llvm-strip"
    CROSS_OBJCOPY="$TC/bin/llvm-objcopy"; CROSS_LD="$TC/bin/ld"
    TRIPLE="${TARGET}${API}"
    CROSS_CFLAGS="-static -fno-sanitize=undefined"; CROSS_LDFLAGS="-static"; LLVM_STATIC=ON
    ;;
  linux)
    TC="/opt/zig-as-llvm"
    CROSS_CC="$TC/bin/cc"; CROSS_CXX="$TC/bin/c++"; CROSS_AR="$TC/bin/ar"; CROSS_RANLIB="$TC/bin/ranlib"
    CROSS_STRIP="$TC/bin/strip"; CROSS_OBJCOPY="$TC/bin/objcopy"; CROSS_LD="$TC/bin/ld"
    case "$TARGET" in
      *musl*) CROSS_CFLAGS="-static -fno-sanitize=undefined"; CROSS_LDFLAGS="-static"; LLVM_STATIC=ON
              [ -d "$PATCHES_DIR/musl/zig" ] && cp -R "$PATCHES_DIR/musl/zig/." "$(dirname "$(command -v zig)")/" || true ;;
      *)      CROSS_LDFLAGS="-static-libstdc++ -static-libgcc" ;;
    esac
    ;;
  bsd)
    TC="/opt/zig-as-llvm"
    CROSS_CC="$TC/bin/cc"; CROSS_CXX="$TC/bin/c++"; CROSS_AR="$TC/bin/ar"; CROSS_RANLIB="$TC/bin/ranlib"
    CROSS_STRIP="$TC/bin/strip"; CROSS_OBJCOPY="$TC/bin/objcopy"; CROSS_LD="$TC/bin/ld"
    case "$(echo "$TARGET" | cut -d- -f2)" in
      freebsd) SYSTEM_NAME=FreeBSD ;;
      netbsd)  SYSTEM_NAME=NetBSD ;;
      openbsd) SYSTEM_NAME=OpenBSD ;;
    esac
    ;;
  macos)
    # Darwin targets use osxcross (cctools-port + clang wrappers).
    TC="/opt/osxcross"
    case "$TARGET" in
      arm64e-*)          ARCH=arm64e ;;
      aarch64-*|arm64-*) ARCH=arm64 ;;
      x86_64h-*)         ARCH=x86_64h ;;  # Haswell+ x86_64 slice (same ABI)
      x86_64-*)          ARCH=x86_64 ;;
      *) echo "Unsupported macOS arch in TARGET='$TARGET'" >&2; exit 1 ;;
    esac
    # wrapper names carry the SDK's darwin version; glob it rather than pin.
    CCWRAP="$(ls "$TC/bin/${ARCH}-apple-darwin"*-clang 2>/dev/null | head -n1 || true)"
    [ -n "$CCWRAP" ] || { echo "osxcross clang wrapper for $ARCH not found in $TC/bin" >&2; exit 1; }
    HOST="$(basename "${CCWRAP%-clang}")"
    CROSS_CC="$TC/bin/${HOST}-clang"; CROSS_CXX="$TC/bin/${HOST}-clang++"
    CROSS_AR="$TC/bin/${HOST}-ar"; CROSS_RANLIB="$TC/bin/${HOST}-ranlib"
    CROSS_STRIP="$TC/bin/${HOST}-strip"; CROSS_LD="$TC/bin/${HOST}-ld"
    CROSS_OBJCOPY="" # cctools ships no objcopy; unused here
    CROSS_LDFLAGS="--ld-path=$CROSS_LD"
    SYSTEM_NAME=Darwin; TRIPLE="$HOST"
    LLVM_PIC=ON
    ;;
  windows)
    TC="/opt/llvm-mingw"
    CROSS_CC="$TC/bin/${TARGET}-clang"; CROSS_CXX="$TC/bin/${TARGET}-clang++"
    CROSS_AR="$TC/bin/${TARGET}-ar"; CROSS_RANLIB="$TC/bin/${TARGET}-ranlib"
    CROSS_STRIP="$TC/bin/${TARGET}-strip"; CROSS_OBJCOPY="$TC/bin/${TARGET}-objcopy"
    CROSS_LD="$TC/bin/${TARGET}-ld"
    SYSTEM_NAME=Windows
    CROSS_LDFLAGS="-static-libstdc++ -static-libgcc"
    # llvm-mingw ships aarch64 winpthread as an ARM64X archive carrying both
    # arm64 and arm64ec members; --whole-archive force-loads the EC ones and
    # lld rejects them. Let the linker take only what it needs there.
    case "$TARGET" in
      aarch64-*) CROSS_LDFLAGS="$CROSS_LDFLAGS -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic" ;;
      *) CROSS_LDFLAGS="$CROSS_LDFLAGS -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive,-Bdynamic" ;;
    esac
    ;;
  *) echo "Unknown PLATFORM='$PLATFORM'" >&2; exit 1 ;;
esac
export CROSS_CC CROSS_CXX CROSS_AR CROSS_RANLIB CROSS_STRIP CROSS_OBJCOPY CROSS_LD

# Extra cmake flags for zstd + LLVM: env-supplied plus Darwin SDK/libtool/arch
# pins so CMake doesn't probe a host Xcode. Other platforms need none.
# shellcheck disable=SC2206  # intentional word-splitting of the env var
# bionic's syscall stubs end in "b.hi __set_errno_internal", a CONDBR19 that
# reaches 1MB. Link statically and the rest of libc.a settles between the two
# objects, 1.9MB apart, and lld builds range extension thunks for CALL26 and
# JUMP26 but not for conditional branches. Nothing we pass the compiler helps:
# the instruction is already assembled into Google's prebuilt libc.a, and an
# AArch64 code model governs address materialisation and BL versus BLR, never
# b.cond. Ordering is the only lever left. Naming one symbol from each object
# hoists both whole sections to the front of .text, adjacent, because assembly
# .text is not split per function. Probed, since it costs a flag if the linker
# turns out not to take it.
if [ "$PLATFORM" = bionic ]; then
  mkdir -p "$BUILD_DIR"
  printf '%s\n' __set_errno_internal getuid > "$BUILD_DIR/symbol-order.txt"
  _so="-Wl,--symbol-ordering-file=$BUILD_DIR/symbol-order.txt -Wl,--no-warn-symbol-ordering"
  echo 'int main(void){return 0;}' > "$BUILD_DIR/so-probe.c"
  # shellcheck disable=SC2086
  if "$CROSS_CC" $CROSS_CFLAGS $CROSS_LDFLAGS $_so \
       "$BUILD_DIR/so-probe.c" -o "$BUILD_DIR/so-probe" >/dev/null 2>&1; then
    CROSS_LDFLAGS="$CROSS_LDFLAGS $_so"
    log "bionic: pinning __set_errno_internal next to the syscall stubs"
  else
    log "bionic: linker will not take --symbol-ordering-file, leaving layout alone"
  fi
  rm -f "$BUILD_DIR/so-probe.c" "$BUILD_DIR/so-probe"
fi

EXTRA_CMAKE_FLAGS=(${EXTRA_CMAKE_FLAGS:-})
if [ "$SYSTEM_NAME" = Darwin ]; then
  SDKROOT="$(ls -d "$TC/SDK/MacOSX"*.sdk 2>/dev/null | head -n1 || true)"
  [ -n "$SDKROOT" ] && EXTRA_CMAKE_FLAGS+=(-DCMAKE_OSX_SYSROOT="$SDKROOT")
  [ -x "$TC/bin/${HOST}-libtool" ] && EXTRA_CMAKE_FLAGS+=(-DCMAKE_LIBTOOL="$TC/bin/${HOST}-libtool")
  EXTRA_CMAKE_FLAGS+=(-DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
fi
# Before LLVM 16, CrossCompile.cmake forwarded our cross compiler into the NATIVE
# sub-build, so llvm-tblgen came out for the target and the build died on
# "Exec format error". 16 guarded that on NOT CMAKE_CROSSCOMPILING; older trees
# need the host compiler named outright.
case "${LLVM_VERSION%%.*}" in
  ''|*[!0-9]*) ;;
  *) [ "${LLVM_VERSION%%.*}" -lt 16 ] && EXTRA_CMAKE_FLAGS+=(
       -DCROSS_TOOLCHAIN_FLAGS_NATIVE="-DCMAKE_C_COMPILER=/usr/bin/cc;-DCMAKE_CXX_COMPILER=/usr/bin/c++" ) ;;
esac

# --- PGO usability ----------------------------------------------------------
# Four unrelated toolchains at four LLVM versions read this profile, and an
# indexed profile is rejected by any reader older than the one that wrote it.
# Ask the compiler rather than keep a version table. Two probes, so an unrelated
# compile failure can't cost us the profile: PGO drops only when the plain
# compile works and adding the profile breaks it.
if [ -n "${LLVM_PROFDATA_FILE:-}" ]; then
  mkdir -p "$BUILD_DIR"
  echo 'int main(void){return 0;}' > "$BUILD_DIR/pgo-probe.c"
  if "$CROSS_CC" $CROSS_CFLAGS -c "$BUILD_DIR/pgo-probe.c" -o "$BUILD_DIR/pgo-probe.o" >/dev/null 2>&1 \
     && ! "$CROSS_CC" $CROSS_CFLAGS -fprofile-instr-use="$LLVM_PROFDATA_FILE" \
            -c "$BUILD_DIR/pgo-probe.c" -o "$BUILD_DIR/pgo-probe.o" >/dev/null 2>&1; then
    log "PGO: $(basename "$CROSS_CC") cannot read this profile, building without"
    LLVM_PROFDATA_FILE=""
  fi
  rm -f "$BUILD_DIR/pgo-probe.c" "$BUILD_DIR/pgo-probe.o"
fi

# --- MLGO -------------------------------------------------------------------
# Two things decide whether a target can do MLGO: which backends the installed
# wheel carries, and whether the Eigen-heavy xla_aot_runtime_src cross-built
# beside the model survives the target's endianness and SIMD. Neither is
# predictable from a target list and either one fails the whole build, so probe
# both and let a target that can't do it still ship a toolchain.
MLGO_ARGS=()
# tensorflow lives in a venv at /opt/tf; ask it where, rather than hardcoding a
# python version into the path.
TENSORFLOW_AOT_PATH="${TENSORFLOW_AOT_PATH:-$(/opt/tf/bin/python -c \
  'import tensorflow,os;print(os.path.dirname(tensorflow.__file__))' 2>/dev/null || true)}"
if [ -n "${MLGO_DIR:-}" ] && [ -d "${TENSORFLOW_AOT_PATH:-/nonexistent}/xla_aot_runtime_src" ]; then
  mkdir -p "$BUILD_DIR"
  _sm="$(cd "$TENSORFLOW_AOT_PATH/../../../.." && pwd)/bin/saved_model_cli"
  # tf_compile only proves the model translates. The Eigen-heavy runtime built
  # beside it is the part that breaks: on aarch64 its convolution path
  # static-asserts on the NEON register block size (nr is 8, the assert wants 4).
  # Compile one of those TUs here rather than fail ten minutes in. It has to be a
  # convolution one, and f32 for preference: only the float path instantiates the
  # gemm_pack_rhs specialisation that asserts, so f16 and the matmul TUs compile
  # fine on aarch64 and prove nothing. The names move between releases, which is
  # why these are globs and not exact: 2.18 has convolution_thunk_f32.cc, 2.21
  # convolution_lib_f32_2d.cc. Sorted, because unsorted find order picked an f16.
  _find_tu() { find "$TENSORFLOW_AOT_PATH/xla_aot_runtime_src" -name "$1" 2>/dev/null | sort | head -n1; }
  _tu="$(_find_tu '*conv*f32*.cc')"
  [ -n "$_tu" ] || _tu="$(_find_tu '*conv*.cc')"
  [ -n "$_tu" ] || _tu="$(_find_tu 'eigen_contraction_kernel.cc')"
  [ -n "$_tu" ] || _tu="$(_find_tu '*.cc')"
  if ! { [ -x "$_sm" ] && "$_sm" aot_compile_cpu --multithreading false \
       --dir "$MLGO_DIR/inlining-Oz-chromium" --tag_set serve \
       --signature_def_key action --output_prefix "$BUILD_DIR/mlgo-probe" \
       --cpp_class ProbeModel --target_triple "$TRIPLE" >/dev/null 2>&1; }; then
    log "MLGO: $TRIPLE not supported by the AOT compiler, building without"
  elif [ -n "$_tu" ] && ! "$CROSS_CXX" $CROSS_CXXFLAGS -std=c++17 -w \
       -I"$TENSORFLOW_AOT_PATH/include" -c "$_tu" \
       -o "$BUILD_DIR/mlgo-tu.o" >/dev/null 2>&1; then
    log "MLGO: $TRIPLE cannot build the XLA runtime, building without"
  else
    log "MLGO: $TRIPLE accepted by the AOT compiler"
    MLGO_ARGS=(
      -DTENSORFLOW_AOT_PATH="$TENSORFLOW_AOT_PATH"
      -DLLVM_INLINER_MODEL_PATH="$MLGO_DIR/inlining-Oz-chromium"
      -DLLVM_RAEVICT_MODEL_PATH="$MLGO_DIR/regalloc-evict-aosp"
      # only set under MLGO: TensorFlowCompile reads it for --target_triple, and
      # changing it unconditionally would move every other target's host triple.
      -DLLVM_HOST_TRIPLE="$TRIPLE"
    )
  fi
  rm -f "$BUILD_DIR/mlgo-probe".* "$BUILD_DIR/mlgo-tu.o"
fi

# --- LTO --------------------------------------------------------------------
# Thin, and never on darwin. llvm_android's RELEASE preset sets lto for darwin
# but Stage2Builder guards LLVM_ENABLE_LTO on "not target_os.is_darwin" and drops
# it, so the mac toolchain they ship isn't LTO'd. The same guard suits us: the
# cctools ld64 osxcross calls is built without libLTO and won't take bitcode.
LLVM_LTO="${LLVM_LTO:-Thin}"
LINK_JOBS=1
if [ "$LLVM_LTO" != OFF ] && [ "$PLATFORM" = macos ]; then
  log "LTO: not applied on macos, matching llvm_android"
  LLVM_LTO=OFF
fi
# Soft-float mips gets no LTO: lld rejects the objects the LTO backend produces,
# which come out tagged -mdouble-float against an -msoft-float target. A probe
# does not reproduce it, because compiling and linking one TU in a single driver
# call keeps the ABI consistent in a way the separate link step does not. Ask the
# compiler which ABI it is instead of matching triples, so the hard-float mips
# targets keep LTO.
if [ "$LLVM_LTO" != OFF ] &&
   "$CROSS_CC" $CROSS_CFLAGS -dM -E - </dev/null 2>/dev/null | grep -q '__mips_soft_float'; then
  log "LTO: soft-float mips, lld rejects the LTO objects, building without"
  LLVM_LTO=OFF
fi
# Hexagon gets none either: under LTO codegen its backend emits something lld
# cannot name, and it dies with a bare "unknown relocation name". Only at
# llvm-tblgen size, so the probes below link their way straight past it and no
# program small enough to be worth compiling every build will reproduce it.
if [ "$LLVM_LTO" != OFF ] &&
   "$CROSS_CC" $CROSS_CFLAGS -dM -E - </dev/null 2>/dev/null | grep -qi '__hexagon__'; then
  log "LTO: hexagon, lld cannot name the relocations LTO codegen emits, building without"
  LLVM_LTO=OFF
fi
if [ "$LLVM_LTO" != OFF ]; then
  # Probe by linking, not compiling: LTO is a link-time property. Two programs:
  # lto-a is the least that exercises LTO, with a double so the bitcode carries
  # an FP ABI module flag; lto-b adds a throw, dragging in the libc++abi
  # exception machinery the real link pulls even under LLVM_ENABLE_EH=OFF.
  #
  # Each is linked without LTO first. A target that cannot link the probe at all
  # says nothing about LTO, and blaming LTO for it drops the optimisation for a
  # reason that was never LTO. Same two-step as the PGO probe above.
  mkdir -p "$BUILD_DIR"
  printf '%s\n' 'double f(double x){return x*2.0;}' \
                'int main(){ return (int)f(1.5); }' > "$BUILD_DIR/lto-a.cc"
  printf '%s\n' '#include <stdexcept>' \
                'double f(double x){return x*2.0;}' \
                'int main(){ try { if (f(1.5) > 0) throw std::runtime_error("x"); }' \
                '            catch (const std::exception &) { return 0; } return 0; }' \
                > "$BUILD_DIR/lto-b.cc"
  _probe() { "$CROSS_CXX" $CROSS_CXXFLAGS $CROSS_LDFLAGS "${@:2}" \
    "$BUILD_DIR/$1" -o "$BUILD_DIR/lto-probe" >/dev/null 2>&1; }
  for _p in lto-a.cc lto-b.cc; do
    if _probe "$_p" && ! _probe "$_p" -flto=thin; then
      log "LTO: $(basename "$CROSS_CXX") cannot link $_p with -flto=thin, building without"
      LLVM_LTO=OFF
      break
    fi
  done
  if [ "$LLVM_LTO" != OFF ] && [ ${#MLGO_ARGS[@]} -gt 0 ]; then
    # The advisor only reaches the register allocator through the linker, and zig
    # hard-errors on -mllvm: its linker args are an allowlist, with no
    # --plugin-opt to fall back on. Dropping the flag costs this build's regalloc
    # model; passing it blind costs the build.
    _adv="-Wl,-mllvm,-regalloc-enable-advisor=release"
    if _probe lto-a.cc -flto=thin "$_adv"; then
      CROSS_LDFLAGS="$CROSS_LDFLAGS $_adv"
    else
      log "LTO: linker will not take -regalloc-enable-advisor=release, leaving it off"
    fi
  fi
  # Unprofiled, they don't rate link-time codegen worth its cost, and only on
  # linux. Probed too: linux is zig's, same allowlist.
  if [ "$LLVM_LTO" != OFF ] && [ -z "${LLVM_PROFDATA_FILE:-}" ] && [ "$PLATFORM" = linux ]; then
    if _probe lto-a.cc -flto=thin -Wl,--lto-O0; then
      CROSS_LDFLAGS="$CROSS_LDFLAGS -Wl,--lto-O0"
    else
      log "LTO: linker will not take --lto-O0, leaving codegen at default"
    fi
  fi
  rm -f "$BUILD_DIR/lto-a.cc" "$BUILD_DIR/lto-b.cc" "$BUILD_DIR/lto-probe"
fi
if [ "$LLVM_LTO" != OFF ]; then
  # They widen this to min(ncpu/2, 16), sized for their build machines. On a
  # 4-vCPU runner lld's --thinlto-jobs already uses every thread, so one link
  # saturates the box and a second only doubles peak RSS.
  LINK_JOBS="${LLVM_PARALLEL_LINK_JOBS:-1}"
  log "LTO: $LLVM_LTO ($LINK_JOBS parallel link job(s), $(nproc) cpus)"
fi

# --- vendor string ----------------------------------------------------------
# llvm_android's shape with our identity in it:
#
#   Android (12285214, +pgo, +bolt, +lto, +mlgo, based on r522817b)
#
# All four markers, always, in that order, "+" applied and "-" not. The build id
# is the Actions run id, not Google's. bolt is always "-": we ship the tools but
# never run the optimizer. The rest read the value that survived their probe, so
# the string can't claim work a target dropped. clang adds the trailing space,
# see clang/lib/Basic/CMakeLists.txt.
_mark() { if [ "$1" = 1 ]; then printf '+%s' "$2"; else printf -- '-%s' "$2"; fi; }
_on_pgo=0; if [ -n "${LLVM_PROFDATA_FILE:-}" ]; then _on_pgo=1; fi
_on_lto=0; if [ "$LLVM_LTO" != OFF ]; then _on_lto=1; fi
_on_mlgo=0; if [ ${#MLGO_ARGS[@]} -gt 0 ]; then _on_mlgo=1; fi
VENDOR_OPTS="$(_mark "$_on_pgo" pgo), $(_mark 0 bolt), $(_mark "$_on_lto" lto), $(_mark "$_on_mlgo" mlgo)"
CLANG_VENDOR="${CLANG_VENDOR:-Android (${LLVM_BUILD_ID:+$LLVM_BUILD_ID, }$VENDOR_OPTS, based on ${CLANG_RELEASE:-unknown})}"
log "Vendor: $CLANG_VENDOR"

# --- zlib + zstd (static, bundled) -----------------------------------------
ZLIB_VERSION="${ZLIB_VERSION:-1.3.2}"
ZSTD_VERSION="${ZSTD_VERSION:-1.5.7}"
mkdir -p "$INSTALL_DIR" "$BUILD_DIR"
if [ ! -f "$INSTALL_DIR/lib/libz.a" ]; then
  log "Building zlib $ZLIB_VERSION"
  fetch_unpack "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.xz" \
    /tmp/zlib.tar.xz "$ROOTDIR"
  (
    cd "$ROOTDIR/zlib-$ZLIB_VERSION"
    AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" CC="$CROSS_CC" CFLAGS="$CROSS_CFLAGS" \
      ./configure --prefix="$INSTALL_DIR" --static
    # zlib 1.3.2 adds crc32_vx.o to the s390x build once its -fzvector probe
    # succeeds, but its Makefile.in substitutions have no VGFMAFLAG line, so the
    # flag that probe needed never reaches the compile and vecintrin.h refuses to
    # expand. configure.log records the value it settled on, -march=z13 and all;
    # put it back rather than give up the vectorised crc32.
    _vgfma="$(sed -n 's/^VGFMAFLAG = //p' configure.log | tail -n1)"
    if [ -n "$_vgfma" ]; then
      log "zlib: restoring VGFMAFLAG=$_vgfma that configure dropped"
      sed -i "s#^VGFMAFLAG=.*#VGFMAFLAG=$_vgfma#" Makefile
    fi
    make -j"$(nproc)" install
  )
fi
if [ ! -f "$INSTALL_DIR/lib/libzstd.a" ]; then
  log "Building zstd $ZSTD_VERSION"
  fetch_unpack "https://github.com/facebook/zstd/archive/refs/tags/v$ZSTD_VERSION.tar.gz" \
    /tmp/zstd.tar.gz "$ROOTDIR"
  # arm64ec carries x86_64's macros so datatype layouts match x64, but zstd reads
  # them as "has x86 instructions": _M_AMD64 pulls <emmintrin.h> (ZSTD_NO_INTRINSICS
  # is zstd's own opt-out), and __x86_64__/_M_X64 gate cpuid asm, .p2align hints and
  # BMI2. Each site has a portable #else.
  ZSTD_EXTRA_CFLAGS=""
  case "$TARGET" in
    arm64ec-*)
      ZSTD_EXTRA_CFLAGS=" -DZSTD_NO_INTRINSICS"
      grep -rl 'defined(__x86_64__)\|defined(_M_X64)' "$ROOTDIR/zstd-$ZSTD_VERSION/lib" 2>/dev/null | while read -r _f; do
        sed -i -e 's@defined(__x86_64__)@(defined(__x86_64__) \&\& !defined(__arm64ec__))@g' \
               -e 's@defined(_M_X64)@(defined(_M_X64) \&\& !defined(_M_ARM64EC))@g' "$_f"
      done ;;
  esac
  cmake -S "$ROOTDIR/zstd-$ZSTD_VERSION/build/cmake" -B "$BUILD_DIR/zstd" \
    -DCMAKE_C_COMPILER="$CROSS_CC" -DCMAKE_CXX_COMPILER="$CROSS_CXX" -DCMAKE_ASM_COMPILER="$CROSS_CC" \
    -DCMAKE_AR="$CROSS_AR" -DCMAKE_RANLIB="$CROSS_RANLIB" -DCMAKE_STRIP="$CROSS_STRIP" \
    ${CROSS_OBJCOPY:+-DCMAKE_OBJCOPY="$CROSS_OBJCOPY"} -DCMAKE_LINKER="$CROSS_LD" \
    -DCMAKE_C_FLAGS="$CROSS_CFLAGS$ZSTD_EXTRA_CFLAGS" -DCMAKE_CXX_FLAGS="$CROSS_CXXFLAGS$ZSTD_EXTRA_CFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$CROSS_LDFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$CROSS_LDFLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$CROSS_LDFLAGS" -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_CROSSCOMPILING=True -DCMAKE_SYSTEM_NAME="$SYSTEM_NAME" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_CONTRIB=OFF -DZSTD_MULTITHREAD_SUPPORT=ON \
    "${EXTRA_CMAKE_FLAGS[@]}"
  cmake --build "$BUILD_DIR/zstd" --target install -j"$(nproc)"
fi

# --- LLVM -------------------------------------------------------------------
args=(
  -DCMAKE_INSTALL_PREFIX="$OUT"
  -DCMAKE_PREFIX_PATH="$INSTALL_DIR"
  -DLLVM_TARGETS_TO_BUILD="${LLVM_TARGETS:-AArch64;ARM;BPF;RISCV;WebAssembly;X86}"
  -DCMAKE_BUILD_TYPE=MinSizeRel
  -DCMAKE_CROSSCOMPILING=True
  -DCMAKE_SYSTEM_NAME="$SYSTEM_NAME"
  -DLLVM_DEFAULT_TARGET_TRIPLE="$TRIPLE"
  -DCMAKE_C_COMPILER="$CROSS_CC" -DCMAKE_CXX_COMPILER="$CROSS_CXX" -DCMAKE_ASM_COMPILER="$CROSS_CC"
  -DCMAKE_LINKER="$CROSS_LD" -DCMAKE_AR="$CROSS_AR" -DCMAKE_RANLIB="$CROSS_RANLIB"
  -DCMAKE_STRIP="$CROSS_STRIP"
  -DCMAKE_EXE_LINKER_FLAGS="$CROSS_LDFLAGS"
  -DCMAKE_SHARED_LINKER_FLAGS="$CROSS_LDFLAGS"
  -DCMAKE_MODULE_LINKER_FLAGS="$CROSS_LDFLAGS"
  -DLLVM_ENABLE_PROJECTS="$PROJECTS"
  -DLLVM_ENABLE_ZLIB=FORCE_ON -DLLVM_ENABLE_ZSTD=FORCE_ON -DLLVM_USE_STATIC_ZSTD=ON
  -DLLVM_BUILD_STATIC=$LLVM_STATIC -DBUILD_SHARED_LIBS=OFF -DLLVM_LINK_LLVM_DYLIB=OFF
  -DLIBCLANG_BUILD_STATIC=ON -DCLANG_ENABLE_ARCMT=OFF -DCMAKE_SKIP_INSTALL_RPATH=TRUE
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_BUILD_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_BUILD_EXAMPLES=OFF
  -DLLVM_BUILD_TESTS=OFF -DLLVM_INCLUDE_TESTS=OFF
  -DCLANG_INCLUDE_TESTS=OFF -DCLANG_BUILD_TESTS=OFF -DLLVM_BUILD_TOOLS=ON
  -DLLVM_ENABLE_WARNINGS=OFF -DLLVM_ENABLE_PEDANTIC=OFF -DLLVM_TOOL_C_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_IMPORT_TEST_BUILD=OFF -DCLANG_TOOL_APINOTES_TEST_BUILD=OFF
  -DCLANG_TOOL_ARCMT_TEST_BUILD=OFF -DCLANG_TOOL_C_ARCMT_TEST_BUILD=OFF
  -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF
  -DLLVM_INSTALL_BINUTILS_SYMLINKS=ON -DLLVM_INSTALL_CCTOOLS_SYMLINKS=ON
  -DLLVM_PARALLEL_LINK_JOBS=$LINK_JOBS -DLLVM_ENABLE_PIC=$LLVM_PIC
  -DLLVM_ENABLE_LIBCXX=OFF -DLLVM_ENABLE_LLVM_LIBC=OFF
  -DLLVM_ENABLE_UNWIND_TABLES=OFF -DLLVM_ENABLE_EH=OFF -DLLVM_ENABLE_RTTI=OFF
  -DLLVM_ENABLE_LTO="$LLVM_LTO" -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_MODULES=OFF
  -DLLVM_ENABLE_FFI=OFF -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_THREADS=ON
  -DLLVM_VERSION_SUFFIX=""
  -DCLANG_VENDOR="$CLANG_VENDOR"
  -DCLANG_DEFAULT_LINKER=lld -DCLANG_DEFAULT_OBJCOPY=llvm-objcopy
  -DCLANG_REPOSITORY_STRING="${CLANG_REPOSITORY_STRING:-llvm-custom}"
  -DPACKAGE_BUGREPORT="${PACKAGE_BUGREPORT:-}"
)
# Pin zlib + zstd to our bundled static builds so find_package() doesn't grab an
# incompatible host .so (which lld drops, leaving zlib/zstd symbols undefined).
args+=(
  -DZLIB_LIBRARY="$INSTALL_DIR/lib/libz.a" -DZLIB_INCLUDE_DIR="$INSTALL_DIR/include"
  -Dzstd_LIBRARY="$INSTALL_DIR/lib/libzstd.a" -Dzstd_INCLUDE_DIR="$INSTALL_DIR/include"
)
# A profile from one tree still misses functions that differ per target, like
# #ifdef'd code and target-specific TableGen output, so quiet the two warnings
# that reports. Added after zlib/zstd are built, so only the LLVM configure sees
# them. llvm_android suppresses exactly this pair.
if [ -n "${LLVM_PROFDATA_FILE:-}" ]; then
  _pgo_w=" -Wno-profile-instr-out-of-date -Wno-profile-instr-unprofiled"
  CROSS_CFLAGS="$CROSS_CFLAGS$_pgo_w"; CROSS_CXXFLAGS="$CROSS_CXXFLAGS$_pgo_w"
fi
[ -n "$CROSS_CFLAGS" ] && args+=(-DCMAKE_C_FLAGS="$CROSS_CFLAGS" -DCMAKE_CXX_FLAGS="$CROSS_CXXFLAGS")
# pass CMAKE_OBJCOPY only when the toolchain has one (empty on macos).
[ -n "$CROSS_OBJCOPY" ] && args+=(-DCMAKE_OBJCOPY="$CROSS_OBJCOPY")
# the vendor string reports PGO off the same variable, so it has to reach cmake.
[ -n "${LLVM_PROFDATA_FILE:-}" ] && args+=(-DLLVM_PROFDATA_FILE="$LLVM_PROFDATA_FILE")
[ ${#MLGO_ARGS[@]} -gt 0 ] && args+=("${MLGO_ARGS[@]}")
# arm64ec: llvm-mingw skips compiler-rt for EC and builds the aarch64 builtins
# -marm64x, so LLVM's PURE_WINDOWS probes find __ashldi3 and friends but the
# EC-mangled forms do not exist. DynamicLibrary takes their address for the JIT
# symbol table and the link fails. Seed every probe in that block as absent; the
# alloca/chkstk/__main half fails the same way.
case "$TARGET" in
  arm64ec-*)
    for _v in HAVE__ALLOCA HAVE___ALLOCA HAVE___CHKSTK HAVE___CHKSTK_MS HAVE____CHKSTK HAVE____CHKSTK_MS HAVE___MAIN HAVE___ASHLDI3 HAVE___ASHRDI3 HAVE___CMPDI2 HAVE___DIVDI3 HAVE___FIXDFDI HAVE___FIXSFDI HAVE___FLOATDIDF HAVE___LSHRDI3 HAVE___MODDI3 HAVE___UDIVDI3 HAVE___UMODDI3; do
      args+=("-D${_v}=0")
    done ;;
esac
[ ${#EXTRA_CMAKE_FLAGS[@]} -gt 0 ] && args+=("${EXTRA_CMAKE_FLAGS[@]}")
# GNU/Linux: zig's glibc 2.31 headers ship sys/rseq.h but not __rseq_offset/
# __rseq_size (2.35), so GLIBC_INITS_RSEQ is defined and the link fails. Force
# the detection var off to drop the rseq path. (musl has no rseq.)
if [ "$PLATFORM" = linux ] && [[ "$TARGET" != *musl* ]]; then
  args+=(-DHAVE_BUILTIN_THREAD_POINTER=0)
fi

# --- distribution components ------------------------------------------------
# Build the tools the NDK ships and nothing else. A default build links 122
# executables per target while the NDK carries 46, and under LTO each of the
# other 76 costs a full codegen link. That includes llvm-tblgen and clang-tblgen
# built for the target, which a cross build cannot even run; the NATIVE
# sub-build supplies the ones it uses.
#
# Components are not one per binary. bolt puts all of its tools under a single
# "bolt", and the install step makes the rest as symlinks: clang++ off clang,
# ld and ld.lld and ld64.lld and lld-link off lld, ranlib and lib off llvm-ar,
# readelf off llvm-readobj, strip off llvm-objcopy, addr2line off
# llvm-symbolizer, windres off llvm-rc.
#
# Each entry is gated on its directory existing, because an unknown component is
# a configure-time SEND_ERROR and these eight trees span LLVM 14 to 21. Pruning
# beats pinning a list that only suits the newest.
DIST=()
_want() { [ -d "$SRC/$2" ] && DIST+=("$1"); return 0; }
_want clang                  clang/tools/driver
_want clang-resource-headers clang/lib/Headers
_want clang-check            clang/tools/clang-check
_want clang-format           clang/tools/clang-format
_want scan-build             clang/tools/scan-build
_want scan-view              clang/tools/scan-view
_want scan-build-py          clang/tools/scan-build-py
_want clang-tidy             clang-tools-extra/clang-tidy
_want clangd                 clang-tools-extra/clangd
_want lld                    lld
_want bolt                   bolt
for _t in dsymutil sancov sanstats llvm-config llvm-ar llvm-as llvm-cfi-verify \
          llvm-cov llvm-cxxfilt llvm-dis llvm-dwarfdump llvm-dwp llvm-ifs \
          llvm-link llvm-lipo llvm-ml llvm-modextract llvm-nm llvm-objcopy \
          llvm-objdump llvm-profdata llvm-rc llvm-readobj llvm-size \
          llvm-strings llvm-symbolizer; do
  _want "$_t" "llvm/tools/$_t"
done
args+=(-DLLVM_DISTRIBUTION_COMPONENTS="$(IFS=';'; printf '%s' "${DIST[*]}")")
log "Distribution: ${#DIST[@]} components"

log "Configuring LLVM for $TARGET ($PLATFORM)"
cmake -S "$SRC/llvm" -B "$BUILD_DIR" -G Ninja "${args[@]}"
log "Building + installing"
cmake --build "$BUILD_DIR" --target install-distribution

# Every ELF tool the NDK ships has to come back out, or assemble_ndk silently
# keeps Google's copy: it only replaces a file when one of the same name exists
# in ours. lldb went with the debuggers and yasm comes from android-ndk-custom.
_ndk_bin="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
if [ -d "$_ndk_bin" ]; then
  _missing=""
  for _f in "$_ndk_bin"/*; do
    _b="$(basename "$_f")"
    case "$_b" in lldb*|yasm) continue ;; esac
    file -bL "$_f" 2>/dev/null | grep -q ELF || continue
    [ -e "$OUT/bin/$_b" ] || _missing="$_missing $_b"
  done
  [ -z "$_missing" ] || {
    echo "install-distribution did not produce:$_missing" >&2; exit 1; }
  log "All of the NDK's tools accounted for"
fi

# strip installed binaries one at a time (the zig-as-llvm strip wrapper takes
# only one file arg).
find "$OUT/bin" -type f ! -lname '*' | while IFS= read -r f; do
  "$CROSS_STRIP" "$f" 2>/dev/null || true
done
log "Done -> $OUT"
