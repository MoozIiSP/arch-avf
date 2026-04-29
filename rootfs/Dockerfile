FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libarchive-tools \
        qemu-user-static \
        sudo \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
