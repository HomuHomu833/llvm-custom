#!/usr/bin/env bash
# Thin wrapper: download the NDK, resolve the matching llvm-project revision,
# fetch that source, and apply the android + global (+ per-patchset) patches.
# Writes $ROOTDIR/.build-env for build.sh to source.
#
#   NDK_VERSION   required (e.g. 26)
#   NDK_REVISION  optional, appended verbatim to r<version> (e.g. d, b-beta1,
#                 -rc1); use the spelling Google publishes
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

NDK_RELEASE="r${NDK_VERSION}${NDK_REVISION}"
NDK_NAME="android-ndk-$NDK_RELEASE"
NDK_DIR="$ROOTDIR/$NDK_NAME"
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

# Google has published the same archive under -linux.zip and -linux-x86_64.zip
# depending on the release (r21/r22 use -linux-x86_64.zip, r23 and later
# -linux.zip). Ask for both spellings instead of inferring one from our own
# release names.
ndk_url() {
  local base="https://dl.google.com/android/repository/$NDK_NAME" u
  for u in "$base-linux.zip" "$base-linux-x86_64.zip"; do
    if aria2c --dry-run=true --console-log-level=error --check-certificate=false \
               --max-tries=1 --connect-timeout=15 "$u" >/dev/null 2>&1; then
      printf '%s\n' "$u"; return 0
    fi
  done
  return 1
}

if [ ! -d "$NDK_DIR" ]; then
  log "Downloading NDK $NDK_RELEASE"
  NDK_URL=$(ndk_url) || { echo "no NDK $NDK_RELEASE archive at dl.google.com" >&2; exit 1; }
  # The top-level directory does not always match the requested revision:
  # r24-rc1 unpacks as android-ndk-r24-beta3. Remember what was already there
  # so another NDK in ROOTDIR cannot be mistaken for this one.
  _ndk_before=$(find "$ROOTDIR" -maxdepth 1 -mindepth 1 -type d -name 'android-ndk-*' -printf '%f\n' | sort)
  fetch_unpack "$NDK_URL" "$ROOTDIR/android-ndk.zip" "$ROOTDIR"
  if [ ! -d "$NDK_DIR" ]; then
    _ndk_new=$(comm -13 <(printf '%s\n' "$_ndk_before") \
      <(find "$ROOTDIR" -maxdepth 1 -mindepth 1 -type d -name 'android-ndk-*' -printf '%f\n' | sort) | head -n1)
    [ -n "$_ndk_new" ] || _ndk_new=$(find "$ROOTDIR" -maxdepth 1 -mindepth 1 -type d -name 'android-ndk-*' -printf '%f\n' | head -n1)
    [ -n "$_ndk_new" ] || { echo "no android-ndk-* directory unpacked under $ROOTDIR" >&2; exit 1; }
    NDK_DIR="$ROOTDIR/$_ndk_new"
    log "Archive unpacked as $_ndk_new"
    NDK_LLVM="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64"
    CLANG_SOURCE_INFO="$NDK_LLVM/clang_source_info.md"
  fi
fi

ver_line=$("$NDK_LLVM/bin/clang" --version)
LLVM_VERSION=$(echo "$ver_line" | sed -n 's/.*clang version \([0-9][0-9.]*[a-zA-Z0-9]*\).*/\1/p')
LLVM_REV=$(echo "$ver_line" | sed -n -E 's/.*llvm-project ([a-f0-9]{40}).*/\1/p' | head -n1)
# r20 and older predate the llvm-project monorepo: their version string names
# toolchain/llvm and toolchain/clang separately. Keep the llvm revision as the
# key (it is what profiles and patches are named after) and fetch the split
# clang repo alongside it.
SPLIT_LLVM_REV=$(echo "$ver_line" | sed -n -E 's/.*toolchain\/llvm ([a-f0-9]{40}).*/\1/p' | head -n1)
SPLIT_CLANG_REV=$(echo "$ver_line" | sed -n -E 's/.*toolchain\/clang ([a-f0-9]{40}).*/\1/p' | head -n1)
if [ -z "$LLVM_REV" ] && [ -n "$SPLIT_LLVM_REV" ]; then
  LLVM_REV="$SPLIT_LLVM_REV"
fi
LLVM_ANDROID_REPO="https://android.googlesource.com/toolchain/llvm_android"
# The "based on <release>" half of the vendor string, read from the NDK's own
# AndroidVersion.txt so ours says "based on r574158c" exactly like Google's
# instead of a 40-char sha. It stays empty when Google's file has no such line,
# and build.sh then leaves the phrase out too.
CLANG_RELEASE=$(sed -n 's/^based on \(.*\)$/\1/p' "$NDK_LLVM/AndroidVersion.txt" 2>/dev/null | tr -d '\r' | head -n1)
BASE_REV=$(printf '%s\n' "$CLANG_RELEASE" | sed -n 's/^r\([0-9][0-9]*[a-z0-9]*\)$/\1/p')

ANDROID_REV=""
if [ -f "$CLANG_SOURCE_INFO" ]; then
  ANDROID_REV=$(grep 'llvm_android/+/.*' "$CLANG_SOURCE_INFO" | sed -n 's/.*llvm_android\/\+//; s/\/patches.*//p' | sed 's/\/\+//g; s/^\+//g' | head -n1)
fi
if [ -z "$ANDROID_REV" ] && [ -n "$BASE_REV" ] && [ -z "$SPLIT_LLVM_REV" ]; then
  # r21-r23 predate clang_source_info.md. Their llvm_android branch is named
  # after the llvm revision, but not always with the exact suffix Google's
  # AndroidVersion.txt carries: r399163b1 lives on llvm-r399163b, while
  # r365631c3 and r416183c1 live on llvm-r365631 and llvm-r416183. Try the
  # full revision, then without its trailing point-release number, then
  # without the letter suffix, asking googlesource which ref exists.
  _cands=("llvm-r$BASE_REV")
  case "$BASE_REV" in
    *[a-z]*[0-9]) _cands+=("llvm-r${BASE_REV%[0-9]}") ;;
  esac
  _cands+=("llvm-r${BASE_REV%%[a-z]*}")
  for c in "${_cands[@]}"; do
    if git ls-remote --exit-code --heads "$LLVM_ANDROID_REPO" "refs/heads/$c" >/dev/null 2>&1; then
      ANDROID_REV="refs/heads/$c"; break
    fi
  done
fi
[ -n "$LLVM_VERSION" ] && [ -n "$LLVM_REV" ] || {
  echo "Failed to resolve LLVM/android versions from the NDK" >&2; exit 1; }
if [ -z "$SPLIT_LLVM_REV" ]; then
  [ -n "$ANDROID_REV" ] || {
    echo "Failed to resolve the llvm_android revision from the NDK" >&2; exit 1; }
  log "LLVM $LLVM_VERSION ($LLVM_REV) / llvm_android $ANDROID_REV${CLANG_RELEASE:+ / based on $CLANG_RELEASE}"
else
  [ -n "$SPLIT_CLANG_REV" ] || {
    echo "Split LLVM source has no clang revision in the NDK version string" >&2; exit 1; }
  log "LLVM $LLVM_VERSION ($LLVM_REV) / clang $SPLIT_CLANG_REV (split source)${CLANG_RELEASE:+ / based on $CLANG_RELEASE}"
fi

if [ -n "$SPLIT_LLVM_REV" ]; then
  if [ ! -d "$SRC/llvm" ] || [ ! -d "$SRC/clang" ]; then
    log "Fetching split LLVM/clang source"
    rm -rf "$SRC"
    mkdir -p "$SRC"
    git_fetch "https://android.googlesource.com/toolchain/llvm" "$SPLIT_LLVM_REV" "$SRC/llvm"
    git_fetch "https://android.googlesource.com/toolchain/clang" "$SPLIT_CLANG_REV" "$SRC/clang"
    # the version string names only llvm and clang; the rest are pinned in the
    # NDK's repo manifest (r20 has no polly)
    for _p in lld clang-tools-extra polly compiler-rt; do
      _rev=$(sed -n "s|.*name=\"toolchain/$_p\".*revision=\"\([0-9a-f]\{40\}\)\".*|\1|p" "$NDK_LLVM"/manifest_*.xml 2>/dev/null | head -n1)
      if [ -n "$_rev" ]; then git_fetch "https://android.googlesource.com/toolchain/$_p" "$_rev" "$SRC/$_p"; fi
    done
  fi
elif [ ! -d "$SRC" ]; then
  log "Fetching llvm-project source"
  rm -rf "$SRC"
  git_fetch "https://android.googlesource.com/toolchain/llvm-project" "$LLVM_REV" "$SRC"
fi

# Make $SRC its own git repo so `git apply` resolves against it, not an outer
# /work/.git (which would silently no-op the patches).
git init -q "$SRC"

if [ -n "$SPLIT_LLVM_REV" ]; then
  # r20 predates llvm_android's per-release branches; its toolchain/llvm and
  # toolchain/clang trees already carry the Android changes. The targets are
  # the LLVM 8 set from that build (build.py's STAGE2_TARGETS).
  LLVM_TARGETS="AArch64;ARM;BPF;X86"
  log "r${NDK_VERSION}: split LLVM source, skipping llvm_android patches"
else
  log "Applying llvm_android patches"
  git_fetch "$LLVM_ANDROID_REPO" "$ANDROID_REV" "$ROOTDIR/llvm_android"
  PATCH_JSON="$ROOTDIR/llvm_android/patches/PATCHES.json"
  SVN_REV="${BASE_REV%%[a-z]*}"
  if [ ! -d "$ROOTDIR/llvm_android/patches" ]; then
    # r21's llvm_android predates patch management; there is nothing to apply.
    log "llvm_android $ANDROID_REV has no patches/, skipping android patches"
    PATCHES=()
  elif [ ! -f "$PATCH_JSON" ]; then
    echo "no $PATCH_JSON in llvm_android $ANDROID_REV" >&2; exit 1
  else
    command -v python3 >/dev/null || { echo "python3 is required to read PATCHES.json" >&2; exit 1; }
    if [ -z "$SVN_REV" ]; then
      for f in "$ROOTDIR/llvm_android/src/llvm_android/android_version.py" \
               "$ROOTDIR/llvm_android/android_version.py"; do
        [ -f "$f" ] || continue
        SVN_REV=$(sed -n "s/^[a-z_]*svn_revision = 'r\([0-9][0-9]*\).*/\1/p" "$f" | head -n1)
        [ -n "$SVN_REV" ] && break
      done
    fi
    [ -n "$SVN_REV" ] || { echo "Failed to resolve the llvm revision for $ANDROID_REV" >&2; exit 1; }
    mapfile -t PATCHES < <(python3 -c 'import json, sys
svn = int(sys.argv[2])
for p in json.load(open(sys.argv[1])):
    r = p.get("version_range") or {}
    start = r.get("from", p.get("start_version")) or 0
    end = r.get("until", p.get("end_version"))
    if start <= svn and (end is None or svn < end):
        print(p["rel_patch_path"])' "$PATCH_JSON" "$SVN_REV")
  fi
  for p in "${PATCHES[@]:-}"; do
    [ -n "$p" ] || continue
    f="$ROOTDIR/llvm_android/patches/$p"
    [ -f "$f" ] && git -C "$SRC" apply "$f" 2>/dev/null || true
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
  if [ -z "${LLVM_TARGETS:-}" ]; then
    # r21 predates constants.py; Google's list lived in build.py as
    # STAGE2_TARGETS there and reads 'AArch64;ARM;BPF;X86'.
    c="$ROOTDIR/llvm_android/build.py"
    [ -f "$c" ] && LLVM_TARGETS=$(sed -n "s/^STAGE2_TARGETS = '\(.*\)'/\1/p" "$c" | head -n1)
  fi

  rm -rf "$ROOTDIR/llvm_android"
fi
[ -n "${LLVM_TARGETS:-}" ] || {
  echo "Failed to read the target list from llvm_android $ANDROID_REV" >&2; exit 1; }
log "Targets: $LLVM_TARGETS"

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
  # ItaniumDemangle.h uses std::is_pod but only got <type_traits> through
  # <utility>/<numeric>; newer libc++ no longer includes it transitively.
  add_include llvm/include/llvm/Demangle/ItaniumDemangle.h \
              '\(LLVM_\)\?DEMANGLE_ITANIUMDEMANGLE_H' type_traits
  # MicrosoftDemangleNodes.h up to LLVM 13 uses uint*_t and std::string but
  # only gets <cstdint>/<string> transitively; GCC 13's libstdc++ no longer
  # provides either. The guard moved from LLVM_SUPPORT_* to LLVM_DEMANGLE_*.
  add_include llvm/include/llvm/Demangle/MicrosoftDemangleNodes.h \
              '.*MICROSOFTDEMANGLENODES_H' cstdint
  add_include llvm/include/llvm/Demangle/MicrosoftDemangleNodes.h \
              '.*MICROSOFTDEMANGLENODES_H' string
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

# llvm-profdata 9/10 auto-detects (inputs + 1) / 2 merge threads, then cycles
# the writer contexts without waiting for the previous input using one. With
# three profraw files the third races the first and merge segfaults. Force the
# serial path; the merge is small and the indexed profile is unchanged.
_perf_helper="$SRC/clang/utils/perf-training/perf-helper.py"
if [ -f "$_perf_helper" ] &&
   grep -Fq "cmd = [args[0], 'merge', '-o', args[1]]" "$_perf_helper"; then
  sed -i "s/cmd = \[args\[0\], 'merge', '-o', args\[1\]\]/cmd = [args[0], 'merge', '-num-threads=1', '-o', args[1]]/" "$_perf_helper"
  log "profdata: forcing one llvm-profdata merge thread"
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
