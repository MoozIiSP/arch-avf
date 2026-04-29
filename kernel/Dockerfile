FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        bc \
        bison \
        build-essential \
        ca-certificates \
        cpio \
        curl \
        flex \
        gcc-aarch64-linux-gnu \
        git \
        kmod \
        libelf-dev \
        libssl-dev \
        make \
        patch \
        python3 \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
