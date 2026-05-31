#!/usr/bin/env bash
# Build LLVM/clang for one cross target. Driven entirely by env vars so it runs
# identically in CI and in `docker run`.
#
#   PLATFORM    bionic | linux | bsd | windows
#   TARGET      target triple, e.g.
#                 aarch64-linux-android        (bionic)
#                 x86_64-linux-gnu / -musl     (linux)
#                 aarch64-freebsd-none         (bsd)
#                 x86_64-w64-mingw32           (windows)
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
CFLAGS=""; LDFLAGS=""; SYSTEM_NAME="Linux"; TRIPLE="$TARGET"

case "$PLATFORM" in
  bionic)
    API="${ANDROID_API:-25}"; [ "$TARGET" = riscv64-linux-android ] && API=35
    TC="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    CC="$TC/bin/${TARGET}${API}-clang"; CXX="${CC}++"
    AR="$TC/bin/llvm-ar"; RANLIB="$TC/bin/llvm-ranlib"; STRIP="$TC/bin/llvm-strip"
    OBJCOPY="$TC/bin/llvm-objcopy"; LD="$TC/bin/ld"
    TRIPLE="${TARGET}${API}"; LDFLAGS="-static-libstdc++"
    ;;
  linux)   # gnu + musl, via the zig-as-llvm wrapper (on PATH in the image)
    CC=cc; CXX=c++; AR=ar; RANLIB=ranlib; STRIP=strip; OBJCOPY=objcopy; LD=ld
    case "$TARGET" in
      *musl*) CFLAGS="-static"; LDFLAGS="-static"
              # patch zig's musl sources (tmpfile/tmpnam/faccessat) if present
              [ -d "$PATCHES_DIR/musl/zig" ] && cp -R "$PATCHES_DIR/musl/zig/." "$(dirname "$(command -v zig)")/" || true ;;
      *)      LDFLAGS="-static-libstdc++ -static-libgcc" ;;
    esac
    ;;
  bsd)     # via zig-as-llvm; CMAKE_SYSTEM_NAME from the OS field of the triple
    CC=cc; CXX=c++; AR=ar; RANLIB=ranlib; STRIP=strip; OBJCOPY=objcopy; LD=ld
    case "$(echo "$TARGET" | cut -d- -f2)" in
      freebsd) SYSTEM_NAME=FreeBSD ;;
      netbsd)  SYSTEM_NAME=NetBSD ;;
      openbsd) SYSTEM_NAME=OpenBSD ;;
    esac
    LDFLAGS="-static-libstdc++"
    ;;
  windows) # via llvm-mingw (on PATH in the image)
    CC="${TARGET}-clang"; CXX="${TARGET}-clang++"; AR="${TARGET}-ar"
    RANLIB="${TARGET}-ranlib"; STRIP="${TARGET}-strip"; OBJCOPY="${TARGET}-objcopy"; LD="${TARGET}-ld"
    SYSTEM_NAME=Windows; LDFLAGS="-static-libstdc++ -static-libgcc -pthread"
    ;;
  *) echo "Unknown PLATFORM='$PLATFORM'" >&2; exit 1 ;;
esac
export CC CXX AR RANLIB STRIP OBJCOPY LD

# --- zlib + zstd (static, bundled) -----------------------------------------
mkdir -p "$INSTALL_DIR" "$BUILD_DIR"
if [ ! -f "$INSTALL_DIR/lib/libz.a" ]; then
  log "Building zlib"
  curl -sSfL https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.xz | xz -d | tar -x -C "$ROOTDIR"
  ( cd "$ROOTDIR/zlib-1.3.1" && CFLAGS="$CFLAGS" ./configure --prefix="$INSTALL_DIR" --static && make -j"$(nproc)" install )
fi
if [ ! -f "$INSTALL_DIR/lib/libzstd.a" ]; then
  log "Building zstd"
  curl -sSfL https://github.com/facebook/zstd/archive/refs/tags/v1.5.6.tar.gz | gzip -d | tar -x -C "$ROOTDIR"
  cmake -S "$ROOTDIR/zstd-1.5.6/build/cmake" -B "$BUILD_DIR/zstd" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_ASM_COMPILER="$CC" \
    -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB" -DCMAKE_STRIP="$STRIP" \
    -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_CROSSCOMPILING=True -DCMAKE_SYSTEM_NAME="$SYSTEM_NAME" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=OFF \
    -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_CONTRIB=OFF -DZSTD_MULTITHREAD_SUPPORT=ON
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
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_ASM_COMPILER="$CC"
  -DCMAKE_LINKER="$LD" -DCMAKE_AR="$AR" -DCMAKE_RANLIB="$RANLIB"
  -DCMAKE_OBJCOPY="$OBJCOPY" -DCMAKE_STRIP="$STRIP"
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS"
  -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS"
  -DLLVM_ENABLE_PROJECTS="$PROJECTS"
  -DLLVM_ENABLE_ZLIB=FORCE_ON -DLLVM_ENABLE_ZSTD=FORCE_ON -DLLVM_USE_STATIC_ZSTD=ON
  -DLLVM_BUILD_STATIC=OFF -DBUILD_SHARED_LIBS=OFF -DLLVM_LINK_LLVM_DYLIB=OFF
  -DLIBCLANG_BUILD_STATIC=ON -DCLANG_ENABLE_ARCMT=OFF -DCMAKE_SKIP_INSTALL_RPATH=TRUE
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_BUILD_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_BUILD_EXAMPLES=OFF
  -DLLVM_BUILD_TESTS=OFF -DLLVM_INCLUDE_TESTS=OFF
  -DCLANG_INCLUDE_TESTS=OFF -DCLANG_BUILD_TESTS=OFF -DLLVM_BUILD_TOOLS=ON
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
[ -n "$CFLAGS" ] && args+=(-DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_CXX_FLAGS="$CFLAGS")

log "Configuring LLVM for $TARGET ($PLATFORM)"
cmake -S "$SRC/llvm" -B "$BUILD_DIR" -G Ninja "${args[@]}"
log "Building + installing"
cmake --build "$BUILD_DIR" --target install

# strip installed binaries (llvm-strip is format-agnostic: ELF/PE/Mach-O)
find "$OUT/bin" -type f ! -lname '*' -exec "$STRIP" -s {} + 2>/dev/null || true
log "Done -> $OUT"
