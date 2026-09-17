#!/bin/bash
set -euo pipefail

SRC_DIR="$WORK_DIR/src"
cd "$SRC_DIR"

# ---- Toolchain -------------------------------------------------------------
# Recomputed here rather than inherited from 04-configure.sh: each stage
# runs as a separate process (see run_as_user in build.sh), so nothing
# carries over except the exported kbuild.conf variables. Must match what
# generated .config, or the compiler actually building the kernel won't be
# the one the config was written for.
if [[ "${toolchain:-gcc}" == "clang" ]]; then
    TOOLCHAIN_ARGS=(LLVM=1)
else
    TOOLCHAIN_ARGS=()
fi

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

KCFLAGS_VAL="-march=$MARCH"
if [[ "${gaming_tweaks:-no}" == "yes" ]]; then
    echo "==> Enabling AMD private color (-DAMD_PRIVATE_COLOR)"
    KCFLAGS_VAL="$KCFLAGS_VAL -DAMD_PRIVATE_COLOR"
fi

echo "==> Building (this takes a while) - $jobs job(s), LOCALVERSION=$localversion"
make -j"$jobs" "${TOOLCHAIN_ARGS[@]}" KCFLAGS="$KCFLAGS_VAL" bindeb-pkg LOCALVERSION="$localversion"

# bindeb-pkg drops the .deb files one directory above the source tree
cd "$WORK_DIR"

# linux-libc-dev clashes with Debian's own libc6-dev headers and isn't
# needed to install/boot a custom kernel, so it's dropped (same call
# PikaOS's build makes).
rm -f linux-libc-dev_*.deb

mv -v ./*.deb "$OUTPUT_DIR"/
