# Prebuilt build image for the llvm-custom cross builds. Bakes the build tools
# and the zig / llvm-mingw / zig-as-llvm / osxcross toolchains so CI only pulls
# (fast). zig drives the linux/bsd targets, llvm-mingw the windows targets, and
# osxcross (which bundles cctools-port: ld64/ar/ranlib/strip/lipo/...) the macOS
# targets — zig segfaults building macOS LLVM, so darwin uses osxcross instead.
# The build scripts are NOT copied in — they are bind-mounted from the checkout
# at run time, so editing scripts/ needs no image rebuild.
#
#   docker run --rm -v "$PWD:/work" -w /work \
#     -e PLATFORM=linux -e TARGET=x86_64-linux-gnu -e NDK_VERSION=30 \
#     ghcr.io/<owner>/llvm-builder \
#     bash -c 'scripts/fetch-source.sh && scripts/build.sh'
FROM ubuntu:24.04

ARG ZIG_VERSION=0.17.0-dev.304+9787df942
ARG LLVM_MINGW_VERSION=20260505
ARG REPO_OWNER=HomuHomu833
ARG MACOS_SDK_VERSION=15.5

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates aria2 xz-utils unzip git make cmake ninja-build \
        build-essential patchelf file tree python3 zlib1g-dev libzstd-dev \
        clang lld libssl-dev libxml2-dev liblzma-dev libbz2-dev uuid-dev \
        cpio bzip2 \
    && rm -rf /var/lib/apt/lists/*

# qemu-user-static + x86_64 libs so the NDK's prebuilt binaries run on non-x86 hosts
RUN arch="$(uname -m)"; \
    if [ "$arch" != x86_64 ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            qemu-user-static libc6-amd64-cross \
        && rm -rf /var/lib/apt/lists/* \
        && aria2c --max-tries=5 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o zlib.deb \
            "http://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.1_amd64.deb" \
        && dpkg-deb -x /tmp/zlib.deb /tmp/zlib \
        && cp -a /tmp/zlib/usr/lib/x86_64-linux-gnu/* /usr/x86_64-linux-gnu/lib/ \
        && rm -rf /tmp/zlib.deb /tmp/zlib \
        && aria2c --max-tries=5 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o gcc.deb \
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
        aria2c --max-tries=20 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o zig.tar.xz \
            "https://ziglang.org/builds/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
        && tar -xJf /tmp/zig.tar.xz -C /opt \
        && rm /tmp/zig.tar.xz \
        && mv "/opt/zig-${zig_arch}-linux-${ZIG_VERSION}" /opt/zig \
        && chmod -R a+w /opt/zig/lib; \
    fi   # build.sh overlays patches/musl/zig here at run time (non-root)

# zig-as-llvm's cc/c++/ar/strip/... wrappers exec a bare `zig`, and build.sh
# overlays the musl libc fixes next to the zig binary ($(dirname $(command -v zig))).
# Both need zig on PATH. Only zig is added -- NOT the zig-as-llvm / llvm-mingw bin
# dirs: build.sh invokes those by absolute path, and keeping them off PATH leaves
# `cc`/`c++` resolving to the host gcc that LLVM's cross build uses to bootstrap
# its native tablegen.
ENV QEMU_LD_PREFIX=/usr/x86_64-linux-gnu

ENV PATH="/opt/zig:${PATH}"

# llvm-mingw (windows targets; only x86_64 / aarch64 linux hosts)
RUN arch="$(uname -m)"; \
    case "$arch" in \
        x86_64|aarch64) \
            aria2c --max-tries=20 --retry-wait=2 --connect-timeout=15 --dir=/tmp -o llvm-mingw.tar.xz \
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

# osxcross -> /opt/osxcross: the macOS cross toolchain for darwin targets,
# replacing zig (which segfaults building macOS LLVM). osxcross compiles
# cctools-port (ld64/ar/ranlib/strip/lipo/install_name_tool/...) and clang
# wrappers, and bakes the macOS SDK into /opt/osxcross/SDK. build.sh points the
# darwin CC/CXX/AR/RANLIB/STRIP/LD at the arch-prefixed wrappers in
# /opt/osxcross/bin (e.g. arm64-apple-darwin24-clang, x86_64-apple-darwin24-ar).
# Arch-independent toolchain, so no host gating. Only x86_64 + arm64 wrappers are
# built (the only macOS arches we target) to keep the image build quick.
ARG OSXCROSS_REF=master
RUN git clone https://github.com/tpoechtrager/osxcross /tmp/osxcross \
    && git -C /tmp/osxcross checkout "$OSXCROSS_REF" \
    && aria2c --max-tries=20 --retry-wait=2 --connect-timeout=15 \
        --dir=/tmp/osxcross/tarballs -o "MacOSX${MACOS_SDK_VERSION}.sdk.tar.xz" \
        "https://github.com/joseluisq/macosx-sdks/releases/download/${MACOS_SDK_VERSION}/MacOSX${MACOS_SDK_VERSION}.sdk.tar.xz" \
    && cd /tmp/osxcross \
    && UNATTENDED=1 ENABLE_ARCHS="x86_64 arm64 arm64e" OSX_VERSION_MIN=11.0 \
       TARGET_DIR=/opt/osxcross ./build.sh \
    && cd / \
    && rm -rf /tmp/osxcross

WORKDIR /work
