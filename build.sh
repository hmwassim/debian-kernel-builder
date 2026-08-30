#!/bin/bash
# debian-kernel-builder - automated, non-interactive kernel build for Debian 13 Trixie
#
# Usage:
#   ./build.sh              build the kernel .deb packages according to kbuild.conf
#   ./build.sh --install-deps   also apt-get install the packages needed to build
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$ROOT_DIR/kbuild.conf"
WORK_DIR="$ROOT_DIR/work"
OUTPUT_DIR="$ROOT_DIR/output"

# shellcheck source=kbuild.conf
source "$CONF_FILE"

# ---- validate required fields --------------------------------------------
: "${kernel_version:?kernel_version must be set in kbuild.conf}"
: "${cpu:?cpu must be set in kbuild.conf}"
: "${scheduler:?scheduler must be set in kbuild.conf}"
jobs="${jobs:-$(nproc)}"
localversion="${localversion:--custom}"
hz="${hz:-250}"
preempt="${preempt:-lazy}"
trim_modules="${trim_modules:-no}"
verify_signature="${verify_signature:-yes}"

echo "==> debian-kernel-builder"
echo "    kernel_version = $kernel_version"
echo "    cpu            = $cpu"
echo "    scheduler      = $scheduler"
echo "    hz / preempt   = $hz / $preempt"
echo "    trim_modules   = $trim_modules"
echo "    jobs           = $jobs"

if [[ "${1:-}" == "--install-deps" ]]; then
    echo "==> Installing build dependencies"
    apt-get update -y
    apt-get install -y --no-install-recommends \
        build-essential debhelper libncurses-dev bison flex libssl-dev \
        libelf-dev libdw-dev bc dwarves git wget patch rsync kmod cpio \
        fakeroot python3 gnupg xz-utils
fi

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

# If kernel_version or scheduler changed since the last run, the extracted
# source in work/src is stale (or already patched for a different
# scheduler) - wipe it so stage 1/2/3 start clean instead of silently
# applying a new patch on top of an old tree.
FINGERPRINT_FILE="$WORK_DIR/.kbuild-fingerprint"
FINGERPRINT="${kernel_version}:${scheduler}"
if [[ -f "$FINGERPRINT_FILE" ]] && [[ "$(cat "$FINGERPRINT_FILE")" != "$FINGERPRINT" ]]; then
    echo "==> kernel_version/scheduler changed since the last build, cleaning work/src"
    rm -rf "$WORK_DIR/src"
fi
echo "$FINGERPRINT" > "$FINGERPRINT_FILE"

export ROOT_DIR WORK_DIR OUTPUT_DIR kernel_version cpu scheduler jobs localversion \
       hz preempt trim_modules verify_signature

"$ROOT_DIR/scripts/01-fetch-source.sh"
"$ROOT_DIR/scripts/02-fetch-patches.sh"
"$ROOT_DIR/scripts/03-apply-patches.sh"
"$ROOT_DIR/scripts/04-configure.sh"
"$ROOT_DIR/scripts/05-compile.sh"

echo "==> Done. Packages in: $OUTPUT_DIR"
ls -1 "$OUTPUT_DIR"
