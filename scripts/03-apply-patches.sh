#!/bin/bash
set -euo pipefail

SRC_DIR="$WORK_DIR/src"
PATCH_FILE="$WORK_DIR/patches/scheduler.patch"

if [[ ! -f "$PATCH_FILE" ]]; then
    echo "==> No scheduler patch to apply ($scheduler needs none)"
    exit 0
fi

cd "$SRC_DIR"

# work/src persists across runs (see 01-fetch-source.sh and build.sh's
# kernel_version:scheduler fingerprint, which doesn't cover every field -
# e.g. changing hz/preempt/trim_modules/cpu/localversion, or just retrying
# after an unrelated failure, reuses the same already-patched tree). Plain
# `patch` exits 1 on an already-applied patch ("previously applied"), and
# without --batch/closed stdin it can also stall waiting on a tty for
# "Assume -R?". Dry-run first to tell "already applied" apart from a
# genuine mismatch, and keep stdin closed on every invocation.
if patch -Np1 --fuzz=0 --batch --dry-run -i "$PATCH_FILE" &>/dev/null </dev/null; then
    echo "==> Applying scheduler patch ($scheduler)"
    patch -Np1 --fuzz=0 --batch -i "$PATCH_FILE" </dev/null
elif patch -Np1 --fuzz=0 --batch -R --dry-run -i "$PATCH_FILE" &>/dev/null </dev/null; then
    echo "==> Scheduler patch ($scheduler) already applied, skipping"
else
    echo "ERROR: patch failed to apply cleanly against kernel $kernel_version." >&2
    echo "The CachyOS patch for '$scheduler' may not match this exact point release." >&2
    exit 1
fi
