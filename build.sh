#!/bin/bash
# debian-kernel-builder - automated, non-interactive kernel build for Debian 13 Trixie
#
# Usage: sudo ./build.sh
#
# Needs root: it installs any missing build dependencies via apt, and
# installs the finished kernel .deb packages at the end. The actual
# fetch/patch/configure/compile steps run as the user who invoked sudo
# (not root), so work/ and output/ end up owned by you, not root - and
# building a kernel as root isn't something you want to make a habit of.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---- sudo guard -----------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: this needs root, for installing dependencies and the finished kernel." >&2
    echo "Run it with: sudo ./build.sh" >&2
    exit 1
fi

# The user who ran `sudo ./build.sh` - the actual build runs as them, not
# root (see the run_as_user helper below). Falls back to running
# everything as root only if this is a genuine root login rather than a
# sudo'd one (no SUDO_USER to drop to).
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    echo "==> No non-root user to build as (not run via sudo from a regular account) - building as root"
    TARGET_USER="root"
fi

run_as_user() {
    if [[ "$TARGET_USER" == "root" ]]; then
        "$@"
    else
        sudo -u "$TARGET_USER" -H \
            --preserve-env=ROOT_DIR,WORK_DIR,OUTPUT_DIR,kernel_version,cpu,scheduler,jobs,localversion,hz,preempt,trim_modules,verify_signature \
            "$@"
    fi
}

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
echo "    building as    = $TARGET_USER"

# ---- dependencies ----------------------------------------------------------
# Checked rather than unconditionally reinstalled, so a second run doesn't
# hit the network / apt-get update for no reason.
DEPS=(build-essential debhelper libncurses-dev bison flex libssl-dev
      libelf-dev libdw-dev bc dwarves git wget patch rsync kmod cpio
      fakeroot python3 gnupg xz-utils)
MISSING=()
for pkg in "${DEPS[@]}"; do
    dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "==> Installing missing build dependencies: ${MISSING[*]}"
    apt-get update -y
    apt-get install -y --no-install-recommends "${MISSING[@]}"
else
    echo "==> Build dependencies already installed"
fi

# work/ and output/ need to end up owned by TARGET_USER, not root, since
# the actual build runs as them (see run_as_user) - only chown right after
# creating them, not on every run, so this doesn't turn into a recursive
# chown over a multi-GB extracted kernel tree every single build.
for d in "$WORK_DIR" "$OUTPUT_DIR"; do
    if [[ ! -d "$d" ]]; then
        mkdir -p "$d"
        [[ "$TARGET_USER" != root ]] && chown "$TARGET_USER":"$TARGET_USER" "$d"
    fi
done

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

run_as_user "$ROOT_DIR/scripts/01-fetch-source.sh"
run_as_user "$ROOT_DIR/scripts/02-fetch-patches.sh"
run_as_user "$ROOT_DIR/scripts/03-apply-patches.sh"
run_as_user "$ROOT_DIR/scripts/04-configure.sh"
run_as_user "$ROOT_DIR/scripts/05-compile.sh"

echo "==> Installing the built kernel"
# output/ accumulates .deb files across every past build, not just this
# one - scope the install to this run's kernel_version+localversion so an
# old build sitting in output/ (possibly one you've since removed from the
# system on purpose) doesn't get silently reinstalled alongside it.
#
# Also skip the -dbg package: DEBUG_INFO_BTF (enabled above for sched-ext)
# needs full DWARF debug info to generate BTF, so bindeb-pkg always splits
# that into its own linux-image-*-dbg deb - often multiple GB. The BTF
# data BPF schedulers actually need at runtime is already embedded in the
# image package itself; the -dbg package is just symbols for gdb/crash/
# perf annotate. It's still built and sitting in output/ if you ever want
# it, just not pulled onto the system automatically.
KERNELRELEASE="${kernel_version}${localversion}"
INSTALL_DEBS=()
for f in "$OUTPUT_DIR"/*"${KERNELRELEASE}"*.deb; do
    [[ "$f" == *-dbg_* ]] && continue
    INSTALL_DEBS+=("$f")
done
if [[ ${#INSTALL_DEBS[@]} -eq 0 ]]; then
    echo "ERROR: no .deb packages found for $KERNELRELEASE in $OUTPUT_DIR" >&2
    exit 1
fi
apt-get install -y "${INSTALL_DEBS[@]}"

echo "==> Done and installed. Packages in: $OUTPUT_DIR"
ls -1 "$OUTPUT_DIR"
echo "==> Your previous kernel is still installed and still in the GRUB menu -"
echo "    this only adds the new one, it doesn't remove or default to it."
