# Prebuilt build image for the llvm-custom cross builds. Bakes the build tools
# and the zig / llvm-mingw / zig-as-llvm toolchains so CI only pulls (fast).
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

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils unzip git make cmake ninja-build \
        build-essential patchelf file tree python3 zlib1g-dev libzstd-dev \
    && rm -rf /var/lib/apt/lists/*

# qemu-user-static + x86_64 libs so the NDK's prebuilt binaries run on non-x86 hosts
RUN arch="$(uname -m)"; \
    if [ "$arch" != x86_64 ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            qemu-user-static libc6-amd64-cross \
        && rm -rf /var/lib/apt/lists/* \
        && curl -L -o /tmp/zlib.deb \
            "http://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g_1.3.dfsg-3.1ubuntu2.1_amd64.deb" \
        && dpkg-deb -x /tmp/zlib.deb /tmp/zlib \
        && cp -a /tmp/zlib/lib/x86_64-linux-gnu/* /usr/x86_64-linux-gnu/lib/ \
        && rm -rf /tmp/zlib.deb /tmp/zlib; \
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
        curl -L --fail --retry 20 --retry-all-errors --retry-delay 2 --connect-timeout 15 --speed-limit 1024 --speed-time 30 --progress-bar "https://ziglang.org/builds/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" \
          | tar -xJ -C /opt \
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
            curl -L --fail --retry 20 --retry-all-errors --retry-delay 2 --connect-timeout 15 --speed-limit 1024 --speed-time 30 --progress-bar "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${arch}.tar.xz" \
              | tar -xJ -C /opt \
            && mv "/opt/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${arch}" /opt/llvm-mingw ;; \
        *) echo "WARNING: llvm-mingw does not support host arch '$arch'; Windows cross-builds will be unavailable" ;; \
    esac

# zig-as-llvm: thin cc/c++/ar/... wrappers around zig, keyed off $ZIG_TARGET
RUN if [ ! -f /opt/.no-zig ]; then \
        git clone --depth 1 "https://github.com/${REPO_OWNER}/zig-as-llvm" /opt/zig-as-llvm; \
    fi
# llvm-mingw before zig-as-llvm: mingw ar/cc/c++ must resolve to llvm-mingw,
# not zig-as-llvm which is only for linux/bsd targets via zig

WORKDIR /work
