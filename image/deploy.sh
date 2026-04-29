#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PAYLOAD_DIR="${PAYLOAD_DIR:-$PROJECT_DIR/build/payload}"
ANDROID_IMAGE="${ANDROID_IMAGE:-$PROJECT_DIR/build/images.tar.gz}"
TARGET_DIR="${TARGET_DIR:-/sdcard/linux}"

command -v adb >/dev/null 2>&1 || { echo "adb not found. Install Android Platform Tools." >&2; exit 1; }

[ -f "$ANDROID_IMAGE" ] || { echo "Missing Android import image: $ANDROID_IMAGE" >&2; exit 1; }

device_count="$(adb devices | awk 'NR > 1 && $2 == "device" { count++ } END { print count + 0 }')"
[ "$device_count" -eq 1 ] || { echo "Expected exactly one connected adb device, found $device_count." >&2; exit 1; }

echo "==> Deploying Android Terminal image to $TARGET_DIR/images.tar.gz"
adb shell "mkdir -p '$TARGET_DIR'"
adb push "$ANDROID_IMAGE" "$TARGET_DIR/images.tar.gz"

echo "Image deployed. Restart the Android Terminal app and accept the auto-install prompt."
echo "For SSH after boot: adb forward tcp:2222 tcp:22 && ssh root@localhost -p 2222"
