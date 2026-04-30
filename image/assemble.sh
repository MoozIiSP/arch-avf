#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
PAYLOAD_DIR="${PAYLOAD_DIR:-$BUILD_DIR/payload}"
IMAGE_DIR="$BUILD_DIR/image"
PARTITION_UUIDS="$IMAGE_DIR/partition-uuids.env"
ANDROID_IMAGE="$BUILD_DIR/images.tar.gz"
REPLACE_IMAGE="$BUILD_DIR/arch-avf-replace.tar.gz"

rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"

copy_required() {
    local src="$1"
    local dest="$2"
    [ -f "$src" ] || { echo "Missing required file: $src" >&2; exit 1; }
    cp "$src" "$dest"
}

echo "==> Assembling AVF payload"
copy_required "$PARTITION_UUIDS" "$PAYLOAD_DIR/partition-uuids.env"
copy_required "$BUILD_DIR/kernel/vmlinuz" "$PAYLOAD_DIR/vmlinuz"
copy_required "$BUILD_DIR/initrd.img" "$PAYLOAD_DIR/initrd.img"
copy_required "$BUILD_DIR/image/root_part" "$PAYLOAD_DIR/root_part"
copy_required "$BUILD_DIR/image/efi_part" "$PAYLOAD_DIR/efi_part"

. "$PARTITION_UUIDS"
export EFI_PART_GUID ROOT_PART_GUID
python3 - "$PROJECT_DIR/config/vm_config.json" "$PAYLOAD_DIR/vm_config.json" <<'PY'
import json
import os
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
text = src.read_text()
text = text.replace("{efi_part_guid}", os.environ["EFI_PART_GUID"])
text = text.replace("{root_part_guid}", os.environ["ROOT_PART_GUID"])
json.loads(text)
dest.write_text(text + "\n")
PY

kernel_release="unknown"
if [ -f "$BUILD_DIR/kernel/kernel.release" ]; then
    kernel_release="$(cat "$BUILD_DIR/kernel/kernel.release")"
fi
printf 'arch_avf/aarch64/%s/%s\n' "$kernel_release" "$(date -u +%Y%m%dT%H%M%SZ)" > "$PAYLOAD_DIR/build_id"

python3 -m json.tool "$PAYLOAD_DIR/vm_config.json" >/dev/null

echo "==> Packaging Android Terminal import image"
tar -C "$PAYLOAD_DIR" -czf "$ANDROID_IMAGE" \
    build_id \
    root_part \
    efi_part \
    vm_config.json \
    vmlinuz \
    initrd.img
sha256sum "$ANDROID_IMAGE" > "$ANDROID_IMAGE.sha256"

echo "==> Packaging production replace image"
cp "$SCRIPT_DIR/replace.sh" "$PAYLOAD_DIR/replace.sh"
chmod 0755 "$PAYLOAD_DIR/replace.sh"
tar -C "$PAYLOAD_DIR" -czf "$REPLACE_IMAGE" \
    build_id \
    root_part \
    efi_part \
    vm_config.json \
    vmlinuz \
    initrd.img \
    replace.sh
sha256sum "$REPLACE_IMAGE" > "$REPLACE_IMAGE.sha256"

echo "==> Payload contents"
ls -lh "$PAYLOAD_DIR"
ls -lh "$ANDROID_IMAGE" "$ANDROID_IMAGE.sha256" "$REPLACE_IMAGE" "$REPLACE_IMAGE.sha256"
