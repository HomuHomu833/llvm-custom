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
#   PROJECTS    LLVM_ENABLE_PROJECTS (default: bolt;clang;clang-tools-extra;lld)
#   ROOTDIR     work dir (default: cwd)
#   ANDROID_API bionic API level (default: 25, riscv64 forced to 35)
#
# Reads $ROOTDIR/.build-env (written by fetch-source.sh) for SRC/NDK_DIR/LLVM_VERSION.
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${PLATFORM:?set PLATFORM}" "${TARGET:?set TARGET}"
PROJECTS="${PROJECTS:-bolt;clang;clang-tools-extra;lld}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PATCHES_DIR="${PATCHES_DIR:-$SCRIPT_DIR/../patches}"

# shellcheck disable=SC1091
[ -f "$ROOTDIR/.build-env" ] && . "$ROOTDIR/.build-env"
SRC="${SRC:-$ROOTDIR/llvm-project}"
BUILD_DIR="${BUILD_DIR:-$ROOTDIR/build/$TARGET}"
INSTALL_DIR="${INSTALL_DIR:-$ROOTDIR/deps/$TARGET}"
OUT="${OUT:-$ROOTDIR/llvm-$TARGET}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- toolchain + platform-specific flags -----------------------------------
export ZIG_TARGET="$TARGET"
CROSS_CFLAGS="-fno-sanitize=undefined"; CROSS_LDFLAGS=""; SYSTEM_NAME="Linux"; TRIPLE="$TARGET"
# LLVM_BUILD_STATIC mirrors upstream per platform: ON for the fully-static targets
# (bionic/musl), OFF for the dynamically-linked bsd/windows builds. Windows only
# statically links the mingw C++/unwind/pthread runtime (see the windows case),
# not the whole binary, so pass plugins can still resolve symbols dynamically.
LLVM_STATIC=OFF

case "$PLATFORM" in
  bionic)
    API="${ANDROID_API:-25}"; [ "$TARGET" = riscv64-linux-android ] && API=35
    TC="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    CROSS_CC="$TC/bin/${TARGET}${API}-clang"; CROSS_CXX="${CROSS_CC}++"
    CROSS_AR="$TC/bin/llvm-ar"; CROSS_RANLIB="$TC/bin/llvm-ranlib"; CROSS_STRIP="$TC/bin/llvm-strip"
    CROSS_OBJCOPY="$TC/bin/llvm-objcopy"; CROSS_LD="$TC/bin/ld"
    TRIPLE="${TARGET}${API}"; LLVM_STATIC=ON
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
    # Darwin targets use osxcross (cctools-port + clang wrappers), not zig:
    # zig segfaults building macOS LLVM. The wrappers carry the macOS SDK
    # sysroot themselves, so no -isysroot/-iframework juggling is needed here.
    TC="/opt/osxcross"
    case "$TARGET" in
      arm64e-*)          ARCH=arm64e ;;   # distinct PAC ABI, not arm64
      aarch64-*|arm64-*) ARCH=arm64 ;;
      x86_64-*)          ARCH=x86_64 ;;
      *) echo "Unsupported macOS arch in TARGET='$TARGET'" >&2; exit 1 ;;
    esac
    # osxcross names its wrappers with the SDK's darwin version (e.g.
    # arm64-apple-darwin24.5-clang); resolve that prefix by globbing rather
    # than pinning a version that drifts with the baked SDK.
    CCWRAP="$(ls "$TC/bin/${ARCH}-apple-darwin"*-clang 2>/dev/null | head -n1 || true)"
    [ -n "$CCWRAP" ] || { echo "osxcross clang wrapper for $ARCH not found in $TC/bin" >&2; exit 1; }
    HOST="$(basename "${CCWRAP%-clang}")"
    CROSS_CC="$TC/bin/${HOST}-clang"; CROSS_CXX="$TC/bin/${HOST}-clang++"
    CROSS_AR="$TC/bin/${HOST}-ar"; CROSS_RANLIB="$TC/bin/${HOST}-ranlib"
    CROSS_STRIP="$TC/bin/${HOST}-strip"; CROSS_LD="$TC/bin/${HOST}-ld"
    CROSS_OBJCOPY=""   # cctools ships no objcopy; the Darwin LLVM build needs none
    SYSTEM_NAME=Darwin; TRIPLE="$HOST"
    ;;
  windows)
    TC="/opt/llvm-mingw"
    CROSS_CC="$TC/bin/${TARGET}-clang"; CROSS_CXX="$TC/bin/${TARGET}-clang++"
    CROSS_AR="$TC/bin/${TARGET}-ar"; CROSS_RANLIB="$TC/bin/${TARGET}-ranlib"
    CROSS_STRIP="$TC/bin/${TARGET}-strip"; CROSS_OBJCOPY="$TC/bin/${TARGET}-objcopy"
    CROSS_LD="$TC/bin/${TARGET}-ld"
    SYSTEM_NAME=Windows
    CROSS_LDFLAGS="-static-libstdc++ -static-libgcc -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive,-Bdynamic"
    ;;
  *) echo "Unknown PLATFORM='$PLATFORM'" >&2; exit 1 ;;
esac
export CROSS_CC CROSS_CXX CROSS_AR CROSS_RANLIB CROSS_STRIP CROSS_OBJCOPY CROSS_LD

# Extra CMake flags shared by the zstd + LLVM Darwin configures: point CMake's
# Apple support at the osxcross SDK + cctools libtool (CMake creates static libs
# with libtool, not ar, on Darwin) so it doesn't probe a host Xcode, and pin the
# arch + deployment target. zig-targeted platforms need none of this.
DARWIN_CMAKE_ARGS=()
if [ "$SYSTEM_NAME" = Darwin ]; then
  SDKROOT="$(ls -d "$TC/SDK/MacOSX"*.sdk 2>/dev/null | head -n1 || true)"
  [ -n "$SDKROOT" ] && DARWIN_CMAKE_ARGS+=(-DCMAKE_OSX_SYSROOT="$SDKROOT")
  [ -x "$TC/bin/${HOST}-libtool" ] && DARWIN_CMAKE_ARGS+=(-DCMAKE_LIBTOOL="$TC/bin/${HOST}-libtool")
  DARWIN_CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0)
fi

# --- zlib + zstd (static, bundled) -----------------------------------------
mkdir -p "$INSTALL_DIR" "$BUILD_DIR"
if [ ! -f "$INSTALL_DIR/lib/libz.a" ]; then
  log "Building zlib"
  aria2c --max-tries=20 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o zlib.tar.xz \
    https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz \
  && xz -d < /tmp/zlib.tar.xz | tar -x -C "$ROOTDIR" \
  && rm /tmp/zlib.tar.xz
  ( cd "$ROOTDIR/zlib-1.3.1" && AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" CC="$CROSS_CC" CFLAGS="$CROSS_CFLAGS" ./configure --prefix="$INSTALL_DIR" --static && make -j"$(nproc)" install )
fi
if [ ! -f "$INSTALL_DIR/lib/libzstd.a" ]; then
  log "Building zstd"
  aria2c --max-tries=20 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o zstd.tar.gz \
    https://github.com/facebook/zstd/archive/refs/tags/v1.5.6.tar.gz \
  && gzip -d < /tmp/zstd.tar.gz | tar -x -C "$ROOTDIR" \
  && rm /tmp/zstd.tar.gz
  cmake -S "$ROOTDIR/zstd-1.5.6/build/cmake" -B "$BUILD_DIR/zstd" \
    -DCMAKE_C_COMPILER="$CROSS_CC" -DCMAKE_CXX_COMPILER="$CROSS_CXX" -DCMAKE_ASM_COMPILER="$CROSS_CC" \
    -DCMAKE_AR="$CROSS_AR" -DCMAKE_RANLIB="$CROSS_RANLIB" -DCMAKE_STRIP="$CROSS_STRIP" \
    ${CROSS_OBJCOPY:+-DCMAKE_OBJCOPY="$CROSS_OBJCOPY"} -DCMAKE_LINKER="$CROSS_LD" \
    -DCMAKE_C_FLAGS="$CROSS_CFLAGS" -DCMAKE_CXX_FLAGS="$CROSS_CFLAGS" \
    -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_CROSSCOMPILING=True -DCMAKE_SYSTEM_NAME="$SYSTEM_NAME" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_CONTRIB=OFF -DZSTD_MULTITHREAD_SUPPORT=ON \
    "${DARWIN_CMAKE_ARGS[@]}"
  cmake --build "$BUILD_DIR/zstd" --target install -j"$(nproc)"
fi

# --- LLVM -------------------------------------------------------------------
args=(
  -DCMAKE_INSTALL_PREFIX="$OUT"
  -DCMAKE_PREFIX_PATH="$INSTALL_DIR"
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;ARM;RISCV"
  -DCMAKE_BUILD_TYPE=MinSizeRel
  -DCMAKE_CROSSCOMPILING=True
  -DCMAKE_SYSTEM_NAME="$SYSTEM_NAME"
  -DLLVM_DEFAULT_TARGET_TRIPLE="$TRIPLE"
  -DCMAKE_C_COMPILER="$CROSS_CC" -DCMAKE_CXX_COMPILER="$CROSS_CXX" -DCMAKE_ASM_COMPILER="$CROSS_CC"
  -DCMAKE_LINKER="$CROSS_LD" -DCMAKE_AR="$CROSS_AR" -DCMAKE_RANLIB="$CROSS_RANLIB"
  -DCMAKE_STRIP="$CROSS_STRIP"
  -DCMAKE_EXE_LINKER_FLAGS="$CROSS_LDFLAGS"
  -DCMAKE_SHARED_LINKER_FLAGS="$CROSS_LDFLAGS"
  -DLLVM_ENABLE_PROJECTS="$PROJECTS"
  -DLLVM_ENABLE_ZLIB=FORCE_ON -DLLVM_ENABLE_ZSTD=FORCE_ON -DLLVM_USE_STATIC_ZSTD=ON
  -DLLVM_BUILD_STATIC=$LLVM_STATIC -DBUILD_SHARED_LIBS=OFF -DLLVM_LINK_LLVM_DYLIB=OFF
  -DLIBCLANG_BUILD_STATIC=ON -DCLANG_ENABLE_ARCMT=OFF -DCMAKE_SKIP_INSTALL_RPATH=TRUE
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_BUILD_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_BUILD_EXAMPLES=OFF
  -DLLVM_BUILD_TESTS=OFF -DLLVM_INCLUDE_TESTS=OFF
  -DCLANG_INCLUDE_TESTS=OFF -DCLANG_BUILD_TESTS=OFF -DLLVM_BUILD_TOOLS=ON
  -DLLVM_ENABLE_PEDANTIC=OFF -DLLVM_TOOL_C_TEST_BUILD=OFF
  -DCLANG_TOOL_CLANG_IMPORT_TEST_BUILD=OFF -DCLANG_TOOL_APINOTES_TEST_BUILD=OFF
  -DCLANG_TOOL_ARCMT_TEST_BUILD=OFF -DCLANG_TOOL_C_ARCMT_TEST_BUILD=OFF
  -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF
  -DLLVM_INSTALL_BINUTILS_SYMLINKS=ON -DLLVM_INSTALL_CCTOOLS_SYMLINKS=ON
  -DLLVM_PARALLEL_LINK_JOBS=1 -DLLVM_ENABLE_PIC=OFF
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
# Pin zlib + zstd to our bundled static builds so find_package() can't resolve
# them against the host (the build image ships zlib1g-dev/libzstd-dev) or a
# toolchain sysroot. Otherwise an incompatible host .so slips onto the link line,
# lld drops it as incompatible, and zlib/zstd symbols (compressBound, compress2,
# uncompress, ...) end up undefined. Upstream only overrides this for bionic; we
# do it for every cross target since the bundled static libs always exist here.
args+=(
  -DZLIB_LIBRARY="$INSTALL_DIR/lib/libz.a" -DZLIB_INCLUDE_DIR="$INSTALL_DIR/include"
  -Dzstd_LIBRARY="$INSTALL_DIR/lib/libzstd.a" -Dzstd_INCLUDE_DIR="$INSTALL_DIR/include"
)
[ -n "$CROSS_CFLAGS" ] && args+=(-DCMAKE_C_FLAGS="$CROSS_CFLAGS" -DCMAKE_CXX_FLAGS="$CROSS_CFLAGS")
# cctools has no objcopy, so CROSS_OBJCOPY is empty for macos; only pass it when
# the toolchain actually provides one (zig/llvm-mingw/NDK all do).
[ -n "$CROSS_OBJCOPY" ] && args+=(-DCMAKE_OBJCOPY="$CROSS_OBJCOPY")
# Darwin (osxcross): SDK sysroot + libtool + arch/deployment target (see above).
[ ${#DARWIN_CMAKE_ARGS[@]} -gt 0 ] && args+=("${DARWIN_CMAKE_ARGS[@]}")
# GNU/Linux targets: zig bundles glibc 2.31 headers, which ship sys/rseq.h
# (added in 2.28) but not the runtime symbols __rseq_offset/__rseq_size
# (added in 2.35). All three preprocessor guards in BenchmarkRunner.cpp
# therefore pass, GLIBC_INITS_RSEQ gets defined, and the link fails.
# Bumping to glibc 2.35 would require appending a version suffix to the
# target triple, which I deliberately avoid. Instead, forcing this CMake
# feature detection variable to 0 prevents GLIBC_INITS_RSEQ from being
# defined, removing the rseq code path entirely at compile time.
# no needed for musl (no rseq at all).
if [ "$PLATFORM" = linux ] && [[ "$TARGET" != *musl* ]]; then
  args+=(-DHAVE_BUILTIN_THREAD_POINTER=0)
fi

log "Configuring LLVM for $TARGET ($PLATFORM)"
cmake -S "$SRC/llvm" -B "$BUILD_DIR" -G Ninja "${args[@]}"
log "Building + installing"
cmake --build "$BUILD_DIR" --target install

# strip installed binaries one at a time: the zig-as-llvm strip wrapper only
# handles a single file argument, and real llvm-strip is fine either way.
find "$OUT/bin" -type f ! -lname '*' | while IFS= read -r f; do
  "$CROSS_STRIP" "$f" 2>/dev/null || true
done
log "Done -> $OUT"
