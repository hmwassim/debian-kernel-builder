#!/bin/bash
# Downloads the pristine kernel.org source for kernel_version. This has to
# be vanilla, unpatched source - the scheduler patches in the next stage
# come from CachyOS/kernel-patches, which are generated against plain
# kernel.org trees, not against CachyOS's own (already-modified) kernel
# releases. Applying a vanilla-targeted patch on top of an already-patched
# tree is what causes hunk failures.
set -euo pipefail

MAJOR="${kernel_version%%.*}"

# kernel.org's own naming quirk: the first release of a major.minor series
# ships as linux-X.Y.tar.xz, NOT linux-X.Y.0.tar.xz - the trailing ".0" is
# dropped from the archive filename (later X.Y.Z point releases keep the
# full version, e.g. linux-6.6.1.tar.xz). kernel_version="7.3.0" is a
# perfectly real version a user would type for a fresh major release, so
# strip it for the download filename only - the rest of the script
# (fingerprint, localversion, MAJOR_MINOR comparisons) keeps using the
# version exactly as configured.
DL_VERSION="$kernel_version"
if [[ "$kernel_version" =~ ^[0-9]+\.[0-9]+\.0$ ]]; then
    DL_VERSION="${kernel_version%.0}"
fi
TARBALL="linux-${DL_VERSION}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"
SRC_DIR="$WORK_DIR/src"

if [[ -d "$SRC_DIR" ]]; then
    echo "==> Source already present at $SRC_DIR, skipping download"
    exit 0
fi

echo "==> Fetching kernel source: $URL"
if ! wget -nv -O "$WORK_DIR/$TARBALL" "$URL"; then
    echo "ERROR: could not download $TARBALL from kernel.org." >&2
    echo "Check that $kernel_version is a real released version: https://kernel.org" >&2
    exit 1
fi

# ---- Verify against kernel.org's own PGP signature -----------------------
# This is a root-owned kernel that will end up in /boot - worth checking
# the tarball is actually what kernel.org published before it's ever
# extracted or compiled. Off by default only via kbuild.conf, not here.
if [[ "${verify_signature:-yes}" == "yes" ]]; then
    SIGFILE="linux-${DL_VERSION}.tar.sign"
    SIG_URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${SIGFILE}"

    command -v gpg &>/dev/null || {
        echo "ERROR: verify_signature=yes but gpg is not installed." >&2
        echo "Install gnupg (see build.sh --install-deps) or set verify_signature=\"no\"." >&2
        exit 1
    }

    echo "==> Fetching signature: $SIG_URL"
    wget -nv -O "$WORK_DIR/$SIGFILE" "$SIG_URL"

    # Long key IDs (last 16 hex digits of each fingerprint) for Linus
    # Torvalds and Greg Kroah-Hartman, the two kernel.org release
    # signers - see https://kernel.org/signature.html. Import once.
    LINUS_KEY="79BE3E4300411886"
    GREGKH_KEY="38DBBDC86092693E"
    gpg --list-keys "$LINUS_KEY" &>/dev/null || \
        gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$LINUS_KEY"
    gpg --list-keys "$GREGKH_KEY" &>/dev/null || \
        gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$GREGKH_KEY"

    echo "==> Verifying tarball signature"
    if ! xz -cd "$WORK_DIR/$TARBALL" | gpg --verify "$WORK_DIR/$SIGFILE" -; then
        echo "ERROR: PGP signature verification failed for $TARBALL - refusing to build it." >&2
        exit 1
    fi
    echo "==> Signature OK"
fi

mkdir -p "$SRC_DIR"
tar -xf "$WORK_DIR/$TARBALL" -C "$SRC_DIR" --strip-components=1
echo "==> Extracted to $SRC_DIR"
