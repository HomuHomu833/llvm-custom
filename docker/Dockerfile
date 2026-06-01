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

# zig (provides the cross C/C++ toolchain for linux/bsd targets)
RUN curl -L --fail --retry 20 --retry-all-errors --retry-delay 2 --connect-timeout 15 --speed-limit 1024 --speed-time 30 --progress-bar "https://ziglang.org/builds/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
      | tar -xJ -C /opt \
    && mv "/opt/zig-x86_64-linux-${ZIG_VERSION}" /opt/zig \
    && chmod -R a+w /opt/zig/lib   # build.sh overlays patches/musl/zig here at run time (non-root)

# zig-as-llvm's cc/c++/ar/strip/... wrappers exec a bare `zig`, and build.sh
# overlays the musl libc fixes next to the zig binary ($(dirname $(command -v zig))).
# Both need zig on PATH. Only zig is added -- NOT the zig-as-llvm / llvm-mingw bin
# dirs: build.sh invokes those by absolute path, and keeping them off PATH leaves
# `cc`/`c++` resolving to the host gcc that LLVM's cross build uses to bootstrap
# its native tablegen.
ENV PATH="/opt/zig:${PATH}"

# llvm-mingw (windows targets)
RUN curl -L --fail --retry 20 --retry-all-errors --retry-delay 2 --connect-timeout 15 --speed-limit 1024 --speed-time 30 --progress-bar "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64.tar.xz" \
      | tar -xJ -C /opt \
    && mv "/opt/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64" /opt/llvm-mingw

# zig-as-llvm: thin cc/c++/ar/... wrappers around zig, keyed off $ZIG_TARGET
RUN git clone --depth 1 "https://github.com/${REPO_OWNER}/zig-as-llvm" /opt/zig-as-llvm
# llvm-mingw before zig-as-llvm: mingw ar/cc/c++ must resolve to llvm-mingw,
# not zig-as-llvm which is only for linux/bsd targets via zig

WORKDIR /work
