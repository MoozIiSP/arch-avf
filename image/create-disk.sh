#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build/image}"
ROOTFS_TAR="${ROOTFS_TAR:-$PROJECT_DIR/build/rootfs/rootfs.tar.gz}"
KERNEL="${KERNEL:-$PROJECT_DIR/build/kernel/vmlinuz}"
KERNEL_EFI="${KERNEL_EFI:-$PROJECT_DIR/build/kernel/BOOTAA64.EFI}"
INITRD="${INITRD:-$PROJECT_DIR/build/initrd.img}"

EFI_SIZE_MB="${EFI_SIZE_MB:-100}"
ROOT_SIZE_MB="${ROOT_SIZE_MB:-8192}"

DISK_IMG="$BUILD_DIR/disk.img"
ROOT_PART="$BUILD_DIR/root_part"
EFI_PART="$BUILD_DIR/efi_part"

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require awk
require dd
require losetup
require mkfs.ext4
require mkfs.vfat
require python3
require sfdisk
require sudo
require tar
require truncate

[ -f "$ROOTFS_TAR" ] || { echo "Missing rootfs tarball: $ROOTFS_TAR" >&2; exit 1; }
[ -f "$KERNEL" ] || { echo "Missing kernel: $KERNEL" >&2; exit 1; }
[ -f "$KERNEL_EFI" ] || { echo "Missing EFI kernel stub: $KERNEL_EFI" >&2; exit 1; }
[ -f "$INITRD" ] || { echo "Missing initrd: $INITRD" >&2; exit 1; }

mkdir -p "$BUILD_DIR"
rm -f "$DISK_IMG" "$ROOT_PART" "$EFI_PART"

TOTAL_SIZE_MB=$((EFI_SIZE_MB + ROOT_SIZE_MB + 16))

echo "==> Creating ${TOTAL_SIZE_MB} MiB raw GPT disk image"
truncate -s "${TOTAL_SIZE_MB}M" "$DISK_IMG"
SECTORS_PER_MIB=2048
ROOT_START=$((1 * SECTORS_PER_MIB))
ROOT_SECTORS=$((ROOT_SIZE_MB * SECTORS_PER_MIB))
EFI_START=$(((ROOT_SIZE_MB + 1) * SECTORS_PER_MIB))
EFI_SECTORS=$((EFI_SIZE_MB * SECTORS_PER_MIB))
sfdisk "$DISK_IMG" <<EOF
label: gpt
start=${ROOT_START}, size=${ROOT_SECTORS}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="archlinux"
start=${EFI_START}, size=${EFI_SECTORS}, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP"
EOF

LOOP_DEV=""
EFI_MNT="$(mktemp -d)"
ROOT_MNT="$(mktemp -d)"
cleanup() {
    sudo umount "$ROOT_MNT" 2>/dev/null || true
    sudo umount "$EFI_MNT" 2>/dev/null || true
    if [ -n "$LOOP_DEV" ]; then
        sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    rmdir "$ROOT_MNT" "$EFI_MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Attaching loop device"
LOOP_DEV="$(sudo losetup --find --partscan --show "$DISK_IMG")"
ROOT_DEV="${LOOP_DEV}p1"
EFI_DEV="${LOOP_DEV}p2"

echo "==> Formatting partitions"
sudo mkfs.vfat -F 32 -n ESP "$EFI_DEV"
sudo mkfs.ext4 -F -L archlinux "$ROOT_DEV"

echo "==> Populating EFI partition"
sudo mount "$EFI_DEV" "$EFI_MNT"
sudo mkdir -p "$EFI_MNT/EFI/BOOT"
sudo cp "$KERNEL_EFI" "$EFI_MNT/EFI/BOOT/BOOTAA64.EFI"
sudo cp "$INITRD" "$EFI_MNT/initrd.img"
sudo sync
sudo umount "$EFI_MNT"

echo "==> Populating root partition"
sudo mount "$ROOT_DEV" "$ROOT_MNT"
sudo tar --numeric-owner -xzf "$ROOTFS_TAR" -C "$ROOT_MNT"
sudo mkdir -p "$ROOT_MNT/boot"
sudo cp "$KERNEL" "$ROOT_MNT/boot/vmlinuz"
sudo cp "$INITRD" "$ROOT_MNT/boot/initrd.img"
sudo mkdir -p "$ROOT_MNT/mnt/internal" "$ROOT_MNT/mnt/shared" "$ROOT_MNT/mnt/backup"
sudo sync
sudo umount "$ROOT_MNT"

echo "==> Extracting AVF partition payload files"
sector_size="$(sfdisk -J "$DISK_IMG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["partitiontable"]["sectorsize"])')"
sfdisk -J "$DISK_IMG" | python3 -c '
import json
import sys

data = json.load(sys.stdin)["partitiontable"]
sector_size = data["sectorsize"]
for partition in data["partitions"]:
    name = partition.get("name", "")
    start = int(partition["start"]) * sector_size
    size = int(partition["size"]) * sector_size
    if name == "ESP":
        print(f"efi {start} {size}")
    elif name == "archlinux":
        print(f"root {start} {size}")
' | while read -r label start size; do
    case "$label" in
        efi) dd if="$DISK_IMG" of="$EFI_PART" bs="$sector_size" skip="$((start / sector_size))" count="$((size / sector_size))" status=none ;;
        root) dd if="$DISK_IMG" of="$ROOT_PART" bs="$sector_size" skip="$((start / sector_size))" count="$((size / sector_size))" status=none ;;
    esac
done

cat > "$BUILD_DIR/partition-uuids.env" <<EOF
ROOT_PART_GUID="$(sfdisk --part-uuid "$DISK_IMG" 1)"
EFI_PART_GUID="$(sfdisk --part-uuid "$DISK_IMG" 2)"
EOF

ls -lh "$DISK_IMG" "$EFI_PART" "$ROOT_PART" "$BUILD_DIR/partition-uuids.env"
