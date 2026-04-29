#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build/kernel}"
CONFIG_FRAGMENT="$PROJECT_DIR/config/kernel_fragment"

KERNEL_VERSION="${KERNEL_VERSION:-6.1.169}"
KERNEL_MAJOR="${KERNEL_MAJOR:-6.x}"
KERNEL_TARBALL_URL="${KERNEL_TARBALL_URL:-https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz}"
ANDROID_VIRT_REPO="${ANDROID_VIRT_REPO:-https://android.googlesource.com/platform/packages/modules/Virtualization}"
ANDROID_VIRT_REV="${ANDROID_VIRT_REV:-android-16.0.0_r3}"
APPLY_AVF_PATCHES="${APPLY_AVF_PATCHES:-1}"

mkdir -p "$BUILD_DIR"

echo "==> Building kernel helper image"
docker build -t arch-avf-kernel "$SCRIPT_DIR"

echo "==> Cross-compiling Linux $KERNEL_VERSION for arm64"
docker run --rm -i \
    -v "$BUILD_DIR:/output" \
    -v "$CONFIG_FRAGMENT:/config/kernel_fragment:ro" \
    -e KERNEL_VERSION="$KERNEL_VERSION" \
    -e KERNEL_TARBALL_URL="$KERNEL_TARBALL_URL" \
    -e ANDROID_VIRT_REPO="$ANDROID_VIRT_REPO" \
    -e ANDROID_VIRT_REV="$ANDROID_VIRT_REV" \
    -e APPLY_AVF_PATCHES="$APPLY_AVF_PATCHES" \
    arch-avf-kernel bash -s <<'SCRIPT'
set -euo pipefail

cd /work
curl -fL "$KERNEL_TARBALL_URL" -o linux.tar.xz
tar -xf linux.tar.xz
cd "linux-$KERNEL_VERSION"

if [ "$APPLY_AVF_PATCHES" = "1" ]; then
    git clone --depth=1 --branch "$ANDROID_VIRT_REV" "$ANDROID_VIRT_REPO" /work/Virtualization
    for patch_file in \
        /work/Virtualization/build/debian/kernel/patches/avf/arm64-balloon.patch \
        /work/Virtualization/build/debian/kernel/patches/avf/virtual-cpufreq.patch
    do
        [ -f "$patch_file" ] || { echo "Missing AVF kernel patch: $patch_file" >&2; exit 1; }
        patch -p1 < "$patch_file"
    done
fi

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig

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

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -j"$(nproc)" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image Image.gz modules
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- kernelrelease > /output/kernel.release
rm -rf /output/modules
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=/output/modules INSTALL_MOD_STRIP=1 modules_install

# crosvm's arm64 direct-kernel loader expects the raw Image format.
cp arch/arm64/boot/Image /output/vmlinuz
cp arch/arm64/boot/Image /output/BOOTAA64.EFI
cp .config /output/kernel.config
SCRIPT

cp "$BUILD_DIR/vmlinuz" "$PROJECT_DIR/build/vmlinuz"
cp "$BUILD_DIR/BOOTAA64.EFI" "$PROJECT_DIR/build/BOOTAA64.EFI"
ls -lh "$BUILD_DIR/vmlinuz" "$BUILD_DIR/BOOTAA64.EFI" "$BUILD_DIR/kernel.release"
