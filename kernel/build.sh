#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build/kernel}"
CONFIG_FRAGMENT="$PROJECT_DIR/config/kernel_fragment"
KERNEL_CONFIG="${KERNEL_CONFIG:-$PROJECT_DIR/config/debian_kernel_config}"
ORIG_KERNEL_IMAGE="${ORIG_KERNEL_IMAGE:-$PROJECT_DIR/orig/vmlinuz}"

KERNEL_VERSION="${KERNEL_VERSION:-6.12.77}"
KERNEL_BASE_CONFIG="${KERNEL_BASE_CONFIG:-android_avf}"
KERNEL_BUILD_LLVM="${KERNEL_BUILD_LLVM:-auto}"
KERNEL_DISABLE_BTF="${KERNEL_DISABLE_BTF:-1}"
KERNEL_GIT_REPO="${KERNEL_GIT_REPO:-https://android.googlesource.com/kernel/common}"
KERNEL_GIT_REF="${KERNEL_GIT_REF:-android16-6.12.77_r00}"
KERNEL_BUILD_BACKEND="${KERNEL_BUILD_BACKEND:-container}"
DOCKER_CMD="${DOCKER_CMD:-$(command -v podman || command -v docker || true)}"

mkdir -p "$BUILD_DIR"

if [ "$KERNEL_BUILD_BACKEND" = "host" ]; then
    for tool in curl git tar make patch python3; do
        command -v "$tool" >/dev/null || {
            echo "Missing host kernel build tool: $tool" >&2
            exit 1
        }
    done
    if [ "$KERNEL_BUILD_LLVM" = "auto" ]; then
        if [ "$KERNEL_BASE_CONFIG" = "orig_ikconfig" ] || [ "$KERNEL_BASE_CONFIG" = "android_avf" ]; then
            KERNEL_BUILD_LLVM=1
        else
            KERNEL_BUILD_LLVM=0
        fi
    fi
    if [ "$KERNEL_BUILD_LLVM" = "1" ]; then
        for tool in clang ld.lld llvm-objcopy llvm-strip; do
            command -v "$tool" >/dev/null || {
                echo "Missing host LLVM kernel build tool: $tool" >&2
                exit 1
            }
        done
    else
        command -v aarch64-linux-gnu-gcc >/dev/null || {
            echo "Missing host kernel build tool: aarch64-linux-gnu-gcc" >&2
            exit 1
        }
    fi
    if [ "$KERNEL_BASE_CONFIG" = "orig_ikconfig" ] && [ ! -s "$ORIG_KERNEL_IMAGE" ]; then
        echo "Missing original kernel image for config extraction: $ORIG_KERNEL_IMAGE" >&2
        exit 1
    fi

    WORK_DIR="${KERNEL_WORK_DIR:-$BUILD_DIR/work}"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"

    echo "==> Cross-compiling Linux $KERNEL_VERSION for arm64 on host"
    OUTPUT_DIR="$BUILD_DIR" \
    WORK_DIR="$WORK_DIR" \
    CONFIG_FRAGMENT_IN="$CONFIG_FRAGMENT" \
    KERNEL_CONFIG_IN="$KERNEL_CONFIG" \
    ORIG_KERNEL_IMAGE_IN="$ORIG_KERNEL_IMAGE" \
    KERNEL_VERSION="$KERNEL_VERSION" \
    KERNEL_BASE_CONFIG="$KERNEL_BASE_CONFIG" \
    KERNEL_BUILD_LLVM="$KERNEL_BUILD_LLVM" \
    KERNEL_DISABLE_BTF="$KERNEL_DISABLE_BTF" \
    KERNEL_GIT_REPO="$KERNEL_GIT_REPO" \
    KERNEL_GIT_REF="$KERNEL_GIT_REF" \
    bash -s <<'SCRIPT'
set -euo pipefail

cd "$WORK_DIR"
echo "==> Fetching Android common kernel $KERNEL_GIT_REF"
git init linux-src
cd linux-src
git remote add origin "$KERNEL_GIT_REPO"
git fetch --depth=1 origin "$KERNEL_GIT_REF"
git checkout --detach FETCH_HEAD

if [ "$KERNEL_BUILD_LLVM" = "1" ]; then
    MAKE_ARGS=(ARCH=arm64 LLVM=1 LLVM_IAS=1)
else
    MAKE_ARGS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
fi

if [ "$KERNEL_BASE_CONFIG" = "orig_ikconfig" ]; then
    scripts/extract-ikconfig "$ORIG_KERNEL_IMAGE_IN" > .config
elif [ "$KERNEL_BASE_CONFIG" = "android_avf" ]; then
    cp "$KERNEL_CONFIG_IN" .config
else
    make "${MAKE_ARGS[@]}" "$KERNEL_BASE_CONFIG"
fi

if [ "$KERNEL_BASE_CONFIG" != "orig_ikconfig" ] && [ "$KERNEL_BASE_CONFIG" != "android_avf" ]; then
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
    done < "$CONFIG_FRAGMENT_IN"
fi

if [ "$KERNEL_DISABLE_BTF" = "1" ]; then
    scripts/config --disable DEBUG_INFO_BTF
    scripts/config --disable DEBUG_INFO_BTF_MODULES
fi

make "${MAKE_ARGS[@]}" olddefconfig
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
make -j"$(nproc)" "${MAKE_ARGS[@]}" Image Image.gz modules
make --no-print-directory -s "${MAKE_ARGS[@]}" kernelrelease > "$OUTPUT_DIR/kernel.release"
KERNEL_RELEASE="$(cat "$OUTPUT_DIR/kernel.release")"
rm -rf "$OUTPUT_DIR/modules"
make "${MAKE_ARGS[@]}" INSTALL_MOD_PATH="$OUTPUT_DIR/modules" modules_install
find "$OUTPUT_DIR/modules/lib/modules" -type l \( -name build -o -name source \) -delete

rm -rf "$OUTPUT_DIR/headers"
headers_dir="$OUTPUT_DIR/headers/usr/lib/modules/$KERNEL_RELEASE/build"
mkdir -p "$headers_dir"
tar -cf - \
    --exclude='.git' \
    --exclude='*.o' \
    --exclude='*.ko' \
    --exclude='*.mod' \
    --exclude='*.mod.c' \
    --exclude='vmlinux' \
    --exclude='System.map' \
    Makefile Kconfig Module.symvers .config include scripts arch/arm64 |
    tar -C "$headers_dir" -xf -

# Android Terminal feeds $PAYLOAD_DIR/vmlinuz directly to crosvm, which expects
# the raw arm64 Image header rather than a gzip stream.
cp arch/arm64/boot/Image "$OUTPUT_DIR/vmlinuz"
cp arch/arm64/boot/Image.gz "$OUTPUT_DIR/Image.gz"
cp .config "$OUTPUT_DIR/kernel.config"
cat > "$OUTPUT_DIR/kernel.source" <<EOF
KERNEL_VERSION="$KERNEL_VERSION"
KERNEL_GIT_REPO="$KERNEL_GIT_REPO"
KERNEL_GIT_REF="$KERNEL_GIT_REF"
KERNEL_BASE_CONFIG="$KERNEL_BASE_CONFIG"
KERNEL_BUILD_LLVM="$KERNEL_BUILD_LLVM"
KERNEL_DISABLE_BTF="$KERNEL_DISABLE_BTF"
EOF
python3 - <<'PY'
import os
from pathlib import Path

kernel = Path(os.environ["OUTPUT_DIR"], "vmlinuz").read_bytes()
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
elif [ "$KERNEL_BUILD_BACKEND" = "container" ]; then
    [ -n "$DOCKER_CMD" ] || {
        echo "Missing container runtime: install podman or docker, or set KERNEL_BUILD_BACKEND=host" >&2
        exit 1
    }
    echo "==> Building kernel helper image"
    $DOCKER_CMD build -t arch-avf-kernel "$SCRIPT_DIR"

    orig_kernel_mount=()
    if [ "$KERNEL_BASE_CONFIG" = "orig_ikconfig" ]; then
        [ -s "$ORIG_KERNEL_IMAGE" ] || {
            echo "Missing original kernel image for config extraction: $ORIG_KERNEL_IMAGE" >&2
            exit 1
        }
        orig_kernel_mount=(-v "$ORIG_KERNEL_IMAGE:/config/orig_vmlinuz:ro")
    fi

    echo "==> Cross-compiling Linux $KERNEL_VERSION for arm64"
    $DOCKER_CMD run --rm -i \
        -v "$BUILD_DIR:/output" \
        -v "$CONFIG_FRAGMENT:/config/kernel_fragment:ro" \
        -v "$KERNEL_CONFIG:/config/kernel_config:ro" \
        "${orig_kernel_mount[@]}" \
        -e KERNEL_VERSION="$KERNEL_VERSION" \
        -e KERNEL_BASE_CONFIG="$KERNEL_BASE_CONFIG" \
        -e KERNEL_BUILD_LLVM="$KERNEL_BUILD_LLVM" \
        -e KERNEL_DISABLE_BTF="$KERNEL_DISABLE_BTF" \
        -e KERNEL_GIT_REPO="$KERNEL_GIT_REPO" \
        -e KERNEL_GIT_REF="$KERNEL_GIT_REF" \
        arch-avf-kernel bash -s <<'SCRIPT'
set -euo pipefail

cd /work
echo "==> Fetching Android common kernel $KERNEL_GIT_REF"
git init linux-src
cd linux-src
git remote add origin "$KERNEL_GIT_REPO"
git fetch --depth=1 origin "$KERNEL_GIT_REF"
git checkout --detach FETCH_HEAD

if [ "$KERNEL_BUILD_LLVM" = "auto" ]; then
    if [ "$KERNEL_BASE_CONFIG" = "orig_ikconfig" ] || [ "$KERNEL_BASE_CONFIG" = "android_avf" ]; then
        KERNEL_BUILD_LLVM=1
    else
        KERNEL_BUILD_LLVM=0
    fi
fi
if [ "$KERNEL_BUILD_LLVM" = "1" ]; then
    MAKE_ARGS=(ARCH=arm64 LLVM=1 LLVM_IAS=1)
else
    MAKE_ARGS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
fi

if [ "$KERNEL_BASE_CONFIG" = "orig_ikconfig" ]; then
    scripts/extract-ikconfig /config/orig_vmlinuz > .config
elif [ "$KERNEL_BASE_CONFIG" = "android_avf" ]; then
    cp /config/kernel_config .config
else
    make "${MAKE_ARGS[@]}" "$KERNEL_BASE_CONFIG"
fi

if [ "$KERNEL_BASE_CONFIG" != "orig_ikconfig" ] && [ "$KERNEL_BASE_CONFIG" != "android_avf" ]; then
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

if [ "$KERNEL_DISABLE_BTF" = "1" ]; then
    scripts/config --disable DEBUG_INFO_BTF
    scripts/config --disable DEBUG_INFO_BTF_MODULES
fi

make "${MAKE_ARGS[@]}" olddefconfig
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
make -j"$(nproc)" "${MAKE_ARGS[@]}" Image Image.gz modules
make --no-print-directory -s "${MAKE_ARGS[@]}" kernelrelease > /output/kernel.release
KERNEL_RELEASE="$(cat /output/kernel.release)"
rm -rf /output/modules
make "${MAKE_ARGS[@]}" INSTALL_MOD_PATH=/output/modules modules_install
find /output/modules/lib/modules -type l \( -name build -o -name source \) -delete

rm -rf /output/headers
headers_dir="/output/headers/usr/lib/modules/$KERNEL_RELEASE/build"
mkdir -p "$headers_dir"
tar -cf - \
    --exclude='.git' \
    --exclude='*.o' \
    --exclude='*.ko' \
    --exclude='*.mod' \
    --exclude='*.mod.c' \
    --exclude='vmlinux' \
    --exclude='System.map' \
    Makefile Kconfig Module.symvers .config include scripts arch/arm64 |
    tar -C "$headers_dir" -xf -

# Android Terminal feeds $PAYLOAD_DIR/vmlinuz directly to crosvm, which expects
# the raw arm64 Image header rather than a gzip stream.
cp arch/arm64/boot/Image /output/vmlinuz
cp arch/arm64/boot/Image.gz /output/Image.gz
cp .config /output/kernel.config
cat > /output/kernel.source <<EOF
KERNEL_VERSION="$KERNEL_VERSION"
KERNEL_GIT_REPO="$KERNEL_GIT_REPO"
KERNEL_GIT_REF="$KERNEL_GIT_REF"
KERNEL_BASE_CONFIG="$KERNEL_BASE_CONFIG"
KERNEL_BUILD_LLVM="$KERNEL_BUILD_LLVM"
KERNEL_DISABLE_BTF="$KERNEL_DISABLE_BTF"
EOF
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
else
    echo "Unsupported KERNEL_BUILD_BACKEND: $KERNEL_BUILD_BACKEND" >&2
    exit 1
fi

cp "$BUILD_DIR/vmlinuz" "$PROJECT_DIR/build/vmlinuz"
ls -lh "$BUILD_DIR/vmlinuz" "$BUILD_DIR/kernel.release" "$BUILD_DIR/kernel.source"
