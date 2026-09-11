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
#   ANDROID_API bionic API level (default: 25, riscv64 forced to 35 if lower)
#   EXTRA_CMAKE_FLAGS  optional extra -D flags for the zstd + LLVM configures
#
# Reads $ROOTDIR/.build-env (written by fetch-source.sh) for SRC/NDK_DIR/LLVM_VERSION.
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}"
PROJECTS="${PROJECTS:-bolt;clang;clang-tools-extra;lld;polly}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PATCHES_DIR="${PATCHES_DIR:-$SCRIPT_DIR/../patches}"

# shellcheck disable=SC1091
[ -f "$ROOTDIR/.build-env" ] && . "$ROOTDIR/.build-env"
SRC="${SRC:-$ROOTDIR/llvm-project}"
BUILD_DIR="${BUILD_DIR:-$ROOTDIR/build/$TARGET}"
INSTALL_DIR="${INSTALL_DIR:-$ROOTDIR/deps/$TARGET}"
OUT="${OUT:-$ROOTDIR/llvm-$TARGET}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

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
# archives on the fly -- gitiles' +archive, codeload -- stream them chunked with
# no Content-Length (aria2 logs the size as "0B/0B"), so when the far end cuts
# the stream short there is no expected size to compare against: aria2 prints
# "(OK):download completed" and exits 0 on a 600KiB truncation of a 200MiB
# archive, and the damage only surfaces further down as "gzip: stdin:
# unexpected end of file". Unpacking is the only integrity check available, so
# the retry has to wrap the download and the unpack together.
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
    [ "$i" -ge 5 ] && { echo "fetch_unpack: $url still incomplete after $i attempts" >&2; return 1; }
    echo "fetch_unpack: $(basename "$archive") came down incomplete, retry $i/5 in $((5 * i))s..." >&2
    sleep $((5 * i))
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
    API="${ANDROID_API:-25}"; [ "$TARGET" = riscv64-linux-android ] && [ "$API" -lt 35 ] && API=35
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
EXTRA_CMAKE_FLAGS=(${EXTRA_CMAKE_FLAGS:-})
if [ "$SYSTEM_NAME" = Darwin ]; then
  SDKROOT="$(ls -d "$TC/SDK/MacOSX"*.sdk 2>/dev/null | head -n1 || true)"
  [ -n "$SDKROOT" ] && EXTRA_CMAKE_FLAGS+=(-DCMAKE_OSX_SYSROOT="$SDKROOT")
  [ -x "$TC/bin/${HOST}-libtool" ] && EXTRA_CMAKE_FLAGS+=(-DCMAKE_LIBTOOL="$TC/bin/${HOST}-libtool")
  EXTRA_CMAKE_FLAGS+=(-DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
fi

# --- zlib + zstd (static, bundled) -----------------------------------------
mkdir -p "$INSTALL_DIR" "$BUILD_DIR"
if [ ! -f "$INSTALL_DIR/lib/libz.a" ]; then
  log "Building zlib"
  fetch_unpack https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz \
    /tmp/zlib.tar.xz "$ROOTDIR"
  ( cd "$ROOTDIR/zlib-1.3.1" && AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" CC="$CROSS_CC" CFLAGS="$CROSS_CFLAGS" ./configure --prefix="$INSTALL_DIR" --static && make -j"$(nproc)" install )
fi
if [ ! -f "$INSTALL_DIR/lib/libzstd.a" ]; then
  log "Building zstd"
  fetch_unpack https://github.com/facebook/zstd/archive/refs/tags/v1.5.6.tar.gz \
    /tmp/zstd.tar.gz "$ROOTDIR"
  # arm64ec carries x86_64's macros so datatype layouts match x64, but zstd reads
  # them as "has x86 instructions": _M_AMD64 pulls <emmintrin.h> (ZSTD_NO_INTRINSICS
  # is zstd's own opt-out), and __x86_64__/_M_X64 gate cpuid asm, .p2align hints and
  # BMI2. Each site has a portable #else.
  ZSTD_EXTRA_CFLAGS=""
  case "$TARGET" in
    arm64ec-*)
      ZSTD_EXTRA_CFLAGS=" -DZSTD_NO_INTRINSICS"
      grep -rl 'defined(__x86_64__)\|defined(_M_X64)' "$ROOTDIR/zstd-1.5.6/lib" 2>/dev/null | while read -r _f; do
        sed -i -e 's@defined(__x86_64__)@(defined(__x86_64__) \&\& !defined(__arm64ec__))@g' \
               -e 's@defined(_M_X64)@(defined(_M_X64) \&\& !defined(_M_ARM64EC))@g' "$_f"
      done ;;
  esac
  cmake -S "$ROOTDIR/zstd-1.5.6/build/cmake" -B "$BUILD_DIR/zstd" \
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
  -DLLVM_TARGETS_TO_BUILD="AArch64;ARM;BPF;RISCV;WebAssembly;X86"
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
  -DLLVM_PARALLEL_LINK_JOBS=1 -DLLVM_ENABLE_PIC=$LLVM_PIC
  -DLLVM_ENABLE_LIBCXX=OFF -DLLVM_ENABLE_LLVM_LIBC=OFF
  -DLLVM_ENABLE_UNWIND_TABLES=OFF -DLLVM_ENABLE_EH=OFF -DLLVM_ENABLE_RTTI=OFF
  -DLLVM_ENABLE_LTO=OFF -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_MODULES=OFF
  -DLLVM_ENABLE_FFI=OFF -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_THREADS=ON
  -DLLVM_VERSION_SUFFIX=""
  -DCLANG_VENDOR="Android"
  -DCLANG_REPOSITORY_STRING="${CLANG_REPOSITORY_STRING:-llvm-custom}"
  -DPACKAGE_BUGREPORT="${PACKAGE_BUGREPORT:-}"
)
# Pin zlib + zstd to our bundled static builds so find_package() doesn't grab an
# incompatible host .so (which lld drops, leaving zlib/zstd symbols undefined).
args+=(
  -DZLIB_LIBRARY="$INSTALL_DIR/lib/libz.a" -DZLIB_INCLUDE_DIR="$INSTALL_DIR/include"
  -Dzstd_LIBRARY="$INSTALL_DIR/lib/libzstd.a" -Dzstd_INCLUDE_DIR="$INSTALL_DIR/include"
)
[ -n "$CROSS_CFLAGS" ] && args+=(-DCMAKE_C_FLAGS="$CROSS_CFLAGS" -DCMAKE_CXX_FLAGS="$CROSS_CXXFLAGS")
# pass CMAKE_OBJCOPY only when the toolchain has one (empty on macos).
[ -n "$CROSS_OBJCOPY" ] && args+=(-DCMAKE_OBJCOPY="$CROSS_OBJCOPY")
# arm64ec: llvm-mingw skips compiler-rt for EC and builds the aarch64 builtins
# -marm64x, so LLVM's PURE_WINDOWS probes find __ashldi3 and friends but the
# EC-mangled forms do not exist. DynamicLibrary takes their address for the JIT's
# symbol table, which then fails to link ("undefined symbol: ... (EC symbol)").
# Seed every probe in that block as absent: the alloca/chkstk/__main half fails
# the same way, and they only populate the JIT symbol table.
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

log "Configuring LLVM for $TARGET ($PLATFORM)"
cmake -S "$SRC/llvm" -B "$BUILD_DIR" -G Ninja "${args[@]}"
log "Building + installing"
cmake --build "$BUILD_DIR" --target install

# strip installed binaries one at a time (the zig-as-llvm strip wrapper takes
# only one file arg).
find "$OUT/bin" -type f ! -lname '*' | while IFS= read -r f; do
  "$CROSS_STRIP" "$f" 2>/dev/null || true
done
log "Done -> $OUT"
