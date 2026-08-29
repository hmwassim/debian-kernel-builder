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

# CPU tuning is applied at compile time as a straight -march= value (see
# scripts/05-compile.sh): generic/native map to a concrete flag, anything
# else (rocketlake, znver4, alderlake, ...) is already a valid GCC/Clang
# -march name and is passed straight through.
case "$cpu" in
    generic) march="x86-64-v3" ;;
    native)  march="native" ;;
    *)       march="$cpu" ;;
esac

echo "==> debian-kernel-builder"
echo "    kernel_version = $kernel_version"
echo "    cpu            = $cpu (-march=$march)"
echo "    scheduler      = $scheduler"
echo "    jobs           = $jobs"

install_deps=0
for arg in "$@"; do
    [[ "$arg" == "--install-deps" ]] && install_deps=1
done

if [[ "$install_deps" -eq 1 ]]; then
    echo "==> Installing build dependencies"
    apt-get update -y
    apt-get install -y --no-install-recommends \
        build-essential libncurses-dev bison flex libssl-dev libelf-dev \
        bc dwarves git wget patch rsync kmod cpio fakeroot python3
fi

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

export ROOT_DIR WORK_DIR OUTPUT_DIR kernel_version cpu scheduler jobs localversion march

"$ROOT_DIR/scripts/01-fetch-source.sh"
"$ROOT_DIR/scripts/02-fetch-patches.sh"
"$ROOT_DIR/scripts/03-apply-patches.sh"
"$ROOT_DIR/scripts/04-configure.sh"
"$ROOT_DIR/scripts/05-compile.sh"

echo "==> Done. Packages in: $OUTPUT_DIR"
ls -1 "$OUTPUT_DIR"
