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
#   ENABLE_PGO    1 (default) looks for a published profile for this llvm rev
#   PGO_URL_BASE  base URL the profile assets live under; without it PGO is off
#   ENABLE_MLGO   1 (default) downloads the arm64 MLGO models
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
# archives on the fly, such as codeload, stream them chunked with
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
    [ "$i" -ge 8 ] && { echo "fetch_unpack: $url still incomplete after $i attempts" >&2; return 1; }
    echo "fetch_unpack: $(basename "$archive") came down incomplete, retry $i/8 in $((15 * i))s..." >&2
    sleep $((15 * i))
  done
}

# Check out REF of REPO into DEST, or only SUBDIR of it when SUBDIR is given.
# gitiles builds its +archive tarballs on the fly and streams them with no
# Content-Length, so a short read arrives as a silent truncation that only
# surfaces at unpack time; a packfile carries its own checksum and a bad
# transfer fails on the spot. SUBDIR pulls trees without blobs and checks out
# sparsely, so a path inside a huge repo costs megabytes instead of gigabytes.
# DEST is left without a .git. Usage: git_fetch REPO REF DEST [SUBDIR]
git_fetch() {
  local repo="$1" ref="$2" dest="$3" sub="${4:-}" work="$3" filter="" i=0
  [ -n "$sub" ] && { work="$dest.gitsrc"; filter="--filter=blob:none"; }
  rm -rf "$work" "$dest"
  git init -q "$work"
  git -C "$work" remote add origin "$repo"
  if [ -n "$sub" ]; then
    git -C "$work" config core.sparseCheckout true
    printf '/%s/*\n' "$sub" > "$work/.git/info/sparse-checkout"
  fi
  until git -C "$work" fetch -q --depth 1 $filter origin "$ref"; do
    i=$((i + 1))
    [ "$i" -ge 5 ] && { echo "git_fetch: $repo $ref failed after $i attempts" >&2; return 1; }
    echo "git_fetch: $repo $ref failed, retry $i/5 in $((5 * i))s..." >&2
    sleep $((5 * i))
  done
  git -C "$work" checkout -q FETCH_HEAD
  rm -rf "$work/.git"
  if [ -n "$sub" ]; then
    mkdir -p "$dest"
    cp -a "$work/$sub/." "$dest/"
    rm -rf "$work"
  fi
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
[ -n "$LLVM_VERSION" ] && [ -n "$LLVM_REV" ] && [ -n "$ANDROID_REV" ] || {
  echo "Failed to resolve LLVM/android versions from the NDK" >&2; exit 1; }
# The "based on <release>" half of the vendor string, read from the NDK's own
# AndroidVersion.txt so ours says "based on r574158c" exactly like Google's
# instead of a 40-char sha. That file has carried the line since at least r25;
# fall back to the llvm_android commit if a tree ever turns up without it.
CLANG_RELEASE=$(sed -n 's/^based on \(.*\)$/\1/p' "$NDK_LLVM/AndroidVersion.txt" 2>/dev/null | tr -d '\r' | head -n1)
CLANG_RELEASE="${CLANG_RELEASE:-$ANDROID_REV}"
log "LLVM $LLVM_VERSION ($LLVM_REV) / llvm_android $ANDROID_REV / based on $CLANG_RELEASE"

if [ ! -d "$SRC" ]; then
  log "Fetching llvm-project source"
  rm -rf "$SRC"
  git_fetch "https://android.googlesource.com/toolchain/llvm-project" "$LLVM_REV" "$SRC"
fi

# Make $SRC its own git repo so `git apply` resolves against it, not an outer
# /work/.git (which would silently no-op the patches).
git init -q "$SRC"

log "Applying llvm_android patches"
git_fetch "https://android.googlesource.com/toolchain/llvm_android" "$ANDROID_REV" "$ROOTDIR/llvm_android"
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

# LLVM <= 14 (r25 and older) relies on includes newer toolchains no longer pull
# in transitively: GCC 13 dropped <cstdint>, llvm-mingw's libc++ splits
# <exception> and <system_error> into granular headers. sed rather than
# patches/, since these span both r25 source revisions.
NDK_MAJOR=""
case "$NDK_VERSION" in
  ''|*[!0-9]*) ;;
  *) NDK_MAJOR="$NDK_VERSION" ;;
esac

if [ -n "$NDK_MAJOR" ] && [ "$NDK_MAJOR" -le 25 ]; then
  log "r${NDK_VERSION}: adding includes newer toolchains no longer provide"
  # Insert after the include guard. GUARD is a sed address, so it may be a
  # pattern, since the LLVM_ prefix comes and goes across these revisions.
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
  # pattern, since the LLVM_ prefix came and went across these revisions.
  add_include llvm/include/llvm/Demangle/Utility.h \
              '\(LLVM_\)\?DEMANGLE_UTILITY_H' exception
  add_include llvm/include/llvm/Demangle/ItaniumDemangle.h \
              '\(LLVM_\)\?DEMANGLE_ITANIUMDEMANGLE_H' exception
  # std::error_code in the atom-based lld/Core, which LLVM 17 deleted, so this
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

# Same block, same treatment for OpenBSD: LLVMRTDyldTLSSpace is defined with
# initial-exec TLS and referenced from inline asm, and the link there ends in
# "undefined symbol". Only x86_64 reaches it, and only from 14.0.6, which is
# where the block was added. Guarding it costs llvm-rtdyld's TLS section
# support, as it already does on Android.
if [ "${PLATFORM:-}" = bsd ]; then
  log "bsd: guarding llvm-rtdyld x86_64 ELF block on !__OpenBSD__"
  sed -i -E '/^#if defined\(__x86_64__\) && defined\(__ELF__\)( && defined\(__linux__\))?$/ {
    /&& !defined\(__OpenBSD__\)/! s/$/ \&\& !defined(__OpenBSD__)/
  }' "$SRC/llvm/tools/llvm-rtdyld/llvm-rtdyld.cpp" || true
fi

# clang-ast-dump exists only to generate ASTNodeAPI.json, and a cross build never
# runs it: CMAKE_CROSSCOMPILING is in the guard that swaps in
# EmptyNodeIntrospection.inc and forces CLANG_TOOLING_BUILD_AST_INTROSPECTION
# off. The target is added outside that guard though, so it was built and linked
# for the target with nothing consuming it, and on bionic aarch64 that link
# fails: the static binary grows until two libc.a members are 1.9MB apart, past
# the 1MB reach of R_AARCH64_CONDBR19, which lld cannot thunk.
#
# EXCLUDE_FROM_ALL, not dropping the subdirectory. A cross build still spawns a
# NATIVE sub-build over this same tree, that one is not cross-compiling, and it
# takes the generating branch: removing the target left it evaluating
# $<TARGET_FILE:clang-ast-dump> against nothing. Excluded from all it stays
# available to whoever depends on it and out of everyone else's build.
_dump="$SRC/clang/lib/Tooling/DumpTool/CMakeLists.txt"
if [ -f "$_dump" ] && ! grep -q 'EXCLUDE_FROM_ALL' "$_dump"; then
  printf '\nset_target_properties(clang-ast-dump PROPERTIES EXCLUDE_FROM_ALL ON)\n' >> "$_dump"
  log "clang: clang-ast-dump excluded from all, unused in a cross build"
fi

# bolt_rt, the runtime BOLT injects into instrumented binaries, is Linux-only:
# it makes raw Linux syscalls and its osx variant builds -target
# x86_64-apple-darwin, which zig rejects. LLVM 14 enables it off the *builder's*
# CPU with a plain set(), so -DBOLT_ENABLE_RUNTIME=OFF is overwritten. Flip the
# assignment instead. Everything it guards sits in the same if/endif.
case "${PLATFORM:-}" in
  windows|bsd|macos)
    if [ -f "$SRC/bolt/CMakeLists.txt" ]; then
      sed -i 's@set(BOLT_ENABLE_RUNTIME ON)@set(BOLT_ENABLE_RUNTIME OFF)@' \
        "$SRC/bolt/CMakeLists.txt"
      if ! grep -q 'set(BOLT_ENABLE_RUNTIME ON)' "$SRC/bolt/CMakeLists.txt"; then
        log "${PLATFORM}: bolt_rt disabled (BOLT_ENABLE_RUNTIME forced off)"
      fi
    fi ;;
esac

# BOLT installs its binaries by bare name, so the install step cannot find them
# where executables carry a suffix. CMAKE_EXECUTABLE_SUFFIX is empty elsewhere,
# so this needs no platform gate; matching the whole line also covers
# llvm-bolt-heatmap, which only LLVM 14 installs.
for _f in bolt/tools/driver/CMakeLists.txt bolt/tools/merge-fdata/CMakeLists.txt; do
  if [ -f "$SRC/$_f" ]; then
    sed -i 's@^\([[:space:]]*\${CMAKE_BINARY_DIR}/bin/[A-Za-z0-9_-]\{1,\}\)$@\1${CMAKE_EXECUTABLE_SUFFIX}@' \
      "$SRC/$_f"
    if grep -q 'CMAKE_EXECUTABLE_SUFFIX' "$SRC/$_f"; then
      log "  + exe suffix on BOLT installs -> $_f"
    fi
  fi
done

# merge-fdata links with --emit-relocs on any Unix target, for a BOLT test we
# never build, and zig's linker rejects the flag. Upstream gates this on
# BOLT_INCLUDE_TESTS; the android fork does not, so LLVM_INCLUDE_TESTS=OFF does
# not help and the condition has to go.
case "${PLATFORM:-}" in
  linux|bsd)
    _mf="$SRC/bolt/tools/merge-fdata/CMakeLists.txt"
    if [ -f "$_mf" ]; then
      sed -i 's@^if (UNIX AND NOT APPLE)$@if (FALSE) # zig ld has no --emit-relocs@' "$_mf"
      if grep -q 'zig ld has no' "$_mf"; then
        log "${PLATFORM}: dropped merge-fdata --emit-relocs"
      fi
    fi ;;
esac

# --- PGO profile ------------------------------------------------------------
# One profile per llvm-project tree, keyed by $LLVM_REV and shared by every
# target built from it (see build.sh's BUILD_PROFDATA for why one covers all).
# A missing asset just means nobody has profiled this tree yet; build without.
# Seeded from the environment so a caller-supplied profile survives the
# round-trip through .build-env rather than being blanked by the lookup.
LLVM_PROFDATA_FILE="${LLVM_PROFDATA_FILE:-}"
if [ -z "$LLVM_PROFDATA_FILE" ] && [ "${ENABLE_PGO:-1}" = 1 ] && [ -n "${PGO_URL_BASE:-}" ]; then
  _pd="$ROOTDIR/$LLVM_REV.profdata"
  if [ ! -f "$_pd" ]; then
    log "Looking for a PGO profile for $LLVM_REV"
    # One attempt, deliberately not the retrying fetch(): a 404 here is the
    # expected "not profiled yet" answer, not a transient error worth 5 retries.
    aria2c --console-log-level=error --check-certificate=false --max-tries=1 \
           --connect-timeout=15 --allow-overwrite=true --auto-file-renaming=false \
           --dir="$ROOTDIR" -o "$LLVM_REV.profdata.xz" \
           "$PGO_URL_BASE/$LLVM_REV.profdata.xz" >/dev/null 2>&1 || true
    if [ -s "$ROOTDIR/$LLVM_REV.profdata.xz" ]; then
      xz -df "$ROOTDIR/$LLVM_REV.profdata.xz"
    else
      rm -f "$ROOTDIR/$LLVM_REV.profdata.xz"
    fi
  fi
  if [ -f "$_pd" ]; then
    LLVM_PROFDATA_FILE="$_pd"
    log "PGO: using $(basename "$_pd")"
  else
    log "PGO: no profile published for $LLVM_REV, building without"
  fi
fi

# --- MLGO models ------------------------------------------------------------
# The arm64 models, as llvm_android embeds in the toolchain it ships ("Embed
# ARM64 models for optimizing ARM64 AOSP / NDK"): the model is chosen for the
# code clang emits, not the host it runs on, so arm64 fits every host we build.
# Whether a host can AOT-compile them is build.sh's probe to answer.
MLGO_DIR="${MLGO_DIR:-}"
if [ -z "$MLGO_DIR" ] && [ "${ENABLE_MLGO:-1}" = 1 ]; then
  MLGO_DIR="$ROOTDIR/mlgo"
  _have=1
  for _m in inlining-Oz-chromium regalloc-evict-aosp; do
    [ -f "$MLGO_DIR/$_m/saved_model.pb" ] || _have=0
  done
  if [ "$_have" = 0 ]; then
    log "Fetching MLGO models"
    git_fetch "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86" \
      "refs/heads/mirror-goog-main-llvm-toolchain-source" "$MLGO_DIR" "mlgo-models/arm64"
  fi
fi

cat > "$ROOTDIR/.build-env" <<EOF
LLVM_VERSION=$LLVM_VERSION
LLVM_REV=$LLVM_REV
CLANG_RELEASE=$CLANG_RELEASE
LLVM_TARGETS='$LLVM_TARGETS'
LLVM_PROFDATA_FILE='$LLVM_PROFDATA_FILE'
MLGO_DIR='$MLGO_DIR'
SRC=$SRC
NDK_DIR=$NDK_DIR
EOF
log "Source ready at $SRC"
