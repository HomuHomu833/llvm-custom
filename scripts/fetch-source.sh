#!/usr/bin/env bash
# Thin wrapper: download the NDK, resolve the matching llvm-project revision,
# fetch that source, and apply the android + global (+ per-patchset) patches.
# Writes $ROOTDIR/.build-env for build.sh to source.
#
#   NDK_VERSION   required (e.g. 26)
#   NDK_REVISION  optional (e.g. d)
#   PLATFORM      optional (bionic|linux|bsd|windows); picks the default patch set
#                 and the bionic-only source fixups
#   PATCHSET      optional extra patch dir under patches/ (e.g. musl); overrides
#                 the PLATFORM-based default
#   ROOTDIR       work dir (default: cwd)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${NDK_VERSION:?set NDK_VERSION}"
NDK_REVISION="${NDK_REVISION:-}"
# The musl patch set carries source fixes every zig-built target needs (linux +
# bsd); bionic (NDK clang) and windows (llvm-mingw) don't use it. This mirrors
# upstream, which applies patches/musl/llvm in both the musl and bsd workflows.
PATCHSET="${PATCHSET:-}"
if [ -z "$PATCHSET" ]; then
  case "${PLATFORM:-}" in
    linux|bsd) PATCHSET=musl ;;
    "") case "${TARGET:-}" in
          *musl*|*-freebsd-*|*-netbsd-*|*-openbsd-*) PATCHSET=musl ;;
        esac ;;
  esac
fi
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PATCHES_DIR="${PATCHES_DIR:-$SCRIPT_DIR/../patches}"

NDK_DIR="$ROOTDIR/android-ndk-r${NDK_VERSION}${NDK_REVISION}"
NDK_LLVM="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
CLANG_SOURCE_INFO="$NDK_LLVM/clang_source_info.md"
SRC="${SRC:-$ROOTDIR/llvm-project}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

if [ ! -d "$NDK_DIR" ]; then
  log "Downloading NDK r${NDK_VERSION}${NDK_REVISION}"
  curl -sSfL -o "$ROOTDIR/android-ndk.zip" \
    "https://dl.google.com/android/repository/android-ndk-r${NDK_VERSION}${NDK_REVISION}-linux.zip"
  unzip -qq "$ROOTDIR/android-ndk.zip" -d "$ROOTDIR"
  rm -f "$ROOTDIR/android-ndk.zip"
fi

ver_line=$("$NDK_LLVM/bin/clang" --version)
LLVM_VERSION=$(echo "$ver_line" | sed -n 's/.*clang version \([0-9][0-9.]*[a-zA-Z0-9]*\).*/\1/p')
LLVM_REV=$(echo "$ver_line" | sed -E 's/.*llvm-project ([a-f0-9]{40}).*/\1/' | head -n1)
ANDROID_REV=$(grep 'llvm_android/+/.*' "$CLANG_SOURCE_INFO" | sed -n 's/.*llvm_android\/\+//; s/\/patches.*//p' | sed 's/\/\+//g; s/^\+//g' | head -n1)
[ -n "$LLVM_VERSION" ] && [ -n "$LLVM_REV" ] && [ -n "$ANDROID_REV" ] || {
  echo "Failed to resolve LLVM/android versions from the NDK" >&2; exit 1; }
log "LLVM $LLVM_VERSION ($LLVM_REV) / llvm_android $ANDROID_REV"

if [ ! -d "$SRC" ]; then
  log "Fetching llvm-project source"
  mkdir -p "$SRC"
  curl -sSfL "https://android.googlesource.com/toolchain/llvm-project/+archive/$LLVM_REV.tar.gz" | tar -xz -C "$SRC"
fi

# Make $SRC its own git repo. In CI the repo checkout is the mount root (/work)
# and $SRC sits *inside* it, so `git apply` would otherwise discover /work/.git,
# resolve the patch paths against that outer root, and silently no-op with exit
# 0 - patches look applied but the tree is untouched (and strict mode never
# aborts). With a .git here, $SRC is the nearest repo and patches apply for real.
git init -q "$SRC"

log "Applying llvm_android patches"
rm -rf "$ROOTDIR/llvm_android"
git clone --quiet https://android.googlesource.com/toolchain/llvm_android "$ROOTDIR/llvm_android"
git -C "$ROOTDIR/llvm_android" checkout --quiet "$ANDROID_REV"
mapfile -t PATCHES < <(grep -oP 'patches/\S+' "$CLANG_SOURCE_INFO" | sed 's/)$//')
for p in "${PATCHES[@]:-}"; do
  [ -n "$p" ] || continue
  for base in "$ROOTDIR/llvm_android/$p" "$ROOTDIR/llvm_android/cherry/$p"; do
    if [ -f "$base" ]; then git -C "$SRC" apply "$base" 2>/dev/null || true; break; fi
  done
done
rm -rf "$ROOTDIR/llvm_android"

apply_set() {
  local dir="$1" strict="$2" p
  [ -d "$dir" ] || return 0
  for p in "$dir"/*.patch; do
    [ -f "$p" ] || continue
    log "patch: $(basename "$p")"
    if [ "$strict" = strict ]; then git -C "$SRC" apply "$p"; else git -C "$SRC" apply "$p" || true; fi
  done
}
[ -n "${PATCHSET:-}" ] && apply_set "$PATCHES_DIR/$PATCHSET/llvm/$LLVM_VERSION" loose
apply_set "$PATCHES_DIR/global/llvm/$LLVM_VERSION" strict

# bionic: llvm-rtdyld's x86_64/ELF/linux fast path doesn't compile for Android;
# gate it on !__ANDROID__ so the bionic cross build succeeds (mirrors upstream).
if [ "${PLATFORM:-}" = bionic ]; then
  log "bionic: guarding llvm-rtdyld x86_64 ELF block on !__ANDROID__"
  sed -i '/^#if defined(__x86_64__) && defined(__ELF__) && defined(__linux__)$/ {
    /&& !defined(__ANDROID__)/! s/$/ \&\& !defined(__ANDROID__)/
  }' "$SRC/llvm/tools/llvm-rtdyld/llvm-rtdyld.cpp" || true
fi

cat > "$ROOTDIR/.build-env" <<EOF
LLVM_VERSION=$LLVM_VERSION
SRC=$SRC
NDK_DIR=$NDK_DIR
EOF
log "Source ready at $SRC"
