#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build/rootfs}"
ROOTFS_DIR="$BUILD_DIR/rootfs"
CACHE_DIR="$BUILD_DIR/cache"
OUTPUT="$BUILD_DIR/rootfs.tar.gz"
INITRD_OUT="$BUILD_DIR/initrd.img"
KERNEL_MODULES_DIR="${KERNEL_MODULES_DIR:-$PROJECT_DIR/build/kernel/modules}"
KERNEL_RELEASE_FILE="${KERNEL_RELEASE_FILE:-$PROJECT_DIR/build/kernel/kernel.release}"
ANDROID_SERVICES_DIR="${ANDROID_SERVICES_DIR:-$PROJECT_DIR/build/android-services/out}"
OVERLAY_DIR="$SCRIPT_DIR/overlay"

ALARM_TARBALL_URL="${ALARM_TARBALL_URL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
DROID_USER="${DROID_USER:-droid}"
DROID_PASSWORD="${DROID_PASSWORD:-droid}"

[ -d "$KERNEL_MODULES_DIR/lib/modules" ] || { echo "Missing kernel modules: $KERNEL_MODULES_DIR/lib/modules. Run make kernel first." >&2; exit 1; }
[ -f "$KERNEL_RELEASE_FILE" ] || { echo "Missing kernel release file: $KERNEL_RELEASE_FILE. Run make kernel first." >&2; exit 1; }

mkdir -p "$BUILD_DIR" "$CACHE_DIR" "$ANDROID_SERVICES_DIR"

echo "==> Building rootfs helper image"
docker build -t arch-avf-rootfs "$SCRIPT_DIR"

echo "==> Creating Arch Linux ARM rootfs"
docker run --rm -i --privileged \
    -v "$BUILD_DIR:/build" \
    -v "$SCRIPT_DIR/packages.txt:/packages.txt:ro" \
    -v "$KERNEL_MODULES_DIR:/kernel_modules:ro" \
    -v "$KERNEL_RELEASE_FILE:/kernel_release:ro" \
    -v "$ANDROID_SERVICES_DIR:/android-services:ro" \
    -v "$OVERLAY_DIR:/overlay:ro" \
    -e ALARM_TARBALL_URL="$ALARM_TARBALL_URL" \
    -e ROOT_PASSWORD="$ROOT_PASSWORD" \
    -e DROID_USER="$DROID_USER" \
    -e DROID_PASSWORD="$DROID_PASSWORD" \
    arch-avf-rootfs bash -s <<'SCRIPT'
set -euo pipefail

ROOTFS_DIR=/build/rootfs
CACHE_DIR=/build/cache
TARBALL="$CACHE_DIR/ArchLinuxARM-aarch64-latest.tar.gz"
PACKAGES="$(tr '\n' ' ' < /packages.txt)"
KERNEL_RELEASE="$(cat /kernel_release)"

rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR" "$CACHE_DIR"

if [ ! -s "$TARBALL" ]; then
    curl -fL "$ALARM_TARBALL_URL" -o "$TARBALL"
fi

bsdtar -xpf "$TARBALL" -C "$ROOTFS_DIR"

rm -f "$ROOTFS_DIR/etc/resolv.conf"
install -Dm644 /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
# Docker chroots can confuse pacman's mount lookup for /var/cache/pacman/pkg.
sed -i 's/^[[:space:]]*CheckSpace/#CheckSpace/' "$ROOTFS_DIR/etc/pacman.conf"
cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"
mountpoint -q "$ROOTFS_DIR/proc" || mount -t proc proc "$ROOTFS_DIR/proc"
mountpoint -q "$ROOTFS_DIR/sys" || mount --rbind /sys "$ROOTFS_DIR/sys"
mountpoint -q "$ROOTFS_DIR/dev" || mount --rbind /dev "$ROOTFS_DIR/dev"
mountpoint -q "$ROOTFS_DIR/run" || mount --rbind /run "$ROOTFS_DIR/run"
cleanup() {
    umount -R "$ROOTFS_DIR/run" 2>/dev/null || true
    umount -R "$ROOTFS_DIR/dev" 2>/dev/null || true
    umount -R "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount -R "$ROOTFS_DIR/proc" 2>/dev/null || true
}
trap cleanup EXIT

chroot "$ROOTFS_DIR" /bin/bash -eux <<CHROOT
pacman_retry() {
    local attempt
    for attempt in 1 2 3; do
        if pacman "\$@"; then
            return 0
        fi
        sleep "\$((attempt * 10))"
        pacman -Sy --noconfirm || true
    done
    pacman "\$@"
}
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Rns --noconfirm linux-aarch64 linux-firmware || true
pacman_retry -Syu --noconfirm
pacman_retry -S --needed --noconfirm $PACKAGES
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo archlinux > /etc/hostname
printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
if ! getent group 100 >/dev/null; then
    groupadd -g 100 android
fi
primary_group="\$(getent group 100 | cut -d: -f1)"
existing_uid1000="\$(getent passwd 1000 | cut -d: -f1 || true)"
if id -u "$DROID_USER" >/dev/null 2>&1; then
    usermod -u 1000 -g "\$primary_group" -s /usr/bin/bash "$DROID_USER"
elif [ -n "\$existing_uid1000" ]; then
    usermod -l "$DROID_USER" -d /home/"$DROID_USER" -m -g "\$primary_group" -s /usr/bin/bash "\$existing_uid1000"
else
    useradd -m -u 1000 -g "\$primary_group" -s /usr/bin/bash "$DROID_USER"
fi
printf '%s:%s\n' "$DROID_USER" "$DROID_PASSWORD" | chpasswd
for group in wheel sudo video render seat; do
    getent group "\$group" >/dev/null && usermod -aG "\$group" "$DROID_USER"
done
echo "$DROID_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/10-avf-droid
chmod 0440 /etc/sudoers.d/10-avf-droid
cat >> /home/"$DROID_USER"/.bashrc <<'EOF'
# Match Android Terminal's Debian shell title behavior.
trap 'echo -ne "\e]0;$BASH_COMMAND\007"' DEBUG
EOF
chown "$DROID_USER:100" /home/"$DROID_USER"/.bashrc
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
locale-gen
CHROOT

mkdir -p "$ROOTFS_DIR/usr/lib/modules"
cp -a /kernel_modules/lib/modules/. "$ROOTFS_DIR/usr/lib/modules/"
chroot "$ROOTFS_DIR" depmod "$KERNEL_RELEASE"
rm -rf "$ROOTFS_DIR/var/cache/pacman/pkg/"*

cp -a /overlay/. "$ROOTFS_DIR/"
chmod 0755 "$ROOTFS_DIR/usr/local/lib/avf/make-ttyd-cert"
chmod 0755 "$ROOTFS_DIR/usr/local/bin/enable_display"
find "$ROOTFS_DIR/etc/systemd/system" -type f -name '*.service' -exec sed -i "s/@DROID_USER@/$DROID_USER/g" {} +
mkdir -p "$ROOTFS_DIR/usr/lib/avf"
for binary in forwarder_guest forwarder_guest_launcher storage_balloon_agent shutdown_runner; do
    if [ -x "/android-services/$binary" ]; then
        install -Dm755 "/android-services/$binary" "$ROOTFS_DIR/usr/lib/avf/$binary"
    fi
done

cat > "$ROOTFS_DIR/etc/fstab" <<'EOF'
LABEL=archlinux / ext4 rw,noatime 0 1
LABEL=ESP /boot vfat rw,noatime,nofail 0 2
EOF

install -d "$ROOTFS_DIR/etc/ssh/sshd_config.d" "$ROOTFS_DIR/etc/sudoers.d"
cat > "$ROOTFS_DIR/etc/ssh/sshd_config.d/10-avf.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
cat > "$ROOTFS_DIR/etc/sudoers.d/10-avf-wheel" <<'EOF'
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
chmod 0440 "$ROOTFS_DIR/etc/sudoers.d/10-avf-wheel"

mkdir -p "$ROOTFS_DIR/etc/systemd/resolved.conf.d"
cat > "$ROOTFS_DIR/etc/systemd/resolved.conf.d/10-avf.conf" <<'EOF'
[Resolve]
LLMNR=no
EOF

mkdir -p "$ROOTFS_DIR/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$ROOTFS_DIR/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty -o '-p -- \\u' --keep-baud 115200,57600,38400,9600 %I dumb
EOF

mkdir -p "$ROOTFS_DIR/etc/NetworkManager/conf.d"
cat > "$ROOTFS_DIR/etc/NetworkManager/conf.d/00-avf.conf" <<'EOF'
[main]
plugins=keyfile

[connection]
ipv6.ip6-privacy=0
EOF

cat > "$ROOTFS_DIR/etc/mkinitcpio.conf" <<'EOF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev block filesystems fsck)
EOF

chroot "$ROOTFS_DIR" /bin/bash -eux <<CHROOT
systemctl enable \
    sshd.service \
    NetworkManager.service \
    systemd-resolved.service \
    serial-getty@ttyS0.service \
    seatd.service \
    virtiofs_internal.service \
    virtiofs.service \
    backup_mount.service \
    storage_balloon_agent.service \
    forwarder_guest_launcher.service \
    shutdown_runner.service \
    ttyd.service \
    avahi-daemon.service \
    avahi_ttyd.service
systemctl set-default multi-user.target
rm -f /etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service
mkinitcpio -k "$KERNEL_RELEASE" -g /boot/initrd.img
CHROOT
cp "$ROOTFS_DIR/boot/initrd.img" /build/initrd.img
rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
rm -f "$ROOTFS_DIR/etc/pacman.d/gnupg/S.gpg-agent"*
cleanup
trap - EXIT
tar --numeric-owner -czf /build/rootfs.tar.gz -C "$ROOTFS_DIR" .
chmod 0644 /build/initrd.img /build/rootfs.tar.gz
SCRIPT

echo "==> Rootfs archive"
[ -f "$OUTPUT" ] || { echo "Missing rootfs archive: $OUTPUT" >&2; exit 1; }
cp "$INITRD_OUT" "$PROJECT_DIR/build/initrd.img"
ls -lh "$OUTPUT" "$PROJECT_DIR/build/initrd.img"
