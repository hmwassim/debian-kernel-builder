#!/bin/bash
set -euo pipefail

SRC_DIR="$WORK_DIR/src"
PATCH_FILE="$WORK_DIR/patches/scheduler.patch"

if [[ ! -f "$PATCH_FILE" ]]; then
    echo "==> No scheduler patch to apply ($scheduler needs none)"
    exit 0
fi

cd "$SRC_DIR"

# work/src persists across runs (see 01-fetch-source.sh), so a rerun with
# the same scheduler hits a tree that's already patched. `patch` detects
# that and exits 1 ("previously applied"), which used to be treated as a
# hard failure. Dry-run first to tell "already applied" apart from a
# genuine mismatch.
if patch -Np1 --fuzz=0 --dry-run -i "$PATCH_FILE" &>/dev/null </dev/null; then
    echo "==> Applying scheduler patch ($scheduler)"
    patch -Np1 --fuzz=0 -i "$PATCH_FILE" </dev/null
elif patch -Np1 --fuzz=0 -R --dry-run -i "$PATCH_FILE" &>/dev/null </dev/null; then
    echo "==> Scheduler patch ($scheduler) already applied, skipping"
else
    echo "ERROR: patch failed to apply cleanly against kernel $kernel_version." >&2
    echo "The CachyOS patch for '$scheduler' may not match this exact point release." >&2
    exit 1
fi
