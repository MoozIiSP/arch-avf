#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PAYLOAD_DIR="${PAYLOAD_DIR:-$PROJECT_DIR/build/payload}"
ANDROID_IMAGE="${ANDROID_IMAGE:-$PROJECT_DIR/build/images.tar.gz}"
DEPLOY_MODE="${DEPLOY_MODE:-replace-dir}"
TARGET_DIR="${TARGET_DIR:-}"
PUSH_ROOT_PART="${PUSH_ROOT_PART:-1}"

command -v adb >/dev/null 2>&1 || { echo "adb not found. Install Android Platform Tools." >&2; exit 1; }

device_count="$(adb devices | awk 'NR > 1 && $2 == "device" { count++ } END { print count + 0 }')"
[ "$device_count" -eq 1 ] || { echo "Expected exactly one connected adb device, found $device_count." >&2; exit 1; }

case "$DEPLOY_MODE" in
  replace-dir)
    target_dir="${TARGET_DIR:-/sdcard/Download/image}"
    required=(
      build_id
      vm_config.json
      vmlinuz
      initrd.img
      replace.sh
    )
    if [ "$PUSH_ROOT_PART" != "0" ]; then
      required+=(root_part)
    fi
    for file in "${required[@]}"; do
      [ -s "$PAYLOAD_DIR/$file" ] || { echo "Missing payload file: $PAYLOAD_DIR/$file" >&2; exit 1; }
    done

    echo "==> Deploying replace payload files to $target_dir"
    adb shell "mkdir -p '$target_dir'"
    for file in "${required[@]}"; do
      adb push "$PAYLOAD_DIR/$file" "$target_dir/$file"
    done
    ;;
  import-image)
    target_dir="${TARGET_DIR:-/sdcard/linux}"
    [ -f "$ANDROID_IMAGE" ] || { echo "Missing Android import image: $ANDROID_IMAGE" >&2; exit 1; }
    echo "==> Deploying Android Terminal import image to $target_dir/images.tar.gz"
    adb shell "mkdir -p '$target_dir'"
    adb push "$ANDROID_IMAGE" "$target_dir/images.tar.gz"
    ;;
  *)
    echo "Unsupported DEPLOY_MODE=$DEPLOY_MODE; use replace-dir or import-image" >&2
    exit 1
    ;;
esac

echo "Payload deployed."
echo "For SSH after boot: adb forward tcp:2222 tcp:22 && ssh root@localhost -p 2222"
