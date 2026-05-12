#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build/kernel}"
CONFIG_FRAGMENT="$PROJECT_DIR/config/kernel_fragment"
KERNEL_CONFIG="${KERNEL_CONFIG:-$PROJECT_DIR/config/debian_kernel_config}"
ORIG_KERNEL_IMAGE="${ORIG_KERNEL_IMAGE:-$PROJECT_DIR/orig/vmlinuz}"

KERNEL_VERSION="${KERNEL_VERSION:-6.12.77}"
KERNEL_MAJOR="${KERNEL_MAJOR:-6.x}"
KERNEL_BASE_CONFIG="${KERNEL_BASE_CONFIG:-android_avf}"
KERNEL_BUILD_LLVM="${KERNEL_BUILD_LLVM:-auto}"
KERNEL_DISABLE_BTF="${KERNEL_DISABLE_BTF:-1}"
KERNEL_SOURCE="${KERNEL_SOURCE:-android_common}"
KERNEL_GIT_REPO="${KERNEL_GIT_REPO:-https://android.googlesource.com/kernel/common}"
KERNEL_GIT_REF="${KERNEL_GIT_REF:-android16-6.12.77_r00}"
KERNEL_TARBALL_URL="${KERNEL_TARBALL_URL:-https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz}"
ANDROID_VIRT_REPO="${ANDROID_VIRT_REPO:-https://android.googlesource.com/platform/packages/modules/Virtualization}"
ANDROID_VIRT_REV="${ANDROID_VIRT_REV:-android-16.0.0_r3}"
APPLY_AVF_PATCHES="${APPLY_AVF_PATCHES:-auto}"
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
    KERNEL_TARBALL_URL="$KERNEL_TARBALL_URL" \
    KERNEL_BASE_CONFIG="$KERNEL_BASE_CONFIG" \
    KERNEL_BUILD_LLVM="$KERNEL_BUILD_LLVM" \
    KERNEL_DISABLE_BTF="$KERNEL_DISABLE_BTF" \
    KERNEL_SOURCE="$KERNEL_SOURCE" \
    KERNEL_GIT_REPO="$KERNEL_GIT_REPO" \
    KERNEL_GIT_REF="$KERNEL_GIT_REF" \
    ANDROID_VIRT_REPO="$ANDROID_VIRT_REPO" \
    ANDROID_VIRT_REV="$ANDROID_VIRT_REV" \
    APPLY_AVF_PATCHES="$APPLY_AVF_PATCHES" \
    bash -s <<'SCRIPT'
set -euo pipefail

cd "$WORK_DIR"
case "$KERNEL_SOURCE" in
    android_common)
        echo "==> Fetching Android common kernel $KERNEL_GIT_REF"
        git init linux-src
        cd linux-src
        git remote add origin "$KERNEL_GIT_REPO"
        git fetch --depth=1 origin "$KERNEL_GIT_REF"
        git checkout --detach FETCH_HEAD
        ;;
    tarball)
        echo "==> Fetching upstream kernel tarball $KERNEL_VERSION"
        curl -fL "$KERNEL_TARBALL_URL" -o linux.tar.xz
        tar -xf linux.tar.xz
        cd "linux-$KERNEL_VERSION"
        ;;
    *)
        echo "Unsupported KERNEL_SOURCE: $KERNEL_SOURCE" >&2
        exit 1
        ;;
esac

if [ "$APPLY_AVF_PATCHES" = "auto" ]; then
    if [ "$KERNEL_SOURCE" = "android_common" ]; then
        APPLY_AVF_PATCHES=0
    else
        case "$KERNEL_VERSION" in
            6.1.*) APPLY_AVF_PATCHES=1 ;;
            *) APPLY_AVF_PATCHES=0 ;;
        esac
    fi
fi

if [ "$APPLY_AVF_PATCHES" = "1" ]; then
    git clone --depth=1 --branch "$ANDROID_VIRT_REV" "$ANDROID_VIRT_REPO" "$WORK_DIR/Virtualization"
    for patch_file in \
        "$WORK_DIR/Virtualization/build/debian/kernel/patches/avf/arm64-balloon.patch" \
        "$WORK_DIR/Virtualization/build/debian/kernel/patches/avf/virtual-cpufreq.patch"
    do
        [ -f "$patch_file" ] || { echo "Missing AVF kernel patch: $patch_file" >&2; exit 1; }
        patch -p1 < "$patch_file"
    done
else
    echo "==> Skipping Android AVF patch set for Linux $KERNEL_VERSION"
fi

if [ "$KERNEL_BUILD_LLVM" = "1" ]; then
    MAKE_ARGS=(ARCH=arm64 LLVM=1 LLVM_IAS=1)
else
    MAKE_ARGS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
fi

if [ "$KERNEL_BASE_CONFIG" = "orig_ikconfig" ]; then
    scripts/extract-ikconfig "$ORIG_KERNEL_IMAGE_IN" > .config
elif [ "$KERNEL_BASE_CONFIG" = "android_avf" ]; then
    cp "$KERNEL_CONFIG_IN" .config
elif [ "$KERNEL_BASE_CONFIG" = "debian_avf" ]; then
    cp "$KERNEL_CONFIG_IN" .config
    scripts/config --set-str LOCALVERSION "-arch-avf"
else
    make "${MAKE_ARGS[@]}" "$KERNEL_BASE_CONFIG"
fi

if [ "$KERNEL_BASE_CONFIG" != "debian_avf" ] && [ "$KERNEL_BASE_CONFIG" != "orig_ikconfig" ] && [ "$KERNEL_BASE_CONFIG" != "android_avf" ]; then
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
rm -rf "$OUTPUT_DIR/modules"
make "${MAKE_ARGS[@]}" INSTALL_MOD_PATH="$OUTPUT_DIR/modules" modules_install
find "$OUTPUT_DIR/modules/lib/modules" -type l \( -name build -o -name source \) -delete

# Android Terminal feeds $PAYLOAD_DIR/vmlinuz directly to crosvm, which expects
# the raw arm64 Image header rather than a gzip stream.
cp arch/arm64/boot/Image "$OUTPUT_DIR/vmlinuz"
cp .config "$OUTPUT_DIR/kernel.config"
cat > "$OUTPUT_DIR/kernel.source" <<EOF
KERNEL_VERSION="$KERNEL_VERSION"
KERNEL_SOURCE="$KERNEL_SOURCE"
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
        -e KERNEL_TARBALL_URL="$KERNEL_TARBALL_URL" \
        -e KERNEL_BASE_CONFIG="$KERNEL_BASE_CONFIG" \
        -e KERNEL_BUILD_LLVM="$KERNEL_BUILD_LLVM" \
        -e KERNEL_DISABLE_BTF="$KERNEL_DISABLE_BTF" \
        -e KERNEL_SOURCE="$KERNEL_SOURCE" \
        -e KERNEL_GIT_REPO="$KERNEL_GIT_REPO" \
        -e KERNEL_GIT_REF="$KERNEL_GIT_REF" \
        -e ANDROID_VIRT_REPO="$ANDROID_VIRT_REPO" \
        -e ANDROID_VIRT_REV="$ANDROID_VIRT_REV" \
        -e APPLY_AVF_PATCHES="$APPLY_AVF_PATCHES" \
        arch-avf-kernel bash -s <<'SCRIPT'
set -euo pipefail

cd /work
case "$KERNEL_SOURCE" in
    android_common)
        echo "==> Fetching Android common kernel $KERNEL_GIT_REF"
        git init linux-src
        cd linux-src
        git remote add origin "$KERNEL_GIT_REPO"
        git fetch --depth=1 origin "$KERNEL_GIT_REF"
        git checkout --detach FETCH_HEAD
        ;;
    tarball)
        echo "==> Fetching upstream kernel tarball $KERNEL_VERSION"
        curl -fL "$KERNEL_TARBALL_URL" -o linux.tar.xz
        tar -xf linux.tar.xz
        cd "linux-$KERNEL_VERSION"
        ;;
    *)
        echo "Unsupported KERNEL_SOURCE: $KERNEL_SOURCE" >&2
        exit 1
        ;;
esac

if [ "$APPLY_AVF_PATCHES" = "auto" ]; then
    if [ "$KERNEL_SOURCE" = "android_common" ]; then
        APPLY_AVF_PATCHES=0
    else
        case "$KERNEL_VERSION" in
            6.1.*) APPLY_AVF_PATCHES=1 ;;
            *) APPLY_AVF_PATCHES=0 ;;
        esac
    fi
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
elif [ "$KERNEL_BASE_CONFIG" = "debian_avf" ]; then
    cp /config/kernel_config .config
    scripts/config --set-str LOCALVERSION "-arch-avf"
else
    make "${MAKE_ARGS[@]}" "$KERNEL_BASE_CONFIG"
fi

if [ "$KERNEL_BASE_CONFIG" != "debian_avf" ] && [ "$KERNEL_BASE_CONFIG" != "orig_ikconfig" ] && [ "$KERNEL_BASE_CONFIG" != "android_avf" ]; then
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
rm -rf /output/modules
make "${MAKE_ARGS[@]}" INSTALL_MOD_PATH=/output/modules modules_install
find /output/modules/lib/modules -type l \( -name build -o -name source \) -delete

# Android Terminal feeds $PAYLOAD_DIR/vmlinuz directly to crosvm, which expects
# the raw arm64 Image header rather than a gzip stream.
cp arch/arm64/boot/Image /output/vmlinuz
cp .config /output/kernel.config
cat > /output/kernel.source <<EOF
KERNEL_VERSION="$KERNEL_VERSION"
KERNEL_SOURCE="$KERNEL_SOURCE"
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
