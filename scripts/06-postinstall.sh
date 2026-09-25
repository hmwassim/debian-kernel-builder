#!/bin/bash
# Runs as root, after the built kernel package is installed (build.sh calls
# this directly - it's not part of the run_as_user fetch/patch/configure/
# compile pipeline in scripts/01-05, since it writes to /etc and reloads
# udev on the live system rather than touching work/ or output/).
#
# 04-configure.sh builds IOSCHED_BFQ/MQ_IOSCHED_KYBER as MODULES rather
# than built-in, specifically so they coexist with debforge's
# (github.com/hmwassim/debforge) modules-load+udev setup instead of making
# its modprobe calls fail every boot (see the comment in 04-configure.sh).
# But a module that's never loaded, and a scheduler that's never assigned
# to a device, doesn't actually do anything - the whole point of building
# them as modules was to let something ELSE load and assign them.
#
# So: if debforge's config-system package is already doing that job, defer
# to it entirely - don't install a second copy of the same thing. If it
# ISN'T present (or its config-system package hasn't been applied), install
# a self-contained equivalent so users who never touch debforge still get
# the same per-device policy out of the box: BFQ for rotational SATA,
# mq-deadline for SATA SSDs/eMMC, and Kyber for NVMe.
set -euo pipefail

MANAGE="${manage_io_schedulers:-yes}"
if [[ "$MANAGE" != "yes" ]]; then
    echo "==> manage_io_schedulers=no, leaving I/O scheduler module loading untouched"
    exit 0
fi

DEBFORGE_MODULES_FILE="/etc/modules-load.d/storage-schedulers.conf"
DEBFORGE_UDEV_FILE="/etc/udev/rules.d/60-scheduler.rules"
OWN_MODULES_FILE="/etc/modules-load.d/90-kernel-builder-schedulers.conf"
OWN_UDEV_FILE="/etc/udev/rules.d/60-kernel-builder-scheduler.rules"

if [[ -f "$DEBFORGE_MODULES_FILE" || -f "$DEBFORGE_UDEV_FILE" ]]; then
    echo "==> debforge's config-system already manages the I/O scheduler policy ($DEBFORGE_MODULES_FILE) - deferring to it"
    # Clean up our own files if a *previous* build wrote them before
    # debforge was set up, so there's exactly one copy of this config
    # managing the system, not two redundant ones.
    if [[ -f "$OWN_MODULES_FILE" || -f "$OWN_UDEV_FILE" ]]; then
        echo "    Removing this tool's own copy - debforge now owns it"
        rm -f "$OWN_MODULES_FILE" "$OWN_UDEV_FILE"
        udevadm control --reload-rules
        udevadm trigger --subsystem-match=block
    fi
    exit 0
fi

echo "==> No system config tool managing I/O scheduler modules - installing a self-contained setup"

cat > "$OWN_MODULES_FILE" <<'EOF'
# Managed by debian-kernel-builder (manage_io_schedulers=yes in kbuild.conf).
# Loads the BFQ and Kyber I/O scheduler modules built by 04-configure.sh
# (CONFIG_IOSCHED_BFQ=m, CONFIG_MQ_IOSCHED_KYBER=m). mq-deadline is built
# into the kernel and needs no module load. If debforge
# (github.com/hmwassim/debforge) is set up on this system, its own
# /etc/modules-load.d/storage-schedulers.conf takes over this job instead
# and this file is removed automatically on the next kernel build.
bfq
kyber-iosched
EOF

cat > "$OWN_UDEV_FILE" <<'EOF'
# Managed by debian-kernel-builder (manage_io_schedulers=yes in kbuild.conf).
# Same per-device policy debforge's config-system uses: BFQ for rotational
# SATA disks, mq-deadline for SATA SSDs and eMMC, and Kyber for NVMe.
# If debforge is set up on this system, its own
# /etc/udev/rules.d/60-scheduler.rules takes over this job instead and
# this file is removed automatically on the next kernel build.
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", \
    ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", \
    ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/rotational}=="0", \
    ATTR{queue/scheduler}="kyber"
EOF

echo "==> Loading modules and applying scheduler assignment now (no reboot needed)"
modprobe bfq 2>/dev/null || echo "    NOTE: modprobe bfq failed - it will load on next boot via modules-load.d"
modprobe kyber-iosched 2>/dev/null || echo "    NOTE: modprobe kyber-iosched failed - it will load on next boot via modules-load.d"
udevadm control --reload-rules
udevadm trigger --subsystem-match=block

echo "==> I/O scheduler modules installed and active"
