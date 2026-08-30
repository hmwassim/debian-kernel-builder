#!/bin/bash
set -euo pipefail

SRC_DIR="$WORK_DIR/src"
cd "$SRC_DIR"

# ---- CPU target ----------------------------------------------------------
# Applied as a compiler -march flag rather than Kconfig: generic/native
# and named microarchs (rocketlake, znver4, x86-64-v3, ...) are all valid
# GCC/Clang -march values directly - no per-name lookup table needed.
case "$cpu" in
    generic) MARCH="x86-64-v3" ;;
    native)  MARCH="native" ;;
    *)       MARCH="$cpu" ;;
esac
echo "==> CPU target: -march=$MARCH"

echo "==> Building (this takes a while) - $jobs job(s), LOCALVERSION=$localversion"
make -j"$jobs" KCFLAGS="-march=$MARCH" bindeb-pkg LOCALVERSION="$localversion"

# bindeb-pkg drops the .deb files one directory above the source tree
cd "$WORK_DIR"

# linux-libc-dev clashes with Debian's own libc6-dev headers and isn't
# needed to install/boot a custom kernel, so it's dropped (same call
# PikaOS's build makes).
rm -f linux-libc-dev_*.deb

mv -v ./*.deb "$OUTPUT_DIR"/
