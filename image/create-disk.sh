#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build/image}"
ROOTFS_TAR="${ROOTFS_TAR:-$PROJECT_DIR/build/rootfs/rootfs.tar.gz}"

ROOT_SIZE_MB="${ROOT_SIZE_MB:-8192}"

DISK_IMG="$BUILD_DIR/disk.img"
ROOT_PART="$BUILD_DIR/root_part"

require() {
    command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require awk
require dd
require e2fsck
require losetup
require mkfs.ext4
require python3
require sfdisk
require sudo
require tar
require truncate

[ -s "$ROOTFS_TAR" ] || { echo "Missing or empty rootfs tarball: $ROOTFS_TAR" >&2; exit 1; }

mkdir -p "$BUILD_DIR"
rm -f "$DISK_IMG" "$ROOT_PART"

TOTAL_SIZE_MB=$((ROOT_SIZE_MB + 16))

echo "==> Creating ${TOTAL_SIZE_MB} MiB raw GPT disk image"
truncate -s "${TOTAL_SIZE_MB}M" "$DISK_IMG"
SECTORS_PER_MIB=2048
ROOT_START=$((1 * SECTORS_PER_MIB))
ROOT_SECTORS=$((ROOT_SIZE_MB * SECTORS_PER_MIB))
sfdisk "$DISK_IMG" <<EOF
label: gpt
start=${ROOT_START}, size=${ROOT_SECTORS}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="archlinux"
EOF
ROOT_PART_GUID="$(sfdisk --part-uuid "$DISK_IMG" 1)"

LOOP_DEV=""
ROOT_MNT="$(mktemp -d)"
cleanup() {
    sudo umount "$ROOT_MNT" 2>/dev/null || true
    if [ -n "$LOOP_DEV" ]; then
        sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    rmdir "$ROOT_MNT" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Attaching loop device"
LOOP_DEV="$(sudo losetup --find --partscan --show "$DISK_IMG")"
ROOT_DEV="${LOOP_DEV}p1"

echo "==> Formatting partitions"
sudo mkfs.ext4 -F -L archlinux -O '^metadata_csum,^metadata_csum_seed,^orphan_file' "$ROOT_DEV"

echo "==> Populating root partition"
sudo mount "$ROOT_DEV" "$ROOT_MNT"
sudo tar --numeric-owner -xzf "$ROOTFS_TAR" -C "$ROOT_MNT"
sudo tee "$ROOT_MNT/etc/fstab" >/dev/null <<EOF
LABEL=archlinux / ext4 rw,discard,errors=remount-ro,x-systemd.growfs 0 1
# /boot/efi is intentionally left unmounted; Android Terminal boots this payload via vm_config.json kernel/initrd.
EOF
sudo mkdir -p "$ROOT_MNT/mnt/internal" "$ROOT_MNT/mnt/shared" "$ROOT_MNT/mnt/backup"
sudo sync
sudo umount "$ROOT_MNT"

echo "==> Optimizing and checking root filesystem"
sudo e2fsck -fyD "$ROOT_DEV"

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
    if name == "archlinux":
        print(f"root {start} {size}")
' | while read -r label start size; do
    case "$label" in
        root) dd if="$DISK_IMG" of="$ROOT_PART" bs="$sector_size" skip="$((start / sector_size))" count="$((size / sector_size))" status=none ;;
    esac
done

cat > "$BUILD_DIR/partition-uuids.env" <<EOF
ROOT_PART_GUID="$ROOT_PART_GUID"
EOF

ls -lh "$DISK_IMG" "$ROOT_PART" "$BUILD_DIR/partition-uuids.env"
