#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build/android-services}"
OUT_DIR="$BUILD_DIR/out"
AOSP_DIR="${AOSP_DIR:-$BUILD_DIR/aosp}"
ANDROID_BRANCH="${ANDROID_BRANCH:-android-16.0.0_r3}"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }

if [ ! -d "$AOSP_DIR/.repo" ]; then
    command -v repo >/dev/null 2>&1 || { echo "repo is required for Android source checkout. Install it or set AOSP_DIR to an existing checkout." >&2; exit 1; }
    mkdir -p "$AOSP_DIR"
    (
        cd "$AOSP_DIR"
        repo init -u https://android.googlesource.com/platform/manifest -b "$ANDROID_BRANCH" --depth=1
        repo sync -c -j"$(getconf _NPROCESSORS_ONLN)"
    )
fi

(
    cd "$AOSP_DIR"
    source build/envsetup.sh
    lunch aosp_cf_arm64_phone-trunk_staging-userdebug
    m forwarder_guest forwarder_guest_launcher storage_balloon_agent shutdown_runner
)

find "$AOSP_DIR/out" -type f \( \
    -name forwarder_guest -o \
    -name forwarder_guest_launcher -o \
    -name storage_balloon_agent -o \
    -name shutdown_runner \
\) -exec cp -f {} "$OUT_DIR/" \;

for binary in forwarder_guest forwarder_guest_launcher storage_balloon_agent shutdown_runner; do
    [ -x "$OUT_DIR/$binary" ] || { echo "Build did not produce $binary" >&2; exit 1; }
done

ls -lh "$OUT_DIR"
