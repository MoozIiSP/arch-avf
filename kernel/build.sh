#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build/kernel}"
CONFIG_FRAGMENT="$PROJECT_DIR/config/kernel_fragment"
DEBIAN_KERNEL_CONFIG="$PROJECT_DIR/config/debian_kernel_config"

KERNEL_VERSION="${KERNEL_VERSION:-6.12.60}"
KERNEL_MAJOR="${KERNEL_MAJOR:-6.x}"
KERNEL_BASE_CONFIG="${KERNEL_BASE_CONFIG:-debian_avf}"
KERNEL_TARBALL_URL="${KERNEL_TARBALL_URL:-https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz}"
ANDROID_VIRT_REPO="${ANDROID_VIRT_REPO:-https://android.googlesource.com/platform/packages/modules/Virtualization}"
ANDROID_VIRT_REV="${ANDROID_VIRT_REV:-android-16.0.0_r3}"
APPLY_AVF_PATCHES="${APPLY_AVF_PATCHES:-auto}"

mkdir -p "$BUILD_DIR"

echo "==> Building kernel helper image"
docker build -t arch-avf-kernel "$SCRIPT_DIR"

echo "==> Cross-compiling Linux $KERNEL_VERSION for arm64"
docker run --rm -i \
    -v "$BUILD_DIR:/output" \
    -v "$CONFIG_FRAGMENT:/config/kernel_fragment:ro" \
    -v "$DEBIAN_KERNEL_CONFIG:/config/debian_kernel_config:ro" \
    -e KERNEL_VERSION="$KERNEL_VERSION" \
    -e KERNEL_TARBALL_URL="$KERNEL_TARBALL_URL" \
    -e KERNEL_BASE_CONFIG="$KERNEL_BASE_CONFIG" \
    -e ANDROID_VIRT_REPO="$ANDROID_VIRT_REPO" \
    -e ANDROID_VIRT_REV="$ANDROID_VIRT_REV" \
    -e APPLY_AVF_PATCHES="$APPLY_AVF_PATCHES" \
    arch-avf-kernel bash -s <<'SCRIPT'
set -euo pipefail

cd /work
curl -fL "$KERNEL_TARBALL_URL" -o linux.tar.xz
tar -xf linux.tar.xz
cd "linux-$KERNEL_VERSION"

if [ "$APPLY_AVF_PATCHES" = "auto" ]; then
    case "$KERNEL_VERSION" in
        6.1.*) APPLY_AVF_PATCHES=1 ;;
        *) APPLY_AVF_PATCHES=0 ;;
    esac
fi

if [ "$APPLY_AVF_PATCHES" = "1" ]; then
    git clone --depth=1 --branch "$ANDROID_VIRT_REV" "$ANDROID_VIRT_REPO" /work/Virtualization
    for patch_file in \
        /work/Virtualization/build/debian/kernel/patches/avf/arm64-balloon.patch \
        /work/Virtualization/build/debian/kernel/patches/avf/virtual-cpufreq.patch
    do
        [ -f "$patch_file" ] || { echo "Missing AVF kernel patch: $patch_file" >&2; exit 1; }
        patch -p1 < "$patch_file"
    done
else
    echo "==> Skipping Android AVF patch set for Linux $KERNEL_VERSION"
fi

if [ "$KERNEL_BASE_CONFIG" = "debian_avf" ]; then
    cp /config/debian_kernel_config .config
    scripts/config --set-str LOCALVERSION "-arch-avf"
else
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "$KERNEL_BASE_CONFIG"
fi

if [ "$KERNEL_BASE_CONFIG" != "debian_avf" ]; then
    while IFS= read -r line; do
        case "$line" in
            ""|\#*) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        case "$value" in
            y) ./scripts/config --enable "${key#CONFIG_}" ;;
            m) ./scripts/config --module "${key#CONFIG_}" ;;
            n) ./scripts/config --disable "${key#CONFIG_}" ;;
            \"*\") ./scripts/config --set-str "${key#CONFIG_}" "${value:1:${#value}-2}" ;;
            [0-9]*) ./scripts/config --set-val "${key#CONFIG_}" "$value" ;;
            *) printf 'Unsupported kernel config line: %s\n' "$line" >&2; exit 1 ;;
        esac
    done < /config/kernel_fragment
fi

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
for required_config in \
    CONFIG_BINFMT_ELF \
    CONFIG_BINFMT_SCRIPT \
    CONFIG_ARM64_BTI \
    CONFIG_ARM64_PTR_AUTH \
    CONFIG_CGROUPS \
    CONFIG_DEVTMPFS_MOUNT \
    CONFIG_EXT4_FS \
    CONFIG_KEYS \
    CONFIG_PROC_FS \
    CONFIG_SECCOMP \
    CONFIG_SECCOMP_FILTER \
    CONFIG_SHMEM \
    CONFIG_TMPFS \
    CONFIG_VIRTIO_BLK
do
    grep -qx "$required_config=y" .config || { echo "Missing required kernel config: $required_config" >&2; exit 1; }
done
make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image Image.gz modules
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease > /output/kernel.release
rm -rf /output/modules
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=/output/modules modules_install
find /output/modules/lib/modules -type l \( -name build -o -name source \) -delete

# Android Terminal feeds $PAYLOAD_DIR/vmlinuz directly to crosvm, which expects
# the raw arm64 Image header rather than a gzip stream.
cp arch/arm64/boot/Image /output/vmlinuz
cp arch/arm64/boot/Image /output/BOOTAA64.EFI
cp .config /output/kernel.config
python3 - <<'PY'
from pathlib import Path

kernel = Path("/output/vmlinuz").read_bytes()
if len(kernel) < 64:
    raise SystemExit("Kernel image is unexpectedly short")
if kernel[:2] == b"\x1f\x8b":
    raise SystemExit("Refusing to publish gzip-compressed kernel as vmlinuz")
if kernel[56:60] != b"ARM\x64":
    raise SystemExit(
        f"Unexpected arm64 Image magic at offset 56: {kernel[56:60]!r}"
    )
PY
SCRIPT

cp "$BUILD_DIR/vmlinuz" "$PROJECT_DIR/build/vmlinuz"
cp "$BUILD_DIR/BOOTAA64.EFI" "$PROJECT_DIR/build/BOOTAA64.EFI"
ls -lh "$BUILD_DIR/vmlinuz" "$BUILD_DIR/BOOTAA64.EFI" "$BUILD_DIR/kernel.release"
