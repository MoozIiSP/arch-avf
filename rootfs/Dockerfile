FROM archlinux:latest

RUN pacman -Syu --noconfirm \
        arch-install-scripts \
        bsdtar \
        curl \
        dosfstools \
        e2fsprogs \
        qemu-user-static \
        qemu-user-static-binfmt \
        sudo \
    && pacman -Scc --noconfirm

WORKDIR /work
