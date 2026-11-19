# Build container for the dodge stage-1 chainloader kernel (Pocket Linux).
# Same toolchain family as the stage-2 kernel that booted the phone on
# 2026-11-18 (Ubuntu 24.04 clang 18, LLVM=1).
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
      clang lld llvm binutils make flex bison bc libssl-dev libelf-dev dwarves \
      python3 cpio zstd lz4 xz-utils gzip file device-tree-compiler kmod \
      curl git ca-certificates rsync gcc libc6-dev console-setup-linux musl-tools musl-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
