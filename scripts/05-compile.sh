#!/bin/bash
set -euo pipefail

SRC_DIR="$WORK_DIR/src"
cd "$SRC_DIR"

echo "==> Building (this takes a while) - $jobs job(s), -march=$march, LOCALVERSION=$localversion"
make -j"$jobs" bindeb-pkg LOCALVERSION="$localversion" KCFLAGS="-march=$march"

# bindeb-pkg drops the .deb files one directory above the source tree
cd "$WORK_DIR"

# linux-libc-dev clashes with Debian's own libc6-dev headers and isn't
# needed to install/boot a custom kernel, so it's dropped (same call
# PikaOS's build makes).
rm -f linux-libc-dev_*.deb

mv -v ./*.deb "$OUTPUT_DIR"/
