#!/usr/bin/env bash
set -euo pipefail

ADB_FLAGS="${ADB_FLAGS:-}"
HAS_ROOT=false
USE_SU=false
ROOT_CHECKED=false

_adb() {
    echo " $ adb ${ADB_FLAGS} $*" >&2
    adb ${ADB_FLAGS} "$@"
}

_enable_root() {
    if "$ROOT_CHECKED"; then
        return
    fi
    ROOT_CHECKED=true

    _adb root >/dev/null 2>&1 || true
    if _adb shell id | grep -q "uid=0"; then
        HAS_ROOT=true
        return
    fi

    if _adb shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
        HAS_ROOT=true
        USE_SU=true
    fi
}

require_root() {
    _enable_root >/dev/null
    if ! "$HAS_ROOT"; then
        echo "This command requires adb root or su on the device." >&2
        exit 2
    fi
}

with_root() {
    require_root
    if "$USE_SU"; then
        _adb shell "su -c '$*'"
    else
        _adb shell "$@"
    fi
}
