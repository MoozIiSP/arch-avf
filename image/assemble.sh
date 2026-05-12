#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
PAYLOAD_DIR="${PAYLOAD_DIR:-$BUILD_DIR/payload}"
IMAGE_DIR="$BUILD_DIR/image"
PARTITION_UUIDS="$IMAGE_DIR/partition-uuids.env"
CIDATA_IMAGE="$BUILD_DIR/cidata.iso"
ANDROID_IMAGE="$BUILD_DIR/images.tar.gz"
REPLACE_IMAGE="$BUILD_DIR/arch-avf-replace.tar.gz"
PACKAGE_IMPORT="${PACKAGE_IMPORT:-1}"
PACKAGE_REPLACE="${PACKAGE_REPLACE:-1}"

rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"

copy_required() {
    local src="$1"
    local dest="$2"
    [ -s "$src" ] || { echo "Missing or empty required file: $src" >&2; exit 1; }
    cp "$src" "$dest"
}

echo "==> Assembling AVF payload"
copy_required "$PARTITION_UUIDS" "$PAYLOAD_DIR/partition-uuids.env"
copy_required "$BUILD_DIR/kernel/vmlinuz" "$PAYLOAD_DIR/vmlinuz"
copy_required "$BUILD_DIR/initrd.img" "$PAYLOAD_DIR/initrd.img"
copy_required "$BUILD_DIR/image/root_part" "$PAYLOAD_DIR/root_part"
if [ -s "$BUILD_DIR/kernel/kernel.source" ]; then
    copy_required "$BUILD_DIR/kernel/kernel.source" "$PAYLOAD_DIR/kernel.source"
fi

. "$PARTITION_UUIDS"
export ROOT_PART_GUID
python3 - "$PROJECT_DIR/config/vm_config.json" "$PAYLOAD_DIR/vm_config.json" <<'PY'
import json
import os
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
text = src.read_text()
text = text.replace("{root_part_guid}", os.environ["ROOT_PART_GUID"])
json.loads(text)
dest.write_text(text + "\n")
PY

kernel_release="unknown"
if [ -f "$BUILD_DIR/kernel/kernel.release" ]; then
    kernel_release="$(cat "$BUILD_DIR/kernel/kernel.release")"
fi
arch_release="${ARCH_RELEASE:-$(date -u +%Y.%m.%d)}"
build_target="archlinux/aarch64/${arch_release}-${kernel_release}"
build_number="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(date -u +%s)}}"
build_timestamp="$(LC_ALL=C TZ=UTC date '+%a %b %d %H:%M:%S UTC %Y')"
printf '%s-%s-%s\n' "$build_target" "$build_number" "$build_timestamp" > "$PAYLOAD_DIR/build_id"

python3 - "$PAYLOAD_DIR/build_id" <<'PY'
import datetime as dt
import pathlib
import re
import sys

build_id = pathlib.Path(sys.argv[1]).read_text().strip()
match = re.fullmatch(r"^(.*?)-(\d+)-(.*)$", build_id)
if not match:
    raise SystemExit(f"Invalid Terminal target-id-date build_id: {build_id!r}")
dt.datetime.strptime(match.group(3), "%a %b %d %H:%M:%S %Z %Y")
PY

python3 -m json.tool "$PAYLOAD_DIR/vm_config.json" >/dev/null

need_cidata=0
if grep -q 'cidata\.iso' "$PAYLOAD_DIR/vm_config.json"; then
    need_cidata=1
fi
if [ "$need_cidata" = 1 ] && [ -s "$CIDATA_IMAGE" ]; then
    copy_required "$CIDATA_IMAGE" "$PAYLOAD_DIR/cidata.iso"
fi

if [ "$PACKAGE_IMPORT" != "0" ] && { [ "$need_cidata" = 0 ] || [ -s "$PAYLOAD_DIR/cidata.iso" ]; }; then
    echo "==> Packaging Android Terminal import image"
    import_contents=(
        build_id
        root_part
        vm_config.json
        vmlinuz
        initrd.img
    )
    if [ -s "$PAYLOAD_DIR/kernel.source" ]; then
        import_contents+=(kernel.source)
    fi
    if [ -s "$PAYLOAD_DIR/cidata.iso" ]; then
        import_contents+=(cidata.iso)
    fi
    tar -C "$PAYLOAD_DIR" -czf "$ANDROID_IMAGE" "${import_contents[@]}"
    sha256sum "$ANDROID_IMAGE" > "$ANDROID_IMAGE.sha256"
elif [ "$PACKAGE_IMPORT" != "0" ]; then
    echo "==> Skipping Android Terminal import image: vm_config.json requires cidata.iso, but $CIDATA_IMAGE is absent"
    rm -f "$ANDROID_IMAGE" "$ANDROID_IMAGE.sha256"
else
    echo "==> Skipping Android Terminal import image packaging"
fi

cp "$SCRIPT_DIR/replace.sh" "$PAYLOAD_DIR/replace.sh"
chmod 0755 "$PAYLOAD_DIR/replace.sh"

if [ "$PACKAGE_REPLACE" != "0" ]; then
    echo "==> Packaging production replace image"
    replace_contents=(
        build_id
        root_part
        vm_config.json
        vmlinuz
        initrd.img
        replace.sh
    )
    if [ -s "$PAYLOAD_DIR/kernel.source" ]; then
        replace_contents+=(kernel.source)
    fi
    if [ -s "$PAYLOAD_DIR/cidata.iso" ]; then
        replace_contents+=(cidata.iso)
    fi
    tar -C "$PAYLOAD_DIR" -czf "$REPLACE_IMAGE" "${replace_contents[@]}"
    sha256sum "$REPLACE_IMAGE" > "$REPLACE_IMAGE.sha256"
else
    echo "==> Skipping production replace image packaging"
fi

echo "==> Payload contents"
ls -lh "$PAYLOAD_DIR"
if [ "$PACKAGE_IMPORT" != "0" ] && [ -f "$ANDROID_IMAGE" ]; then
    ls -lh "$ANDROID_IMAGE" "$ANDROID_IMAGE.sha256"
fi
if [ "$PACKAGE_REPLACE" != "0" ] && [ -f "$REPLACE_IMAGE" ]; then
    ls -lh "$REPLACE_IMAGE" "$REPLACE_IMAGE.sha256"
fi
