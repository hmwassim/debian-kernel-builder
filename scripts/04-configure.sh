#!/bin/bash
set -euo pipefail

SRC_DIR="$WORK_DIR/src"
cd "$SRC_DIR"

echo "==> Preparing baseline .config"
if [[ -f "/boot/config-$(uname -r)" ]]; then
    cp "/boot/config-$(uname -r)" .config
    # Debian's config points SYSTEM_TRUSTED_KEYS/SYSTEM_REVOCATION_KEYS at
    # cert files (e.g. debian/certs/debian-uefi-certs.pem) that only exist
    # in Debian's own packaging tree, not this vanilla kernel.org source -
    # left as-is the build fails looking for them. Clearing them falls
    # back to an auto-generated local module-signing key instead.
    scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
    scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
    make olddefconfig
else
    make defconfig
fi

# ---- CPU target ------------------------------------------------------
# Vanilla kernel.org sources don't have CachyOS's per-microarch Kconfig
# symbols (MROCKETLAKE, MZEN4, ...) - those only exist inside CachyOS's
# own tree, not upstream. Now that stage 1 fetches vanilla, CPU tuning is
# simpler done as a straight compiler `-march=` flag instead (see
# 05-compile.sh, KCFLAGS) - no Kconfig lookup table needed.
echo "==> CPU target '$cpu' will be applied at compile time via -march (see 05-compile.sh)"

# ---- Scheduler ---------------------------------------------------------
echo "==> Setting scheduler: $scheduler"
case "$scheduler" in
    bore)
        scripts/config -e SCHED_BORE
        ;;
    pds)
        scripts/config -e SCHED_ALT -e SCHED_PDS -d SCHED_BMQ
        ;;
    bmq)
        scripts/config -e SCHED_ALT -e SCHED_BMQ -d SCHED_PDS
        ;;
    cfs|eevdf)
        : # nothing to toggle, this is the kernel's own default for the range
        ;;
esac

make olddefconfig
echo "==> Config ready"
