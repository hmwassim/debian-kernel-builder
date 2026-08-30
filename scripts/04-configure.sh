#!/bin/bash
set -euo pipefail

SRC_DIR="$WORK_DIR/src"
cd "$SRC_DIR"

echo "==> Preparing baseline .config"
if [[ -f "/boot/config-$(uname -r)" ]]; then
    cp "/boot/config-$(uname -r)" .config
    make olddefconfig
else
    make defconfig
fi

# ---- Module list trimming ------------------------------------------------
# Only makes sense when building on the machine that will run the kernel:
# it shrinks the module list to whatever's loaded right now via `lsmod`.
if [[ "${trim_modules:-no}" == "yes" ]]; then
    echo "==> Trimming module list to what's currently loaded (localmodconfig)"
    lsmod > "$WORK_DIR/lsmod.txt"
    yes "" | make LSMOD="$WORK_DIR/lsmod.txt" localmodconfig
fi

# Debian's shipped /boot config points signing options at Debian-specific
# cert files (e.g. debian/certs/debian-uefi-certs.pem) that don't exist in
# a vanilla tree and hard-fail the build. Repoint at the kernel's own
# self-generated key instead. See: frogging-family/linux-tkg#54
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" \
               --set-str SYSTEM_REVOCATION_KEYS "" \
               --set-str MODULE_SIG_KEY "certs/signing_key.pem"

# ---- Scheduler ---------------------------------------------------------
# cpu tuning is handled as a compiler -march flag at build time (stage 5)
# instead of Kconfig, since the per-microarch CPU options (GENERIC_CPU,
# MZEN4, MROCKETLAKE, ...) only exist in CachyOS's own tree, not in
# vanilla kernel.org sources.
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

# ---- sched-ext (https://github.com/sched-ext/scx) -----------------------
# Fully upstreamed since kernel 6.12 - just Kconfig, no patch needed.
# This is what lets scx_* BPF schedulers (and tools like scx-switcher) run
# on the resulting kernel; it coexists with cfs/eevdf/bore as a pluggable
# extra scheduling class. PDS/BMQ replace the core scheduler class
# structure that sched-ext's fallback path expects, so the combination is
# untested here - if you use pds/bmq, treat sched-ext support as best-effort.
ver_num() { local M="${1%%.*}" m="${1#*.}"; printf '%d%03d' "$M" "$m"; }
MAJOR_MINOR="$(echo "$kernel_version" | cut -d. -f1,2)"
if (( $(ver_num "$MAJOR_MINOR") >= $(ver_num 6.12) )); then
    echo "==> Enabling sched-ext (CONFIG_SCHED_CLASS_EXT and friends)"
    scripts/config \
        -e BPF -e BPF_SYSCALL -e BPF_JIT \
        -e DEBUG_INFO -e DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -e DEBUG_INFO_BTF \
        -e BPF_JIT_ALWAYS_ON -e BPF_JIT_DEFAULT_ON \
        -e SCHED_CLASS_EXT
    # Checked directly against sched-ext's own required-config list
    # (https://github.com/sched-ext/scx/blob/main/kernel.config):
    #   - KALLSYMS_ALL: needed by some Rust schedulers, e.g. scx_p2dq.
    #   - FUNCTION_TRACER: scx_lavd uses ftrace to track futex calls for its
    #     lock-holder preemption avoidance, falling back to a tracepoint if
    #     ftrace isn't built - a soft dependency, but cheap to enable.
    #   - IKCONFIG/IKCONFIG_PROC: exposes the running kernel's config at
    #     /proc/config.gz, handy for confirming these options actually made
    #     it into the kernel you booted.
    # Deliberately NOT pulling in the rest of that upstream file - things
    # like DEBUG_LOCKDEP/PROVE_LOCKING/full PREEMPT/kprobes/uprobes are
    # scx's own CI/test-coverage config, not requirements for running scx
    # schedulers, and carry real runtime overhead that has no place in a
    # kernel meant to actually be used day to day.
    scripts/config -e KALLSYMS_ALL -e FUNCTION_TRACER -e IKCONFIG -e IKCONFIG_PROC
    if [[ "$scheduler" == "pds" || "$scheduler" == "bmq" ]]; then
        echo "    NOTE: sched-ext + $scheduler is untested - core scheduler is replaced by $scheduler"
    fi
else
    echo "==> Skipping sched-ext: needs kernel_version >= 6.12 (got $kernel_version)"
fi

make olddefconfig

# ---- Timer tick rate (CONFIG_HZ) -----------------------------------------
echo "==> Setting tick rate: ${hz}Hz"
case "$hz" in
    100)  WANT_HZ=HZ_100;  scripts/config -e HZ_100  -d HZ_250 -d HZ_300 -d HZ_1000 ;;
    250)  WANT_HZ=HZ_250;  scripts/config -d HZ_100  -e HZ_250 -d HZ_300 -d HZ_1000 ;;
    300)  WANT_HZ=HZ_300;  scripts/config -d HZ_100  -d HZ_250 -e HZ_300 -d HZ_1000 ;;
    1000) WANT_HZ=HZ_1000; scripts/config -d HZ_100  -d HZ_250 -d HZ_300 -e HZ_1000 ;;
    *)
        echo "ERROR: hz must be one of 100, 250, 300, 1000 (got '$hz')." >&2
        exit 1
        ;;
esac

# ---- Preemption model -----------------------------------------------------
# On current x86_64 kernels the "choice" block only offers PREEMPT_LAZY and
# PREEMPT (see kernel/Kconfig.preempt) - PREEMPT_NONE/PREEMPT_VOLUNTARY both
# carry a `depends on` that x86_64 no longer satisfies. Setting either of
# those here would just get silently dropped back to a default by
# olddefconfig, so lazy/full are the only two offered.
echo "==> Setting preemption model: $preempt"
case "$preempt" in
    lazy) WANT_PREEMPT=PREEMPT_LAZY; scripts/config -d PREEMPT_NONE -d PREEMPT_VOLUNTARY -e PREEMPT_LAZY -d PREEMPT ;;
    full) WANT_PREEMPT=PREEMPT;      scripts/config -d PREEMPT_NONE -d PREEMPT_VOLUNTARY -d PREEMPT_LAZY -e PREEMPT ;;
    *)
        echo "ERROR: preempt must be 'lazy' or 'full' (got '$preempt')." >&2
        exit 1
        ;;
esac

make olddefconfig

# Belt-and-braces alongside the preempt check below: HZ_100/250/300/1000
# carry no `depends on` on any arch this project targets, so this should
# never actually trip, but it's a one-line guard against silent drift.
if ! grep -q "^CONFIG_${WANT_HZ}=y" .config; then
    echo "ERROR: hz=$hz (CONFIG_$WANT_HZ) did not stick after olddefconfig." >&2
    exit 1
fi

# olddefconfig silently falls back to a Kconfig default whenever a
# `depends on` isn't met, so confirm the preemption choice actually stuck
# rather than quietly shipping a different model than kbuild.conf asked for.
if ! grep -q "^CONFIG_${WANT_PREEMPT}=y" .config; then
    echo "ERROR: preempt=$preempt (CONFIG_$WANT_PREEMPT) did not stick after olddefconfig." >&2
    echo "This kernel_version/arch combination may not support it." >&2
    exit 1
fi

echo "==> Config ready"
