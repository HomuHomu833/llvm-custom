#!/usr/bin/env bash
# Functional test of the Linux builds of HomuHomu833/llvm-custom.
# Each llvm-custom tarball holds only bin/ and headers, so the script lays its bin/ over Google's
# official toolchain of the same NDK release (sysroot, libc++, compiler-rt) and tests it there,
# exactly as our clang would sit in a full NDK. Foreign host architectures run under qemu-user,
# and the produced static Android programs are run under qemu-user too.
#
# Usage: ./test-llvm.sh RELEASE [FILTER]
#   RELEASE  NDK release the LLVM was built for: r20-beta1, r20, r20b, r21e, r24-rc1, ...
#            (assets come from the llvm-r<major> release, e.g. llvm-r20)
#   FILTER   substring of the host triple (e.g. aarch64, riscv64-linux-musl, musleabihf)
# Env:
#   OFFICIAL=1        test Google's own toolchain for RELEASE, unchanged, for comparison
#   WORK=~/llvm-test  working dir          TIMEOUT=120   per-command timeout (s)
#   PRUNE_ARCHIVES=1  delete each .tar.xz after testing it
#   KEEP_EXTRACTED=1  keep each extracted toolchain
#
# Needs: curl python3 tar xz-utils unzip qemu-user      (optional: binutils/readelf for hardening checks)
#   sudo apt install curl python3 xz-utils unzip qemu-user binutils
#
# Per build it tests:
#   toolchain   clang/clang++ cross-compiling to aarch64, armv7a, i686, x86_64 (riscv64 where the
#               sysroot has it) Android: static C, static C++ (exceptions, STL), ThinLTO, shared lib,
#               dynamic exe interpreter -> the static binaries are then RUN under qemu-user
#   llvm tools  ar nm ranlib objdump readobj readelf size strip objcopy cxxfilt dwarfdump symbolizer
#               as dis link profdata cov, clang-format, clang-tidy, clang-scan-deps, ld.lld
#   all ELFs    smoke test (--help) + hardening check (WARN only)
# Tools a release does not ship are INFO and skipped; API levels are capped at the sysroot's highest.
# Skipped on purpose: *-linux-android hosts (need Android/Termux), Windows/macOS/BSD hosts, x32.

set -uo pipefail

REPO="HomuHomu833/llvm-custom"
VER="${1:-}"
[[ -n $VER ]] || { sed -n '2,30p' "$0"; exit 2; }
FILTER="${2:-}"
TAG="llvm-${VER%%[!r0-9]*}"   # r20-beta1 -> llvm-r20, r21e -> llvm-r21
WORK="${WORK:-$HOME/llvm-test}"
OFFICIAL="${OFFICIAL:-0}"
TIMEOUT="${TIMEOUT:-120}"
PRUNE_ARCHIVES="${PRUNE_ARCHIVES:-0}"
KEEP_EXTRACTED="${KEEP_EXTRACTED:-0}"

mkdir -p "$WORK"/{dl,x,run}
RESULTS="$WORK/results-$VER.txt"; : > "$RESULTS"

# host arch -> qemu-user suffix ("native" = run directly)
declare -A QEMU=(
  [x86_64]=native   [x86]=i386
  [arm]=arm         [thumb]=arm        [armeb]=armeb     [thumbeb]=armeb
  [aarch64]=aarch64 [aarch64_be]=aarch64_be
  [riscv32]=riscv32 [riscv64]=riscv64
  [powerpc]=ppc     [powerpc64]=ppc64  [powerpc64le]=ppc64le
  [mips]=mips       [mipsel]=mipsel    [mips64]=mips64   [mips64el]=mips64el
  [loongarch64]=loongarch64 [s390x]=s390x [hexagon]=hexagon
)
# glibc sysroots, key = arch-abi (dynamic glibc builds only; static builds need none)
declare -A SYSROOT=(
  [aarch64-gnu]=/usr/aarch64-linux-gnu          [arm-gnueabihf]=/usr/arm-linux-gnueabihf
  [arm-gnueabi]=/usr/arm-linux-gnueabi          [x86-gnu]=/usr/i686-linux-gnu
  [riscv64-gnu]=/usr/riscv64-linux-gnu          [powerpc64le-gnu]=/usr/powerpc64le-linux-gnu
  [s390x-gnu]=/usr/s390x-linux-gnu              [loongarch64-gnu]=/usr/loongarch64-linux-gnu
  [mips-gnueabihf]=/usr/mips-linux-gnu          [mipsel-gnueabihf]=/usr/mipsel-linux-gnu
  [mips64-gnuabi64]=/usr/mips64-linux-gnuabi64  [mips64el-gnuabi64]=/usr/mips64el-linux-gnuabi64
)
declare -A PKG=(
  [aarch64-gnu]=libc6-arm64-cross  [arm-gnueabihf]=libc6-armhf-cross  [arm-gnueabi]=libc6-armel-cross
  [x86-gnu]=libc6-i386-cross       [riscv64-gnu]=libc6-riscv64-cross  [powerpc64le-gnu]=libc6-ppc64el-cross
  [s390x-gnu]=libc6-s390x-cross    [loongarch64-gnu]=libc6-loong64-cross
  [mips-gnueabihf]=libc6-mips-cross [mipsel-gnueabihf]=libc6-mipsel-cross
  [mips64-gnuabi64]=libc6-mips64-cross [mips64el-gnuabi64]=libc6-mips64el-cross
)

for t in curl python3 tar xz unzip; do
  command -v "$t" >/dev/null || { echo "missing tool: $t"; exit 1; }
done

ok=0; fail=0; warn=0; skip=0; CUR=""
RUNNER=()   # how to run the NDK's own (host) binaries
TR=()       # how to run the produced Android test binaries

log()  { echo "$1" | tee -a "$RESULTS"; }
pass() { log "OK    [$CUR] $1"; ((ok++)); return 0; }
bad()  { log "FAIL  [$CUR] $1 :: $(tr '\n' ' ' <<<"${2:-}" | cut -c1-220)"; ((fail++)); return 0; }
note() { log "WARN  [$CUR] $1"; ((warn++)); return 0; }
info() { log "INFO  [$CUR] $1"; return 0; }
run()  { timeout "$TIMEOUT" "${RUNNER[@]}" "$@"; }
trun() { timeout "$TIMEOUT" "${TR[@]}" "$@"; }

step() {   # step LABEL cmd...   -> pass if rc==0
  local label=$1; shift; local out rc
  out=$("$@" 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then pass "$label"; else bad "$label (rc=$rc)" "$out"; fi
  return $rc
}
expect() { # expect LABEL REGEX cmd...   -> pass if rc==0 and output matches
  local label=$1 pat=$2; shift 2; local out rc
  out=$("$@" 2>&1); rc=$?
  if [[ $rc -eq 0 ]] && grep -qE -- "$pat" <<<"$out"; then pass "$label"
  else bad "$label (rc=$rc, wanted /$pat/)" "$out"; fi
}
magic() {  # magic FILE OFFSET HEX
  python3 -c 'import sys
f,o,h=sys.argv[1:]
d=open(f,"rb"); d.seek(int(o)); sys.exit(0 if d.read(len(h)//2).hex()==h else 1)' "$@"
}

# ---------------------------------------------------------------- fixtures
FIX="$WORK/fixtures"
make_fixtures() {
  rm -rf "$FIX"; mkdir -p "$FIX/proj/jni"
  cat > "$FIX/hello.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
static void *w(void *a){ *(int*)a = 41; return 0; }
int main(void){
  char buf[32]; snprintf(buf,sizeof buf,"%d-%s",6*7,"ok");
  int v=0; pthread_t t; pthread_create(&t,0,w,&v); pthread_join(t,0);
  printf("hello %s v=%d long=%zu ptr=%zu\n",buf,v+1,sizeof(long),sizeof(void*)); return 0; }
EOF
  cat > "$FIX/hello.cpp" <<'EOF'
#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <stdexcept>
#include <map>
int main(){
  std::vector<int> v{5,3,9,1}; std::sort(v.begin(),v.end());
  std::map<std::string,int> m; m["a"]=v[0]+v[3];
  try { throw std::runtime_error("boom"); } catch(const std::exception&e){ std::cout<<"caught "<<e.what()<<" "<<m["a"]<<"\n"; }
  return 0; }
EOF
  echo 'int f(int x){return x*2;}' > "$FIX/lib.c"
  printf 'int  main( ){return 0;}' > "$FIX/fmt.c"
  printf 'section .text\nglobal f\nf: mov eax, 42\n ret\n' > "$FIX/t.asm"
  printf 'all:\n\t@echo made-$(MAKE_VERSION)\n' > "$FIX/Makefile"
  printf '#version 450\nlayout(location=0) in vec3 p;\nvoid main(){ gl_Position=vec4(p,1.0); }\n' > "$FIX/t.vert"
  cat > "$FIX/proj/jni/Android.mk" <<'EOF'
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)
LOCAL_MODULE := hello
LOCAL_SRC_FILES := hello.cpp
include $(BUILD_SHARED_LIBRARY)
EOF
  printf 'APP_ABI := arm64-v8a armeabi-v7a x86 x86_64\nAPP_PLATFORM := android-24\nAPP_STL := c++_shared\n' > "$FIX/proj/jni/Application.mk"
  printf '#include <string>\nextern "C" int answer(){ std::string s="ab"; return (int)s.size()+40; }\n' > "$FIX/proj/jni/hello.cpp"
}

# ---------------------------------------------------------------- hardening (WARN only)
check_hardening() {
  command -v readelf >/dev/null || return 0
  local f=$1 label=$2 missing=() ph dyn syms
  ph=$(readelf -lW "$f" 2>/dev/null)
  grep -q 'GNU_STACK' <<<"$ph" || missing+=("no-GNU_STACK")
  grep -E 'GNU_STACK' <<<"$ph" | grep -qE ' RWE | E ' && missing+=("exec-stack")
  if ! grep -q 'GNU_RELRO' <<<"$ph"; then
    readelf -SW "$f" 2>/dev/null | grep -qE '\.(data\.rel\.ro|init_array|fini_array|preinit_array|got\.plt)' && missing+=("no-RELRO")
  fi
  dyn=$(readelf -dW "$f" 2>/dev/null)
  if [[ -n $dyn ]] && ! grep -q 'no dynamic section' <<<"$dyn"; then
    grep -qE 'BIND_NOW|FLAGS.*NOW' <<<"$dyn" || missing+=("no-BIND_NOW")
  fi
  syms=$(readelf -sW "$f" 2>/dev/null)
  grep -qE '__stack_chk_(fail|guard)' <<<"$syms" || missing+=("no-stack-protector-symbol")
  if [[ ${#missing[@]} -eq 0 ]]; then pass "hardening $label"
  else note "hardening $label :: ${missing[*]}"; fi
}

# ---------------------------------------------------------------- Android target table
TGT=(aarch64 armv7a i686 x86_64 riscv64)
declare -A T_TRIPLE=([aarch64]=aarch64-linux-android [armv7a]=armv7a-linux-androideabi [i686]=i686-linux-android [x86_64]=x86_64-linux-android [riscv64]=riscv64-linux-android)
declare -A T_LIBDIR=([aarch64]=aarch64-linux-android [armv7a]=arm-linux-androideabi [i686]=i686-linux-android [x86_64]=x86_64-linux-android [riscv64]=riscv64-linux-android)
# armv7a at 29: below it, static executables from r22+ abort on bionic's TLS alignment check
declare -A T_API=([aarch64]=30 [armv7a]=29 [i686]=21 [x86_64]=21 [riscv64]=37)   # riscv64 sysroot only ships API 37
declare -A T_LONG=([aarch64]=8 [armv7a]=4 [i686]=4 [x86_64]=8 [riscv64]=8)
declare -A T_MACH=([aarch64]='Machine: +AArch64' [armv7a]='Machine: +ARM$' [i686]='Machine: +Intel 80386' [x86_64]='Machine: +Advanced Micro Devices X86-64' [riscv64]='Machine: +RISC-V')
declare -A T_INTERP=([aarch64]=linker64 [armv7a]=linker [i686]=linker [x86_64]=linker64 [riscv64]=linker64)

# ELF machine name, so a foreign-host smoke test only runs binaries built for that
# host: the official NDK keeps its own helper toolchains in x86_64, whatever host
# we are testing.
elf_machine() { readelf -h "$1" 2>/dev/null | sed -n 's/^ *Machine: *//p' | head -n1; }
host_machine_re() {
  case "$HOST_ARCH" in
    x86_64)                        echo 'X86-64|AMD x86-64' ;;
    x86)                           echo 'Intel 80386' ;;
    aarch64|aarch64_be)            echo 'AArch64' ;;
    arm|armeb|thumb|thumbeb)       echo 'ARM' ;;
    riscv32|riscv64)               echo 'RISC-V' ;;
    powerpc|powerpc64|powerpc64le) echo 'PowerPC' ;;
    mips|mipsel|mips64|mips64el)   echo 'MIPS' ;;
    s390x)                         echo 'IBM S/390' ;;
    loongarch64)                   echo 'LoongArch' ;;
    hexagon)                       echo 'QUALCOMM' ;;
    *)                             echo "$HOST_ARCH" ;;
  esac
}

# sets TR (runner for produced binaries) and returns 1 if the target cannot be run here
target_runner() {
  local a=$1; TR=()
  case $a in
    x86_64) [[ "$(uname -m)" == x86_64 ]] && return 0; TR=(qemu-x86_64) ;;
    i686)   if command -v qemu-i386 >/dev/null; then TR=(qemu-i386); else return 0; fi ;;
    aarch64) TR=(qemu-aarch64) ;;
    armv7a)  TR=(qemu-arm) ;;
    riscv64) TR=(qemu-riscv64) ;;
  esac
  if [[ ${#TR[@]} -gt 0 ]] && ! command -v "${TR[0]}" >/dev/null; then return 1; fi
  # 32-bit bionic packs the tid into a 16-bit field and aborts when getpid()
  # exceeds 65535. qemu-user reports the host pid and hosts (containers, CI)
  # routinely run past that, so give the guest a pid namespace where allowed.
  if [[ $a == i686 || $a == armv7a ]] && command -v unshare >/dev/null &&
     unshare -r -p -f true >/dev/null 2>&1; then
    TR=(unshare -r -p -f --mount-proc "${TR[@]}")
  fi
  return 0
}

# ---------------------------------------------------------------- tests for one extracted NDK
test_ndk() {
  local dir=$1 T="$WORK/run/$TAG-$CUR"
  rm -rf "$T"; mkdir -p "$T"; cp -r "$FIX"/. "$T"/; cd "$T" || return
  local LLVM_ONLY=1

  local NDK sp
  sp=$(find "$dir" -maxdepth 3 -name source.properties 2>/dev/null | head -n1)
  [[ -n $sp ]] || { bad "NDK root (source.properties) not found" ""; return; }
  NDK=$(dirname "$sp")
  find "$NDK" -type f \( -path '*/bin/*' -o -path '*/shader-tools/*' -o -name ndk-build -o -name ndk-which -o -name ndk-stack \) -exec chmod +x {} + 2>/dev/null

  local LLVM PB SH PY
  LLVM=$(echo "$NDK"/toolchains/llvm/prebuilt/*/bin | awk '{print $1}')
  PB=$(echo "$NDK"/prebuilt/*/bin | awk '{print $1}')
  SH=$(echo "$NDK"/shader-tools/* | awk '{print $1}')
  PY=$(echo "$NDK"/toolchains/llvm/prebuilt/*/python3/bin/python3 | awk '{print $1}')
  [[ -d $LLVM ]] || { bad "LLVM bin dir not found under $NDK/toolchains/llvm/prebuilt" ""; return; }
  local CLANG="$LLVM/clang" CLANGXX="$LLVM/clang++"
  l() { echo "$LLVM/$1"; }
  have() { local t; for t in "$@"; do [[ -x $LLVM/$t ]] || { info "$t not shipped in this NDK, its tests skipped"; return 1; }; done; }
  # A foreign-host toolchain has to run under qemu. If even clang --version
  # cannot, nothing below is meaningful (qemu-hexagon segfaults on these).
  if [[ ${#RUNNER[@]} -gt 0 ]]; then
    local _po _prc
    _po=$(run "$CLANG" --version 2>&1); _prc=$?
    if [[ $_prc -ne 0 ]]; then
      note "host binaries do not run under ${RUNNER[*]} (rc=$_prc), asset skipped :: $(tr '\n' ' ' <<<"$_po" | cut -c1-160)"
      return
    fi
  fi
  # r20 has no llvm-readelf; llvm-readobj prints the same text in GNU style
  local RE=("$(l llvm-readelf)")
  [[ -x ${RE[0]} ]] || RE=("$(l llvm-readobj)" --elf-output-style=GNU)
  rdelf() { run "${RE[@]}" "$@"; }

  # clang spawns its own children (cc1, ld.lld). On a foreign host arch that only works when
  # binfmt_misc runs foreign binaries transparently (qemu-user-binfmt + systemd in WSL).
  local SPAWN=1
  if [[ ${#RUNNER[@]} -gt 0 ]] && ! "$CLANG" --version >/dev/null 2>&1; then
    SPAWN=0
    note "binfmt_misc not active for this arch: skipping everything that needs clang to spawn ld.lld/cc1 (cross-compile matrix, object-based LLVM tool tests, ndk-build)"
  fi

  # ---- toolchain basics
  expect "clang --version"    "clang version"  run "$CLANG" --version
  expect "ld.lld --version"   "LLD"            run "$(l ld.lld)" --version

  # ---- cross-compile matrix; produced binaries are static bionic and are executed under qemu-user
  local a tgt L runnable
  if ((SPAWN)); then
  for a in "${TGT[@]}"; do
    if ! compgen -G "$NDK/toolchains/llvm/prebuilt/*/sysroot/usr/lib/${T_LIBDIR[$a]}" >/dev/null; then
      info "[$a] no sysroot for ${T_TRIPLE[$a]} in this NDK, target skipped"; continue
    fi
    local api=${T_API[$a]} top
    top=$(ls "$NDK"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/"${T_LIBDIR[$a]}" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -n1)
    [[ -n $top && $top -lt $api ]] && { info "[$a] sysroot tops out at API $top, using it instead of $api"; api=$top; }
    tgt="--target=${T_TRIPLE[$a]}$api"; L="${T_LONG[$a]}"
    target_runner "$a" && runnable=1 || runnable=0

    if step "[$a] compile+link C (static)" run "$CLANG" $tgt -O2 -static hello.c -o "c_$a"; then
      if ((runnable)); then expect "[$a] run C binary" "hello 42-ok v=42 long=$L ptr=$L" trun "./c_$a"
      else note "[$a] cannot run produced binary (${TR[0]:-qemu} missing)"; fi
    fi
    if step "[$a] compile+link C++ (static, libc++)" run "$CLANGXX" $tgt -O2 -static hello.cpp -o "cpp_$a"; then
      ((runnable)) && expect "[$a] run C++ binary (exceptions, STL)" "caught boom 10" trun "./cpp_$a"
    fi
    if step "[$a] compile+link C with ThinLTO" run "$CLANG" $tgt -O2 -flto=thin -static hello.c -o "lto_$a"; then
      ((runnable)) && expect "[$a] run ThinLTO binary" "hello 42-ok" trun "./lto_$a"
    fi
    if step "[$a] link shared lib" run "$CLANG" $tgt -shared -fPIC -O2 lib.c -o "lib_$a.so"; then
      expect "[$a] shared lib machine type" "${T_MACH[$a]}" rdelf -h "lib_$a.so"
    fi
    if step "[$a] link dynamic exe" run "$CLANG" $tgt hello.c -o "dyn_$a"; then
      expect "[$a] dynamic exe interpreter" "Requesting program interpreter: /system/bin/${T_INTERP[$a]}\\]" rdelf -l "dyn_$a"
    fi
  done
  fi

  # ---- LLVM utilities (operate on an aarch64 object so this is independent of the host arch)
  local TA="--target=aarch64-linux-android29"
  if ((SPAWN)) && step "clang -c -g (aarch64 object)" run "$CLANG" $TA -g -O0 -c hello.c -o h.o; then
    if have llvm-ar; then
      step   "llvm-ar rcs"              run "$(l llvm-ar)" rcs libh.a h.o
      have llvm-ranlib && step "llvm-ranlib" run "$(l llvm-ranlib)" libh.a
      have llvm-nm && expect "llvm-nm (archive)" " T main" run "$(l llvm-nm)" libh.a
    fi
    have llvm-objdump && expect "llvm-objdump -d" "file format (elf64-littleaarch64|ELF64-aarch64-little)" run "$(l llvm-objdump)" -d h.o
    have llvm-readobj && expect "llvm-readobj" "Format: (elf64-littleaarch64|ELF64-aarch64-little)" run "$(l llvm-readobj)" --file-headers h.o
    expect "readelf -h"               "Machine: +AArch64"          rdelf -h h.o
    have llvm-size && expect "llvm-size" "filename"                run "$(l llvm-size)" h.o
    if have llvm-strip; then
      # a linked .so: LLVM 8's llvm-strip has no -o and refuses relocatable objects
      if step "clang -g -shared (strip input)" run "$CLANG" $TA -g -shared -fPIC lib.c -o hs.so; then
        cp hs.so hs.stripped.so
        step   "llvm-strip"               run "$(l llvm-strip)" hs.stripped.so
        step   "llvm-strip shrinks file"  test "$(stat -c %s hs.stripped.so)" -lt "$(stat -c %s hs.so)"
      fi
    fi
    have llvm-objcopy && step "llvm-objcopy --strip-debug" run "$(l llvm-objcopy)" --strip-debug h.o h2.o
    have llvm-dwarfdump && expect "llvm-dwarfdump" "DW_TAG_subprogram" run "$(l llvm-dwarfdump)" --name=main h.o
  fi
  have llvm-cxxfilt && expect "llvm-cxxfilt" 'foo\(\)'      run "$(l llvm-cxxfilt)" _Z3foov
  if ((SPAWN)) && have llvm-as llvm-dis llvm-link && step "clang -emit-llvm" run "$CLANG" $TA -S -emit-llvm hello.c -o h.ll; then
    step "llvm-as"                    run "$(l llvm-as)" h.ll -o h.bc
    step "llvm-dis"                   run "$(l llvm-dis)" h.bc -o h2.ll
    step "llvm-dis output has IR"     grep -q 'define' h2.ll
    step "llvm-link"                  run "$(l llvm-link)" h.bc -o hl.bc
  fi
  have clang-format && expect "clang-format" 'int main\(\) \{ return 0; \}' run "$(l clang-format)" fmt.c
  # older clang-tidy does not find the NDK sysroot by itself
  have clang-tidy && step "clang-tidy" run "$(l clang-tidy)" hello.c -checks='-*,bugprone-*' -- $TA --sysroot="$(dirname "$LLVM")/sysroot"
  if have clang-scan-deps; then
    # LLVM 9's clang-scan-deps takes only a compilation database; -format arrived
    # with LLVM 10, and the direct `-- compiler` form does not exist in 9-14.
    # Drive it through a database, which is the CLI those releases actually have.
    if ((SPAWN)) && run "$(l clang-scan-deps)" --help 2>&1 | grep -q -- '--format'; then
      python3 - "$T" "$CLANG" "$TA" <<'PY'
import json, os, shlex, sys
t, clang, ta = sys.argv[1:4]
src = os.path.join(t, "hello.cpp")
obj = os.path.join(t, "hello.o")
cmd = " ".join(shlex.quote(x) for x in (clang, ta, "-c", src, "-o", obj))
json.dump([{"directory": t, "command": cmd, "file": src}],
          open(os.path.join(t, "compile_commands.json"), "w"))
PY
      expect "clang-scan-deps" 'hello\.o:' run "$(l clang-scan-deps)" -compilation-database="$T/compile_commands.json" -format=make
    elif ((SPAWN)); then
      info "clang-scan-deps has no --format in this NDK, its test skipped"
    else
      info "clang-scan-deps needs binfmt_misc to spawn clang, its test skipped"
    fi
  fi

  # symbolizer + PGO/coverage need a runnable x86_64 target binary
  if ((SPAWN)) && target_runner x86_64; then
    if step "[x86_64] compile -g (symbolizer test)" run "$CLANG" --target=x86_64-linux-android21 -g -O0 -static hello.c -o dbg; then
      local addr; addr=$(run "$(l llvm-nm)" dbg 2>/dev/null | awk '$3=="main"{print $1}')
      expect "llvm-symbolizer resolves main" '^main$' run "$(l llvm-symbolizer)" --obj=dbg <<<"0x$addr"   # LLVM 8 reads addresses from stdin only
    fi
    if have llvm-profdata llvm-cov && step "[x86_64] compile with coverage instrumentation" run "$CLANG" --target=x86_64-linux-android21 -O0 -static -fprofile-instr-generate -fcoverage-mapping hello.c -o cov; then
      export LLVM_PROFILE_FILE="$T/c.profraw"
      step "[x86_64] run instrumented binary" trun ./cov
      unset LLVM_PROFILE_FILE
      step   "llvm-profdata merge"  run "$(l llvm-profdata)" merge c.profraw -o c.profdata
      expect "llvm-cov report"      "TOTAL"  run "$(l llvm-cov)" report ./cov -instr-profile=c.profdata
    fi
  else
    ((SPAWN)) && note "x86_64 target not runnable here: skipped llvm-symbolizer / profdata / llvm-cov functional tests"
  fi

  if ((LLVM_ONLY == 0)); then
  # ---- extra tools
  if [[ -x $PB/yasm ]]; then
    if step "yasm assemble (elf64)" run "$PB/yasm" -f elf64 t.asm -o t.o; then
      expect "yasm output machine" "Machine: +Advanced Micro Devices X86-64" rdelf -h t.o
    fi
  else note "yasm not present"; fi
  if [[ -x $PB/make ]]; then expect "make runs a Makefile" "made-" run "$PB/make" -f Makefile
  else note "make not present"; fi

  if [[ -x $PY ]]; then
    expect "python3 runs" '^42$' run "$PY" -c 'print(6*7)'
    local m out
    for m in zipfile json hashlib struct subprocess zlib lzma bz2; do
      step "python3 import $m" run "$PY" -c "import $m"
    done
    for m in ctypes sqlite3 ssl; do   # optional modules: report, do not fail
      out=$(run "$PY" -c "import $m" 2>&1) && pass "python3 import $m" || note "python3 module '$m' missing in bundled python"
    done
  else info "no toolchain python3 in this NDK"; fi
  # r20-r24 also ship Python 2.7 for ndk-gdb and friends
  local PY2="$PB/python2.7"
  if [[ -x $PY2 ]]; then
    expect "python2.7 runs" '^42$' run "$PY2" -c 'print(6*7)'
    local m2
    for m2 in zipfile json hashlib struct subprocess zlib; do
      step "python2.7 import $m2" run "$PY2" -c "import $m2"
    done
    out=$(run "$PY2" -c "import bz2" 2>&1) && pass "python2.7 import bz2" || info "python2.7 has no bz2 (Google's r20-r21 build lacks it too)"
  fi

  if [[ -x $SH/glslc ]]; then
    if step "glslc compile shader" run "$SH/glslc" -fshader-stage=vertex t.vert -o t.spv; then
      step   "SPIR-V magic number"  magic t.spv 0 03022307
      sht() { [[ -x $SH/$1 ]] || { info "$1 not shipped in this NDK"; return 1; }; }
      sht spirv-val && step   "spirv-val"            run "$SH/spirv-val" t.spv
      sht spirv-dis && expect "spirv-dis"            "OpEntryPoint" run "$SH/spirv-dis" t.spv
      sht spirv-opt && step   "spirv-opt"            run "$SH/spirv-opt" -O t.spv -o t2.spv
      if sht spirv-dis && sht spirv-as; then
        step   "spirv-dis to file"    run "$SH/spirv-dis" t.spv -o t.spvasm
        step   "spirv-as (round trip)" run "$SH/spirv-as" t.spvasm -o t3.spv
      fi
      sht spirv-link && step  "spirv-link"           run "$SH/spirv-link" t.spv -o t4.spv --allow-partial-linkage
    fi
  else note "shaderc (glslc) not present"; fi

  # ndk-build / ndk-stack are shell scripts that exec the NDK's own binaries directly,
  # so on a foreign host arch they need binfmt_misc (qemu-user-binfmt + systemd in WSL).
  local direct=$SPAWN
  if ((direct)); then
    if step "ndk-build (4 ABIs, c++_shared)" "$NDK/ndk-build" NDK_PROJECT_PATH="$T/proj"; then
      local abi m2; declare -A AM=([arm64-v8a]='Machine: +AArch64' [armeabi-v7a]='Machine: +ARM$' [x86]='Machine: +Intel 80386' [x86_64]='Machine: +Advanced Micro Devices X86-64')
      for abi in arm64-v8a armeabi-v7a x86 x86_64; do
        if [[ -f proj/libs/$abi/libhello.so ]]; then
          expect "ndk-build output $abi" "${AM[$abi]}" rdelf -h "proj/libs/$abi/libhello.so"
        else bad "ndk-build output $abi missing" ""; fi
      done
    fi
    expect "ndk-stack usage" "usage: ndk-?stack" "$NDK/ndk-stack" -h
    if [[ -x $PB/gdb ]]; then
      out=$(run "$PB/gdb" --version 2>&1)
      if grep -q 'GNU gdb' <<<"$out"; then pass "gdb --version"
      elif grep -q 'error while loading shared libraries' <<<"$out"; then note "gdb needs a host library this machine lacks :: $(grep -o 'lib[^:]*: cannot' <<<"$out")"
      else bad "gdb --version" "$out"; fi
    fi
  else
    :   # already reported above
  fi

  fi

  # ---- every ELF in the host toolchain: smoke test (unless functionally covered) + hardening
  local COVERED=" clang clang++ python2.7 ld.lld llvm-ar llvm-ranlib llvm-nm llvm-objdump llvm-readobj llvm-readelf llvm-size llvm-strip llvm-objcopy llvm-cxxfilt llvm-dwarfdump llvm-symbolizer llvm-as llvm-dis llvm-link llvm-profdata llvm-cov clang-format clang-tidy clang-scan-deps yasm make python3 glslc spirv-val spirv-dis spirv-opt spirv-as spirv-link "
  local f base out rc real mach SRUN=(); declare -A seen=()
  while IFS= read -r -d '' f; do
    base=$(basename "$f")
    real=$(readlink -f "$f"); [[ -n ${seen[$real]:-} ]] && continue; seen[$real]=1
    [[ $base == gdb-orig ]] && continue   # only runs through the gdb wrapper, which sets its library path
    [[ "$base" == *.so || "$base" == *.so.* || "$base" == *.a || "$base" == *.o ]] && continue
    [[ "$(head -c4 "$f" 2>/dev/null | tail -c3)" == "ELF" ]] || continue
    if [[ "$COVERED" != *" $base "* && ! $base =~ ^clang-[0-9]+$ ]]; then
      mach=$(elf_machine "$f"); SRUN=("${RUNNER[@]}")
      if [[ -n $mach ]] && ! grep -qE "$(host_machine_re)" <<<"$mach"; then
        if [[ $HOST_ARCH != x86_64 ]] && grep -qE 'X86-64|AMD x86-64' <<<"$mach"; then
          SRUN=()   # Google's own helper toolchains are x86_64; run those natively
        else
          info "smoke ${f#$NDK/} skipped: $mach ELF on a $HOST_ARCH host"
          check_hardening "$f" "${f#$NDK/}"
          continue
        fi
      fi
      out=$(timeout "$TIMEOUT" "${SRUN[@]}" "$f" --help </dev/null 2>&1); rc=$?
      if [[ $rc -eq 127 ]] && grep -q 'error while loading shared libraries' <<<"$out"; then
        if [[ $real == "$LLVM"/* && -z ${NDK_LOCAL:-} ]]; then
          bad "smoke ${f#$NDK/} (rc=$rc)" "$out"
        else
          note "smoke ${f#$NDK/} needs a host library that is not installed :: $(grep -o 'lib[^:]*: cannot' <<<"$out" | head -n1)"
        fi
      elif [[ $rc -eq 126 || $rc -eq 127 || $rc -ge 128 ]]; then bad "smoke ${f#$NDK/} (rc=$rc)" "$out"
      else pass "smoke ${f#$NDK/} (rc=$rc)"; fi
    fi
    check_hardening "$f" "${f#$NDK/}"
  done < <(find "$NDK"/toolchains/llvm/prebuilt/*/bin "$NDK"/toolchains/llvm/prebuilt/*/python3/bin \
                "$NDK"/toolchains/llvm/prebuilt/*/*-linux-android*/bin "$NDK"/toolchains/*-4.9/prebuilt/*/bin \
                "$NDK"/prebuilt/*/bin "$NDK"/shader-tools -type f -print0 2>/dev/null)
}

# ---------------------------------------------------------------- official toolchain for VER
# The zips were named -linux-x86_64.zip up to r23-beta4 and -linux.zip after.
BASE="$WORK/base/$VER"
fetch_base() {
  [[ -f $BASE/.done ]] && return 0
  local z="$WORK/dl/android-ndk-$VER.zip" u
  if [[ ! -f $z ]]; then
    for u in "android-ndk-$VER-linux.zip" "android-ndk-$VER-linux-x86_64.zip"; do
      echo "--> downloading official $u"
      curl -fL --retry 3 -o "$z.part" "https://dl.google.com/android/repository/$u" && { mv "$z.part" "$z"; break; }
      rm -f "$z.part"
    done
    [[ -f $z ]] || { echo "official NDK $VER not found on dl.google.com"; return 1; }
  fi
  echo "--> extracting the official toolchain"
  rm -rf "$BASE"; mkdir -p "$BASE"
  unzip -q "$z" '*/toolchains/llvm/prebuilt/linux-x86_64/*' '*/source.properties' -d "$BASE" || return 1
  touch "$BASE/.done"
}

# a fake NDK root at $1 with our bin/ over the official toolchain
overlay() {
  local out=$1 ours=$2 ndk tc
  ndk=$(dirname "$(find "$BASE" -maxdepth 2 -name source.properties | head -n1)")
  rm -rf "$out"; mkdir -p "$out/toolchains/llvm/prebuilt"
  cp "$ndk/source.properties" "$out/"
  cp -al "$ndk/toolchains/llvm/prebuilt/linux-x86_64" "$out/toolchains/llvm/prebuilt/" 2>/dev/null \
    || cp -a "$ndk/toolchains/llvm/prebuilt/linux-x86_64" "$out/toolchains/llvm/prebuilt/"
  tc="$out/toolchains/llvm/prebuilt/linux-x86_64"
  [[ $OFFICIAL == 1 ]] && return 0
  rm -rf "$tc/bin"; cp -a "$ours/bin" "$tc/bin"
  # Same as make-ndk.sh: our clang uses its own resource dir (lib/clang/<ours>, e.g. 8.0.0 where
  # Google's is lib64/clang/8.0.7), so it gets our headers plus the Android runtimes Google ships.
  local rd v g
  g=$(ls -d "$tc"/lib64/clang/*/ "$tc"/lib/clang/*/ 2>/dev/null | head -n1)
  for rd in "$ours"/lib/clang/*/; do
    [[ -d $rd ]] || continue
    v=$(basename "$rd")
    if [[ ! -d $tc/lib/clang/$v ]]; then
      mkdir -p "$tc/lib/clang"; cp -a "$rd" "$tc/lib/clang/$v"
      info "resource dir lib/clang/$v is ours; Google's is ${g#$tc/}"
    fi
    [[ -n $g && ! -d $tc/lib/clang/$v/lib && -d $g/lib ]] && cp -a "$g/lib" "$tc/lib/clang/$v/lib"
  done
}

summary() {
  echo
  echo "==================== SUMMARY ===================="
  echo "OK=$ok  FAIL=$fail  WARN=$warn  SKIPPED_ASSETS=$skip"
  echo "Full log:      $RESULTS"
  echo "Problems only: grep -E '^(FAIL|WARN|SKIP)' $RESULTS"
  [[ $fail -eq 0 ]]
}

fetch_base || exit 1
make_fixtures

if [[ $OFFICIAL == 1 ]]; then
  [[ "$(uname -m)" == x86_64 ]] || { echo "Official toolchains are Linux x86_64 only; this machine is $(uname -m)."; exit 1; }
  CUR="official-$VER"; RUNNER=(); NDK_LOCAL=official; HOST_ARCH=x86_64
  dir="$WORK/x/official-$VER"; overlay "$dir" ""
  echo; echo "=================== $CUR ==================="
  test_ndk "$dir"
  [[ $KEEP_EXTRACTED == 1 ]] || rm -rf "$dir"
  summary; exit $?
fi

echo "==> Looking up Linux LLVM assets for $REPO @ $TAG (release $VER)"
html=$(curl -fsSL "https://github.com/$REPO/releases/expanded_assets/$TAG") || { echo "release $TAG not found"; exit 1; }
mapfile -t URLS < <(grep -oE "releases/download/$TAG/[A-Za-z0-9_.+%-]+-$VER-[A-Za-z0-9_.-]+\.tar\.xz" <<<"$html" \
  | grep -vE -- "-$VER-(beta|rc)[0-9]+-" | grep -E -- '-linux-' | grep -v -- '-linux-android' | grep -- "$FILTER" \
  | sort -u | sed "s#^#https://github.com/$REPO/#")
[[ ${#URLS[@]} -gt 0 ]] || { echo "No matching Linux assets found."; exit 1; }
echo "    ${#URLS[@]} asset(s) selected"

for url in "${URLS[@]}"; do
  file="${url##*/}"; file="${file//%2B/+}"; name="${file%.tar.xz}"; triple="${name##*-$VER-}"
  arch="${triple%%-linux-*}"; abi="${triple##*-linux-}"; CUR="$VER-$triple"; HOST_ARCH="$arch"
  dir="$WORK/x/$CUR"
  echo; echo "=================== $CUR ==================="

  qsuf="${QEMU[$arch]:-}"
  [[ -n $qsuf ]] || { log "SKIP  [$CUR] no qemu mapping for arch '$arch'"; ((skip++)); continue; }
  case $abi in *x32) log "SKIP  [$CUR] x32 ABI is not supported by qemu-user"; ((skip++)); continue ;; esac
  [[ $abi == *abin32 ]] && case $arch in mips64) qsuf=mipsn32 ;; mips64el) qsuf=mipsn32el ;; esac

  RUNNER=()
  if [[ $qsuf != native ]]; then
    q="qemu-$qsuf"; command -v "$q" >/dev/null || q="qemu-$qsuf-static"
    command -v "$q" >/dev/null || { log "SKIP  [$CUR] qemu-$qsuf not installed"; ((skip++)); continue; }
    RUNNER=("$q")
  fi

  if [[ ! -f "$WORK/dl/$file" ]]; then
    echo "--> downloading $file"
    curl -fL --retry 3 -o "$WORK/dl/$file.part" "$url" && mv "$WORK/dl/$file.part" "$WORK/dl/$file" \
      || { log "FAIL  [$CUR] download failed"; ((fail++)); rm -f "$WORK/dl/$file.part"; continue; }
  fi
  echo "--> extracting"
  rm -rf "$dir.src"; mkdir -p "$dir.src"
  tar -xf "$WORK/dl/$file" -C "$dir.src" || { log "FAIL  [$CUR] extract failed"; ((fail++)); rm -rf "$dir.src"; continue; }
  ours=$(dirname "$(find "$dir.src" -maxdepth 3 -type d -name bin | head -n1)")
  overlay "$dir" "$ours"; rm -rf "$dir.src"

  # glibc builds under qemu: static binaries need no sysroot, dynamic ones do
  if [[ $qsuf != native && $abi == gnu* ]]; then
    probe=$(find "$dir" -type f -name 'clang-[0-9]*' 2>/dev/null | head -n1)
    interp=""
    command -v readelf >/dev/null && [[ -n $probe ]] && interp=$(readelf -lW "$probe" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p')
    if [[ -n $interp ]]; then
      sr="${SYSROOT[$arch-$abi]:-}"
      if [[ -z $sr || ! -d $sr ]]; then
        log "SKIP  [$CUR] dynamic glibc build, sysroot ${sr:-none known} missing; ${PKG[$arch-$abi]:+try: sudo apt install ${PKG[$arch-$abi]}}"
        ((skip++)); [[ $KEEP_EXTRACTED == 1 ]] || rm -rf "$dir"; continue
      fi
      RUNNER+=(-L "$sr")
    fi
  fi

  test_ndk "$dir"

  [[ $KEEP_EXTRACTED == 1 ]] || rm -rf "$dir"
  [[ $PRUNE_ARCHIVES == 1 ]] && rm -f "$WORK/dl/$file"
done

summary
