#!/usr/bin/env bash
set -euo pipefail

KERNEL_GIT_REPO="${KERNEL_GIT_REPO:-https://android.googlesource.com/kernel/common}"
KERNEL_TAG_PATTERN="${KERNEL_TAG_PATTERN:-android16-6.12.*_r*}"

usage() {
    cat <<EOF
Usage: ${0##*/} [--repo URL] [--pattern GLOB] [--ref REF]

Resolve the newest Android common kernel tag matching PATTERN.

Outputs:
  KERNEL_GIT_REPO
  KERNEL_GIT_REF
  KERNEL_VERSION
  KERNEL_REF_SHA

When GITHUB_OUTPUT is set, the same values are appended for GitHub Actions.
EOF
}

requested_ref=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            KERNEL_GIT_REPO="${2:?missing value for --repo}"
            shift 2
            ;;
        --pattern)
            KERNEL_TAG_PATTERN="${2:?missing value for --pattern}"
            shift 2
            ;;
        --ref)
            requested_ref="${2:?missing value for --ref}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

emit() {
    local key="$1"
    local value="$2"
    printf '%s=%s\n' "$key" "$value"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    fi
}

if [ -n "$requested_ref" ]; then
    KERNEL_GIT_REF="${requested_ref#refs/tags/}"
    KERNEL_REF_SHA="$(git ls-remote --refs --tags "$KERNEL_GIT_REPO" "refs/tags/$KERNEL_GIT_REF" | awk 'NR == 1 {print $1}')"
    [ -n "$KERNEL_REF_SHA" ] || {
        echo "Unable to resolve requested kernel ref: $KERNEL_GIT_REF" >&2
        exit 1
    }
else
    resolved="$(
        git ls-remote --refs --tags "$KERNEL_GIT_REPO" "refs/tags/$KERNEL_TAG_PATTERN" |
        python3 -c '
import re
import sys

tags = []
for line in sys.stdin:
    sha, ref = line.strip().split("\t", 1)
    tag = ref.rsplit("/", 1)[-1]
    match = re.fullmatch(r"android(?P<android>\d+)-(?P<version>\d+\.\d+\.\d+)_r(?P<rev>\d+)", tag)
    if not match:
        continue
    version = tuple(int(part) for part in match.group("version").split("."))
    tags.append((version, int(match.group("rev")), tag, sha))

if not tags:
    raise SystemExit("No matching Android common kernel tags found")

version, rev, tag, sha = max(tags)
print(f"{tag}\t{sha}")
'
    )"
    KERNEL_GIT_REF="${resolved%%$'\t'*}"
    KERNEL_REF_SHA="${resolved#*$'\t'}"
fi

if [[ ! "$KERNEL_GIT_REF" =~ ^android[0-9]+-([0-9]+\.[0-9]+\.[0-9]+)_r[0-9]+$ ]]; then
    echo "Unable to derive KERNEL_VERSION from ref: $KERNEL_GIT_REF" >&2
    exit 1
fi
KERNEL_VERSION="${BASH_REMATCH[1]}"

emit KERNEL_GIT_REPO "$KERNEL_GIT_REPO"
emit KERNEL_GIT_REF "$KERNEL_GIT_REF"
emit KERNEL_VERSION "$KERNEL_VERSION"
emit KERNEL_REF_SHA "$KERNEL_REF_SHA"
