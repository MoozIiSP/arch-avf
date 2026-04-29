#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
IMAGE="${IMAGE:-$PROJECT_DIR/build/images.tar.gz}"
TARGET_DIR="${TARGET_DIR:-/sdcard/linux}"

[ -f "$IMAGE" ] || { echo "Missing image: $IMAGE" >&2; exit 1; }

adb shell "mkdir -p '$TARGET_DIR'"
adb push "$IMAGE" "$TARGET_DIR/images.tar.gz"
