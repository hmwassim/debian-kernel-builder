#!/bin/bash
# Resolves the "scheduler" choice to a concrete patch file from
# CachyOS/kernel-patches (https://github.com/CachyOS/kernel-patches),
# organized per kernel major.minor branch. cfs/eevdf need no patch at
# all - they're just the kernel's own scheduler for that version range.
set -euo pipefail

MAJOR_MINOR="$(echo "$kernel_version" | cut -d. -f1,2)"
PATCH_DIR="$WORK_DIR/patches"
mkdir -p "$PATCH_DIR"

BASE_URL="https://raw.githubusercontent.com/CachyOS/kernel-patches/master/${MAJOR_MINOR}"

# major/minor as a single sortable integer, e.g. 6.6 -> 6006, 7.2 -> 7002
ver_num() { local M="${1%%.*}" m="${1#*.}"; printf '%d%03d' "$M" "$m"; }
KVER_NUM="$(ver_num "$MAJOR_MINOR")"
V66="$(ver_num 6.6)"

case "$scheduler" in
    cfs)
        if (( KVER_NUM >= V66 )); then
            echo "ERROR: scheduler=cfs requires kernel_version < 6.6 (got $kernel_version)." >&2
            exit 1
        fi
        # A previous run may have left a bore/pds/bmq patch file here from a
        # different scheduler choice. build.sh only wipes work/src when
        # kernel_version/scheduler changes - it doesn't touch work/patches -
        # so without this, 03-apply-patches.sh would find that stale file
        # and apply someone else's scheduler patch onto this run's freshly
        # extracted, supposedly-unpatched tree.
        rm -f "$PATCH_DIR/scheduler.patch"
        echo "==> cfs is the kernel's own scheduler on $kernel_version, no patch needed"
        ;;
    eevdf)
        if (( KVER_NUM < V66 )); then
            echo "ERROR: scheduler=eevdf requires kernel_version >= 6.6 (got $kernel_version)." >&2
            exit 1
        fi
        # See the cfs branch above - same stale-patch hazard applies here.
        rm -f "$PATCH_DIR/scheduler.patch"
        echo "==> eevdf is the kernel's default on $kernel_version, no patch needed"
        ;;
    bore)
        wget -nv -O "$PATCH_DIR/scheduler.patch" "$BASE_URL/sched/0001-bore.patch" || {
            echo "ERROR: no bore patch published for kernel $MAJOR_MINOR." >&2
            echo "Check: https://github.com/CachyOS/kernel-patches/tree/master/${MAJOR_MINOR}/sched" >&2
            exit 1
        }
        ;;
    pds|bmq)
        wget -nv -O "$PATCH_DIR/scheduler.patch" "$BASE_URL/sched/0001-prjc-cachy.patch" || {
            echo "ERROR: no pds/bmq (prjc) patch published for kernel $MAJOR_MINOR." >&2
            echo "Check: https://github.com/CachyOS/kernel-patches/tree/master/${MAJOR_MINOR}/sched" >&2
            exit 1
        }
        ;;
    *)
        echo "ERROR: unknown scheduler '$scheduler' (expected cfs, eevdf, bore, pds, or bmq)." >&2
        exit 1
        ;;
esac
