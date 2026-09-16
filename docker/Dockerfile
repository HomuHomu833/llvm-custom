# Prebuilt build image for llvm-custom. Bakes the build tools and the
# zig / llvm-mingw / zig-as-llvm / osxcross toolchains so CI only pulls.
# zig: linux/bsd targets; llvm-mingw: windows; osxcross (cctools-port): macOS
# (zig segfaults on macOS LLVM).
# Build scripts are bind-mounted from the checkout at run time, not copied in.
#
#   docker run --rm -v "$PWD:/work" -w /work \
#     -e PLATFORM=linux -e TARGET=x86_64-linux-gnu -e NDK_VERSION=30 \
#     ghcr.io/<owner>/llvm-builder \
#     bash -c 'scripts/fetch-source.sh && scripts/build.sh'
FROM ubuntu:24.04

ARG ZIG_VERSION=0.17.0-dev.2131+d08989840
ARG LLVM_MINGW_VERSION=20260908
ARG REPO_OWNER=HomuHomu833
ARG MACOS_SDK_VERSION=26.1

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates aria2 xz-utils unzip git make cmake ninja-build \
        build-essential patchelf file tree python3 python3-venv zlib1g-dev libzstd-dev \
        libssl-dev libxml2-dev liblzma-dev libbz2-dev uuid-dev \
        cpio bzip2 \
    && rm -rf /var/lib/apt/lists/*

# clang from apt.llvm.org rather than noble's, which is 18. This is the compiler
# the osxcross wrappers invoke and the one that generates the PGO profile, and an
# indexed profile is rejected by any reader older than the version that wrote it:
# every tree from r28 on emits version 12, which 18 cannot read. 20 can, so macOS
# keeps PGO instead of having build.sh's probe drop it.
#
# cc and c++ are repointed at it too, so the NATIVE tblgen the LLVM < 16 branch
# builds comes from the same toolchain as everything else instead of from gcc.
#
# Fetched with aria2 (no curl here) and kept ASCII-armored: apt reads .asc under
# signed-by directly, so this needs no gnupg in the image.
ARG CLANG_VERSION=20
RUN . /etc/os-release \
    && mkdir -p /etc/apt/keyrings \
    && aria2c --console-log-level=error --check-certificate=false --max-tries=5 \
        --dir=/etc/apt/keyrings -o llvm.asc "https://apt.llvm.org/llvm-snapshot.gpg.key" \
    && echo "deb [signed-by=/etc/apt/keyrings/llvm.asc] http://apt.llvm.org/${VERSION_CODENAME}/ llvm-toolchain-${VERSION_CODENAME}-${CLANG_VERSION} main" \
        > /etc/apt/sources.list.d/llvm.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        "clang-${CLANG_VERSION}" "lld-${CLANG_VERSION}" \
    && rm -rf /var/lib/apt/lists/* \
    && for t in clang clang++ lld ld.lld; do \
           if [ -x "/usr/bin/$t-${CLANG_VERSION}" ]; then \
               update-alternatives --install "/usr/bin/$t" "$t" "/usr/bin/$t-${CLANG_VERSION}" 100; \
           fi; \
       done \
    && update-alternatives --install /usr/bin/cc  cc  "/usr/bin/clang-${CLANG_VERSION}"   100 \
    && update-alternatives --install /usr/bin/c++ c++ "/usr/bin/clang++-${CLANG_VERSION}" 100 \
    && clang --version | head -n1 \
    && cc --version | head -n1 \
    && c++ --version | head -n1

# TensorFlow for MLGO, in its own venv at /opt/tf. The venv is not just tidiness:
# llvm/CMakeLists.txt derives the AOT compiler as
# "${TENSORFLOW_AOT_PATH}/../../../../bin/saved_model_cli", so the package has to
# sit four levels under a prefix that also holds bin/ -- which a venv guarantees
# and a system dist-packages install does not. build.sh probes before using it,
# so a wheel without a given backend just means that target builds without MLGO.
#
# tensorflow-cpu publishes x86_64 wheels only, so this is best-effort per host
# arch the way llvm-mingw below is: elsewhere the venv simply doesn't exist and
# build.sh's probe drops MLGO for every target. On x86_64 the asserts stay hard,
# so a wheel missing the AOT pieces fails the image rather than 99 builds.
ARG TENSORFLOW_VERSION=2.21.0
RUN arch="$(uname -m)"; \
    if [ "$arch" = x86_64 ]; then \
        python3 -m venv /opt/tf \
        && /opt/tf/bin/pip install --no-cache-dir "tensorflow-cpu==${TENSORFLOW_VERSION}" \
        && find /opt/tf -name '__pycache__' -type d -prune -exec rm -rf {} + \
        && test -d "$(/opt/tf/bin/python -c 'import tensorflow,os;print(os.path.dirname(tensorflow.__file__))')/xla_aot_runtime_src" \
        && test -x /opt/tf/bin/saved_model_cli; \
    else \
        echo "WARNING: tensorflow-cpu has no $arch wheel; MLGO will be unavailable on this host"; \
    fi

# fetch: download with retries, re-running aria2c on any failure so transient
# GitHub errors recover. The build scripts define an identical helper for
# standalone runs.
RUN printf '%s\n' '#!/bin/sh' \
    'i=0; until aria2c --console-log-level=error --check-certificate=false --max-tries=5 --retry-wait=2 --connect-timeout=15 --allow-overwrite=true --auto-file-renaming=false "$@"; do' \
    '  i=$((i+1)); [ "$i" -ge 5 ] && { echo "fetch: giving up after $i attempts" >&2; exit 1; }' \
    '  echo "fetch: aria2c failed, retry $i/5 in 2s..." >&2; sleep 2' \
    'done' > /usr/local/bin/fetch && chmod +x /usr/local/bin/fetch

# qemu-user-static + x86_64 libs so the NDK's prebuilt binaries run on non-x86 hosts
RUN arch="$(uname -m)"; \
    if [ "$arch" != x86_64 ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            qemu-user-static libc6-amd64-cross \
        && rm -rf /var/lib/apt/lists/* \
        && fetch --dir=/tmp -o zlib.deb \
            "http://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.1_amd64.deb" \
        && dpkg-deb -x /tmp/zlib.deb /tmp/zlib \
        && cp -a /tmp/zlib/usr/lib/x86_64-linux-gnu/* /usr/x86_64-linux-gnu/lib/ \
        && rm -rf /tmp/zlib.deb /tmp/zlib \
        && fetch --dir=/tmp -o gcc.deb \
            "http://archive.ubuntu.com/ubuntu/pool/main/g/gcc-14/libgcc-s1_14.2.0-4ubuntu2~24.04.1_amd64.deb" \
        && dpkg-deb -x /tmp/gcc.deb /tmp/gcc \
        && cp -a /tmp/gcc/usr/lib/x86_64-linux-gnu/* /usr/x86_64-linux-gnu/lib/ \
        && rm -rf /tmp/gcc.deb /tmp/gcc; \
    fi

# zig (provides the cross C/C++ toolchain for linux/bsd targets)
RUN arch="$(uname -m)"; \
    case "$arch" in \
        x86_64)       zig_arch="x86_64" ;; \
        aarch64)      zig_arch="aarch64" ;; \
        armv7l|armv8l) zig_arch="arm" ;; \
        riscv64)      zig_arch="riscv64" ;; \
        ppc64le)      zig_arch="powerpc64le" ;; \
        i686|i386)    zig_arch="x86" ;; \
        loongarch64)  zig_arch="loongarch64" ;; \
        s390x)        zig_arch="s390x" ;; \
        *) echo "WARNING: unsupported zig host arch '$arch'; skipping zig and zig-as-llvm"; touch /opt/.no-zig ;; \
    esac; \
    if [ ! -f /opt/.no-zig ]; then \
        case "$ZIG_VERSION" in \
            *dev*) zig_base="https://ziglang.org/builds" ;;        \
            *)     zig_base="https://ziglang.org/download/${ZIG_VERSION}" ;; \
        esac; \
        fetch --dir=/tmp -o zig.tar.xz \
            "${zig_base}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
        && tar -xJf /tmp/zig.tar.xz -C /opt \
        && rm /tmp/zig.tar.xz \
        && mv "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}" /opt/zig \
        && chmod -R a+w /opt/zig/lib; \
    fi   # build.sh overlays patches/musl/zig here at run time (non-root)

# Only zig on PATH: its wrappers exec a bare `zig` and build.sh overlays musl
# fixes next to it. zig-as-llvm / llvm-mingw stay off PATH (called by absolute
# path) so `cc`/`c++` resolve to the host gcc LLVM uses to bootstrap tablegen.
ENV QEMU_LD_PREFIX=/usr/x86_64-linux-gnu

ENV PATH="/opt/zig:${PATH}"

# llvm-mingw (windows targets; only x86_64 / aarch64 linux hosts)
RUN arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|aarch64) \
            fetch --dir=/tmp -o llvm-mingw.tar.xz \
                "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${arch}.tar.xz" \
            && tar -xJf /tmp/llvm-mingw.tar.xz -C /opt \
            && rm /tmp/llvm-mingw.tar.xz \
            && mv "/opt/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${arch}" /opt/llvm-mingw ;; \
        *) echo "WARNING: llvm-mingw does not support host arch '$arch'; Windows cross-builds will be unavailable" ;; \
    esac

# zig-as-llvm: thin cc/c++/ar/... wrappers around zig, keyed off $ZIG_TARGET
RUN if [ ! -f /opt/.no-zig ]; then \
        git clone --depth 1 "https://github.com/${REPO_OWNER}/zig-as-llvm" /opt/zig-as-llvm; \
    fi
# llvm-mingw before zig-as-llvm: mingw ar/cc/c++ must resolve to llvm-mingw,
# not zig-as-llvm which is only for linux/bsd targets via zig

# osxcross -> /opt/osxcross: macOS cross toolchain (cctools-port + clang
# wrappers) with the SDK baked into /opt/osxcross/SDK. build.sh points the darwin
# tools at the arch-prefixed wrappers in /opt/osxcross/bin. Only the target
# arches (x86_64/x86_64h/arm64/arm64e) are built to keep it quick.
ARG OSXCROSS_REF=master
RUN git clone https://github.com/tpoechtrager/osxcross /tmp/osxcross \
    && git -C /tmp/osxcross checkout "$OSXCROSS_REF" \
    && fetch \
        --dir=/tmp/osxcross/tarballs -o "MacOSX${MACOS_SDK_VERSION}.sdk.tar.xz" \
        "https://github.com/joseluisq/macosx-sdks/releases/download/${MACOS_SDK_VERSION}/MacOSX${MACOS_SDK_VERSION}.sdk.tar.xz" \
    && cd /tmp/osxcross \
    && UNATTENDED=1 ENABLE_ARCHS="x86_64 x86_64h arm64 arm64e" OSX_VERSION_MIN=11.0 \
       TARGET_DIR=/opt/osxcross ./build.sh \
    && cd / \
    && rm -rf /tmp/osxcross

WORKDIR /work
