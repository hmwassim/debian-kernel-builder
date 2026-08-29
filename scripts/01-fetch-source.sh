#!/bin/bash
# Downloads the vanilla kernel.org source tarball for kernel_version.
#
# This is deliberately NOT CachyOS's own pre-built release tarball. The
# scheduler patches in CachyOS/kernel-patches (stage 2) are generated
# against plain kernel.org sources. Applying a vanilla-targeted patch on
# top of CachyOS's own already-patched tree produces partial hunk
# failures - the line offsets and surrounding context no longer match.
# Building on vanilla is what lets those patches apply cleanly.
set -euo pipefail

MAJOR="$(echo "$kernel_version" | cut -d. -f1)"
TARBALL="linux-${kernel_version}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"
SRC_DIR="$WORK_DIR/src"

if [[ -d "$SRC_DIR" ]]; then
    echo "==> Source already present at $SRC_DIR, skipping download"
    exit 0
fi

echo "==> Fetching kernel source: $URL"
if ! wget -nv --show-progress --progress=bar:force:noscroll \
        --connect-timeout=15 --read-timeout=60 --tries=3 \
        -O "$WORK_DIR/$TARBALL" "$URL"; then
    echo "ERROR: no kernel.org release found for version '$kernel_version'," >&2
    echo "or the download stalled/failed after retries." >&2
    echo "Check available versions: https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/" >&2
    exit 1
fi

# ---- Optional PGP verification ----------------------------------------
# Off by default: it needs gpg and a keyserver reachable at build time,
# neither of which every environment has. Set verify_signature="yes" in
# kbuild.conf to check the tarball against kernel.org's own release keys
# before it's ever extracted and compiled as a root-owned kernel.
if [[ "${verify_signature:-no}" == "yes" ]]; then
    SIGFILE="linux-${kernel_version}.tar.sign"
    SIG_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${SIGFILE}"

    command -v gpg &>/dev/null || {
        echo "ERROR: verify_signature=yes but gpg is not installed." >&2
        exit 1
    }

    echo "==> Fetching signature: $SIG_URL"
    wget -nv --connect-timeout=15 --read-timeout=60 --tries=3 \
        -O "$WORK_DIR/$SIGFILE" "$SIG_URL"

    # Linus Torvalds and Greg Kroah-Hartman's kernel.org release-signing
    # keys (long key IDs, i.e. the last 16 hex digits of each fingerprint;
    # see https://kernel.org/signature.html). Import if not already present.
    LINUS_KEY="79BE3E4300411886"
    GREGKH_KEY="38DBBDC86092693E"
    gpg --list-keys "$LINUS_KEY" &>/dev/null || \
        gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$LINUS_KEY"
    gpg --list-keys "$GREGKH_KEY" &>/dev/null || \
        gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$GREGKH_KEY"

    echo "==> Verifying tarball signature"
    if ! xz -cd "$WORK_DIR/$TARBALL" | gpg --verify "$WORK_DIR/$SIGFILE" -; then
        echo "ERROR: PGP signature verification failed for $TARBALL." >&2
        echo "Do not build this tarball - it does not match the signed release." >&2
        exit 1
    fi
    echo "==> Signature OK"
fi

mkdir -p "$SRC_DIR"
tar -xf "$WORK_DIR/$TARBALL" -C "$SRC_DIR" --strip-components=1
echo "==> Extracted to $SRC_DIR"
