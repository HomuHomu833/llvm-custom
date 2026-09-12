#!/usr/bin/env bash
# Thin wrapper: download the NDK, resolve the matching llvm-project revision,
# fetch that source, and apply the android + global (+ per-patchset) patches.
# Writes $ROOTDIR/.build-env for build.sh to source.
#
#   NDK_VERSION   required (e.g. 26)
#   NDK_REVISION  optional (e.g. d)
#   PLATFORM      optional (bionic|linux|bsd|windows|macos); picks the default patch set
#                 and the bionic-only source fixups
#   PATCHSET      optional extra patch dir under patches/ (e.g. musl); overrides
#                 the PLATFORM-based default
#   ROOTDIR       work dir (default: cwd)
set -euo pipefail

ROOTDIR="${ROOTDIR:-$PWD}"
: "${NDK_VERSION:?set NDK_VERSION}"
NDK_REVISION="${NDK_REVISION:-}"
# The musl patch set carries source fixes every zig-built target needs (linux +
# bsd); bionic/windows/macos don't use it.
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

if [ ! -d "$NDK_DIR" ]; then
  log "Downloading NDK r${NDK_VERSION}${NDK_REVISION}"
  fetch_unpack "https://dl.google.com/android/repository/android-ndk-r${NDK_VERSION}${NDK_REVISION}-linux.zip" \
    "$ROOTDIR/android-ndk.zip" "$ROOTDIR"
  # r24-rc1 and r26-rc1 unpack to android-ndk-r24-beta3/ and -r26-beta2/, not to
  # the revision we asked for. Take what landed.
  if [ ! -d "$NDK_DIR" ]; then
    NDK_DIR="$(find "$ROOTDIR" -maxdepth 1 -mindepth 1 -type d -name 'android-ndk-*' | head -n1)"
    [ -n "$NDK_DIR" ] || { echo "no android-ndk-* directory unpacked under $ROOTDIR" >&2; exit 1; }
    log "Archive unpacked as $(basename "$NDK_DIR")"
    NDK_LLVM="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    CLANG_SOURCE_INFO="$NDK_LLVM/clang_source_info.md"
  fi
fi

ver_line=$("$NDK_LLVM/bin/clang" --version)
LLVM_VERSION=$(echo "$ver_line" | sed -n 's/.*clang version \([0-9][0-9.]*[a-zA-Z0-9]*\).*/\1/p')
LLVM_REV=$(echo "$ver_line" | sed -E 's/.*llvm-project ([a-f0-9]{40}).*/\1/' | head -n1)
ANDROID_REV=$(grep 'llvm_android/+/.*' "$CLANG_SOURCE_INFO" | sed -n 's/.*llvm_android\/\+//; s/\/patches.*//p' | sed 's/\/\+//g; s/^\+//g' | head -n1)
# CLANG_VENDOR, lifted whole from the official clang so ours reports the same
# source drop: "Android (<build id>, based on <revision>)". llvm_android builds
# it from its own build number and svn revision, neither of which we have, but
# the string is right there in the binary we already ran.
CLANG_VENDOR=$(echo "$ver_line" | sed -n 's/^\(Android ([^)]*)\).*/\1/p' | head -n1)
[ -n "$LLVM_VERSION" ] && [ -n "$LLVM_REV" ] && [ -n "$ANDROID_REV" ] || {
  echo "Failed to resolve LLVM/android versions from the NDK" >&2; exit 1; }
log "LLVM $LLVM_VERSION ($LLVM_REV) / llvm_android $ANDROID_REV"
log "Vendor: ${CLANG_VENDOR:-Android}"

if [ ! -d "$SRC" ]; then
  log "Fetching llvm-project source"
  rm -rf "$SRC"
  fetch_unpack "https://android.googlesource.com/toolchain/llvm-project/+archive/$LLVM_REV.tar.gz" \
    "$SRC.tar.gz" "$SRC"
fi

# Make $SRC its own git repo so `git apply` resolves against it, not an outer
# /work/.git (which would silently no-op the patches).
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

# Take the backend list from the same llvm_android revision rather than pinning
# our own: it grew RISCV and WebAssembly between r25 and r26, and would have
# gone stale again. The file moved under src/ along the way; the declaration
# itself has been one line throughout.
for c in "$ROOTDIR/llvm_android/src/llvm_android/constants.py" "$ROOTDIR/llvm_android/constants.py"; do
  [ -f "$c" ] || continue
  LLVM_TARGETS=$(sed -n 's/^ANDROID_TARGETS.*set(\[\(.*\)\]).*/\1/p' "$c" | head -n1 | tr -d " '" | tr ',' ';')
  [ -n "$LLVM_TARGETS" ] && break
done
[ -n "${LLVM_TARGETS:-}" ] || {
  echo "Failed to read ANDROID_TARGETS from llvm_android $ANDROID_REV" >&2; exit 1; }
log "Targets: $LLVM_TARGETS"

rm -rf "$ROOTDIR/llvm_android"

apply_set() {
  local dir="$1" strict="$2" p
  [ -d "$dir" ] || { log "no $strict patches for $(basename "$dir")"; return 0; }
  for p in "$dir"/*.patch; do
    [ -f "$p" ] || continue
    if [ "$strict" = strict ]; then
      log "patch: $(basename "$p")"
      git -C "$SRC" apply "$p"
    elif git -C "$SRC" apply --check "$p" 2>/dev/null; then
      log "patch: $(basename "$p")"
      git -C "$SRC" apply "$p"
    else
      log "patch: $(basename "$p") -- skipped, does not apply to this revision"
    fi
  done
}
# Keyed by $LLVM_REV, not $LLVM_VERSION: the version string is not unique per
# source tree (r29 and r30 both say 21.0.0, off branch points three months
# apart), and several strings share one tree (18.0.1-18.0.4 are all d8003a45).
[ -n "${PATCHSET:-}" ] && apply_set "$PATCHES_DIR/$PATCHSET/llvm/$LLVM_REV" loose
apply_set "$PATCHES_DIR/global/llvm/$LLVM_REV" strict

# Newer toolchains stopped providing includes that LLVM <= 14 relied on getting
# transitively. GCC 13 (the ubuntu-24.04 host compiler) dropped <cstdint>, which
# breaks the NATIVE host stage:
#   Signals.h:119:24: error: 'uintptr_t' was not declared in this scope
# llvm-mingw's libc++ splits <exception> into granular headers, which breaks the
# demangler for every mingw target:
#   Utility.h:40:9: error: no member named 'terminate' in namespace 'std'
# Only r25 and older ship an LLVM predating the upstream fixes. Done with sed
# rather than patches/ because these span several source revisions and a
# patch that does not apply is a hard failure under apply_set's strict mode.
# Not gated on PLATFORM -- every platform cross-compiles, so every platform
# builds NATIVE.
NDK_MAJOR=""
case "$NDK_VERSION" in
  ''|*[!0-9]*) ;;
  *) NDK_MAJOR="$NDK_VERSION" ;;
esac

if [ -n "$NDK_MAJOR" ] && [ "$NDK_MAJOR" -le 25 ]; then
  log "r${NDK_VERSION}: adding includes newer toolchains no longer provide"
  # Insert after the include guard so it lands ahead of every other include.
  # GUARD is a sed address, so it may be a pattern rather than a literal name.
  add_include() {
    local rel="$1" guard="$2" hdr="$3" f="$SRC/$1"
    if [ ! -f "$f" ]; then return 0; fi
    if grep -q "^#include <${hdr}>" "$f"; then return 0; fi
    sed -i "/^#define ${guard}$/a #include <${hdr}>" "$f"
    if grep -q "^#include <${hdr}>" "$f"; then log "  + <${hdr}> -> $rel"; fi
  }
  add_include llvm/include/llvm/Support/Signals.h LLVM_SUPPORT_SIGNALS_H cstdint
  # std::terminate is called from the demangler's headers and its .cpp files
  # alike; Utility.h sits on all of their include paths. Match the guard by
  # pattern -- the LLVM_ prefix came and went across these revisions.
  add_include llvm/include/llvm/Demangle/Utility.h \
              '\(LLVM_\)\?DEMANGLE_UTILITY_H' exception
  add_include llvm/include/llvm/Demangle/ItaniumDemangle.h \
              '\(LLVM_\)\?DEMANGLE_ITANIUMDEMANGLE_H' exception
  # std::error_code in the atom-based lld/Core, which LLVM 17 deleted -- so this
  # one is r25-only rather than merely r25-first.
  add_include lld/include/lld/Core/File.h LLD_CORE_FILE_H system_error
  # sancov: createOrDie takes an ArrayRef<std::string>, and {{ClBlacklist}}
  # copy-initializes a std::string from the cl::opt through an explicit ctor,
  # which newer libc++ rejects ("chosen constructor is explicit in
  # copy-initialization"). Name the value outright. Renamed to ClIgnorelist
  # later, so handle both spellings.
  _sancov="$SRC/llvm/tools/sancov/sancov.cpp"
  if [ -f "$_sancov" ]; then
    sed -i -e 's@createOrDie({{ClBlacklist}}@createOrDie({ClBlacklist.getValue()}@' \
           -e 's@createOrDie({{ClIgnorelist}}@createOrDie({ClIgnorelist.getValue()}@' \
           "$_sancov"
    if grep -q 'createOrDie({Cl[A-Za-z]*\.getValue()}' "$_sancov"; then
      log "  + sancov createOrDie explicit-ctor fix"
    fi
  fi
fi

# bionic: gate llvm-rtdyld's x86_64/ELF/linux fast path on !__ANDROID__ (it
# doesn't compile for Android).
if [ "${PLATFORM:-}" = bionic ]; then
  log "bionic: guarding llvm-rtdyld x86_64 ELF block on !__ANDROID__"
  sed -i -E '/^#if defined\(__x86_64__\) && defined\(__ELF__\)( && defined\(__linux__\))?$/ {
    /&& !defined\(__ANDROID__\)/! s/$/ \&\& !defined(__ANDROID__)/
  }' "$SRC/llvm/tools/llvm-rtdyld/llvm-rtdyld.cpp" || true
fi

# windows: don't build bolt_rt, the runtime BOLT injects into instrumented
# binaries. It includes <sys/mman.h> and its syscall wrappers use x86 "=a" asm
# constraints, so mingw cannot compile it -- x86_64 trips on the header,
# arm64ec on the constraint, and install.util follows them down.
#
# Before LLVM 16 the decision reads the *builder's* CPU, not the target:
#
#   set(BOLT_ENABLE_RUNTIME OFF)
#   if (CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "x86_64")
#     set(BOLT_ENABLE_RUNTIME ON)
#   endif()
#
# which is always true on a GitHub runner however we are cross-compiling. It is
# a plain set(), not a cached option(), so -DBOLT_ENABLE_RUNTIME=OFF is
# silently overwritten -- flip the assignment instead. Everything guarded by it
# (the ExternalProject, its install(CODE) and install-bolt_rt) is inside the
# same if/endif, so nothing is left dangling. Newer trees gate on the target
# and never set it here, where this is simply inert.
if [ "${PLATFORM:-}" = windows ] && [ -f "$SRC/bolt/CMakeLists.txt" ]; then
  sed -i 's@set(BOLT_ENABLE_RUNTIME ON)@set(BOLT_ENABLE_RUNTIME OFF)@' \
    "$SRC/bolt/CMakeLists.txt"
  if ! grep -q 'set(BOLT_ENABLE_RUNTIME ON)' "$SRC/bolt/CMakeLists.txt"; then
    log "windows: bolt_rt disabled (BOLT_ENABLE_RUNTIME forced off)"
  fi
fi

# BOLT installs its binaries by bare name, so the install step cannot find them
# wherever executables carry a suffix:
#   file INSTALL cannot find ".../bin/llvm-bolt": No such file or directory
# Append CMAKE_EXECUTABLE_SUFFIX, which is empty on every other platform, so
# this is safe to run unconditionally. Newer trees carry the same change as a
# patch; LLVM 14 lists one binary more than they do (llvm-bolt-heatmap), which
# matching the whole line rather than each name handles on its own.
for _f in bolt/tools/driver/CMakeLists.txt bolt/tools/merge-fdata/CMakeLists.txt; do
  if [ -f "$SRC/$_f" ]; then
    sed -i 's@^\([[:space:]]*\${CMAKE_BINARY_DIR}/bin/[A-Za-z0-9_-]\{1,\}\)$@\1${CMAKE_EXECUTABLE_SUFFIX}@' \
      "$SRC/$_f"
    if grep -q 'CMAKE_EXECUTABLE_SUFFIX' "$SRC/$_f"; then
      log "  + exe suffix on BOLT installs -> $_f"
    fi
  fi
done

cat > "$ROOTDIR/.build-env" <<EOF
LLVM_VERSION=$LLVM_VERSION
CLANG_VENDOR='$CLANG_VENDOR'
LLVM_TARGETS='$LLVM_TARGETS'
SRC=$SRC
NDK_DIR=$NDK_DIR
EOF
log "Source ready at $SRC"
