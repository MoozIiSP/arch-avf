#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/_common.sh"

with_root rm -rfv \
    /data/data/com.android.virtualization.terminal/files/archlinux.log \
    /data/data/com.android.virtualization.terminal/files/debian.log \
    /data/data/com.android.virtualization.terminal/files/linux \
    /data/data/com.android.virtualization.terminal/vm/archlinux \
    /data/data/com.android.virtualization.terminal/vm/debian
