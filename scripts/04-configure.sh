#!/bin/bash
set -euo pipefail

SRC_DIR="$WORK_DIR/src"
cd "$SRC_DIR"

# ---- Toolchain (GCC vs Clang/LLVM) ----------------------------------------
# Decided before the very first config generation, not bolted on later:
# CONFIG_CC_IS_CLANG is computed fresh by Kconfig from whichever compiler
# $(CC) resolves to on each individual `make` invocation, so every make
# call against this tree - here and in stage 5 - needs the same LLVM=1 or
# CC_IS_CLANG silently comes back unset and any LTO_CLANG_* choice below
# gets dropped back to LTO_NONE by olddefconfig, the same silent-fallback
# failure mode the hz/preempt checks further down guard against, just one
# step earlier. LLVM=1 is the kernel's own "use the whole LLVM toolchain"
# switch (clang, ld.lld, llvm-ar/nm/objcopy/...) rather than setting each
# tool individually.
case "${toolchain:-gcc}" in
    gcc)   TOOLCHAIN_ARGS=() ;;
    clang) TOOLCHAIN_ARGS=(LLVM=1) ;;
    *)
        echo "ERROR: toolchain must be 'gcc' or 'clang' (got '${toolchain:-}')." >&2
        exit 1
        ;;
esac
echo "==> Toolchain: ${toolchain:-gcc}"

echo "==> Preparing baseline .config"
if [[ -f "/boot/config-$(uname -r)" ]]; then
    cp "/boot/config-$(uname -r)" .config
    make "${TOOLCHAIN_ARGS[@]}" olddefconfig
else
    make "${TOOLCHAIN_ARGS[@]}" defconfig
fi

# ---- Module list trimming ------------------------------------------------
# Only makes sense when building on the machine that will run the kernel:
# it shrinks the module list to whatever's loaded right now via `lsmod`.
if [[ "${trim_modules:-no}" == "yes" ]]; then
    echo "==> Trimming module list to what's currently loaded (localmodconfig)"
    lsmod > "$WORK_DIR/lsmod.txt"
    yes "" | make "${TOOLCHAIN_ARGS[@]}" LSMOD="$WORK_DIR/lsmod.txt" localmodconfig
fi

# Debian's shipped /boot config points signing options at Debian-specific
# cert files (e.g. debian/certs/debian-uefi-certs.pem) that don't exist in
# a vanilla tree and hard-fail the build. Repoint at the kernel's own
# self-generated key instead. See: frogging-family/linux-tkg#54
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" \
               --set-str SYSTEM_REVOCATION_KEYS "" \
               --set-str MODULE_SIG_KEY "certs/signing_key.pem"

# DRM_PANIC_SCREEN_QR_CODE (the QR-code kernel-panic screen) depends on
# CONFIG_RUST, which this tool doesn't set up (needs a pinned rustc +
# bindgen - not worth it for a panic screen). If the inherited baseline
# .config has DRM_PANIC_SCREEN="qr_code" from a stock kernel that did have
# Rust enabled, that string carries over as-is (Kconfig doesn't validate
# it against RUST/DRM_PANIC_SCREEN_QR_CODE - they're unrelated symbol
# types), so the kernel would silently fall back to "user" at boot with a
# dmesg warning. Reset it to what we can actually build.
if grep -q '^CONFIG_DRM_PANIC_SCREEN="qr_code"$' .config 2>/dev/null; then
    echo "==> DRM_PANIC_SCREEN=qr_code needs Rust support this build doesn't have, resetting to 'user'"
    scripts/config --set-str DRM_PANIC_SCREEN user
fi

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

# ---- Link-Time Optimization (Clang only) ----------------------------------
# CONFIG_LTO_CLANG_THIN/FULL only exist under HAS_LTO_CLANG (requires
# CC_IS_CLANG) - there's no GCC equivalent Kconfig path, so lto is only
# meaningful when toolchain=clang. Caught here rather than left to fail
# deep in the build, same as the other case-validated fields in this file.
lto="${lto:-none}"
if [[ "${toolchain:-gcc}" == "clang" ]]; then
    case "$lto" in
        none)
            scripts/config -e LTO_NONE -d LTO_CLANG_THIN -d LTO_CLANG_FULL
            ;;
        thin)
            echo "==> Enabling ThinLTO (CONFIG_LTO_CLANG_THIN)"
            scripts/config -d LTO_NONE -e LTO_CLANG_THIN -d LTO_CLANG_FULL
            ;;
        full)
            echo "==> Enabling full LTO (CONFIG_LTO_CLANG_FULL) - single-threaded link, slow and RAM-hungry"
            scripts/config -d LTO_NONE -d LTO_CLANG_THIN -e LTO_CLANG_FULL
            ;;
        *)
            echo "ERROR: lto must be 'none', 'thin', or 'full' (got '$lto')." >&2
            exit 1
            ;;
    esac
elif [[ "$lto" != "none" ]]; then
    echo "ERROR: lto=\"$lto\" requires toolchain=\"clang\" - GCC has no kernel LTO support." >&2
    exit 1
fi

ver_num() { local M="${1%%.*}" m="${1#*.}"; printf '%d%03d' "$M" "$m"; }
MAJOR_MINOR="$(echo "$kernel_version" | cut -d. -f1,2)"

# ---- NTSYNC (kernel >= 6.14, no kbuild.conf toggle - just a version gate) -
# Module, not built-in: debforge's wine.yaml modprobes it at boot; built-in
# would make that modprobe fail. See README > debforge compatibility.
if (( $(ver_num "$MAJOR_MINOR") >= $(ver_num 6.14) )); then
    echo "==> Enabling NTSYNC as a module (CONFIG_NTSYNC=m)"
    scripts/config -m NTSYNC
else
    echo "==> Skipping NTSYNC: needs kernel_version >= 6.14 (got $kernel_version)"
fi

# ---- sched-ext (kernel >= 6.12) - lets scx_* BPF schedulers run -----------
# Config list per https://github.com/sched-ext/scx/blob/main/kernel.config.
# pds/bmq replace the core scheduler class sched-ext expects, so treat that
# combination as best-effort.
if (( $(ver_num "$MAJOR_MINOR") >= $(ver_num 6.12) )); then
    echo "==> Enabling sched-ext (CONFIG_SCHED_CLASS_EXT and friends)"
    scripts/config \
        -e BPF -e BPF_SYSCALL -e BPF_JIT \
        -e DEBUG_INFO -e DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -e DEBUG_INFO_BTF \
        -e BPF_JIT_ALWAYS_ON -e BPF_JIT_DEFAULT_ON \
        -e SCHED_CLASS_EXT \
        -e KALLSYMS_ALL -e FUNCTION_TRACER -e IKCONFIG -e IKCONFIG_PROC
    if [[ "$scheduler" == "pds" || "$scheduler" == "bmq" ]]; then
        echo "    NOTE: sched-ext + $scheduler is untested - core scheduler is replaced by $scheduler"
    fi
else
    echo "==> Skipping sched-ext: needs kernel_version >= 6.12 (got $kernel_version)"
fi

# ---- Gaming tweaks: THP + legacy GCN amdgpu support ----------------------
if [[ "${gaming_tweaks:-no}" == "yes" ]]; then
    echo "==> Setting Transparent Hugepages to always (CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS)"
    scripts/config -e TRANSPARENT_HUGEPAGE_ALWAYS -d TRANSPARENT_HUGEPAGE_MADVISE

    echo "==> Enabling AMD GCN 1.0/1.1 support in amdgpu (CONFIG_DRM_AMDGPU_SI / CIK)"
    scripts/config -e DRM_AMDGPU_SI -e DRM_AMDGPU_CIK
fi

# ---- Interactive I/O schedulers ------------------------------------------
# Keep mq-deadline built in for the SATA/eMMC policy. BFQ_GROUP_IOSCHED
# stays -e: it's a bool, not tristate, so it just rides along with BFQ.
# BFQ and Kyber remain modules so debforge's modules-load setup can load
# them; mq-deadline needs no module load. See README > debforge
# compatibility, and manage_io_schedulers/06-postinstall.sh for what
# actually loads/assigns them at install time.
scripts/config -e MQ_IOSCHED_DEADLINE -m IOSCHED_BFQ -e BFQ_GROUP_IOSCHED -m MQ_IOSCHED_KYBER

make "${TOOLCHAIN_ARGS[@]}" olddefconfig

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

make "${TOOLCHAIN_ARGS[@]}" olddefconfig

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

# mq-deadline is the fixed fallback policy for SATA SSDs and eMMC, so do
# not let a Kconfig dependency silently remove it from the generated image.
if ! grep -q '^CONFIG_MQ_IOSCHED_DEADLINE=y$' .config; then
    echo "ERROR: CONFIG_MQ_IOSCHED_DEADLINE did not stick after olddefconfig." >&2
    exit 1
fi

# Same silent-fallback risk as preempt above, one layer deeper: if Clang
# somehow isn't detected (missing binary, broken update-alternatives),
# CONFIG_CC_IS_CLANG comes back unset and every LTO_CLANG_* choice quietly
# reverts to LTO_NONE instead of failing loudly.
if [[ "${toolchain:-gcc}" == "clang" ]]; then
    if ! grep -q "^CONFIG_CC_IS_CLANG=y" .config; then
        echo "ERROR: toolchain=clang but Kconfig didn't detect Clang (CONFIG_CC_IS_CLANG unset)." >&2
        echo "Check that clang/lld/llvm are installed and 'clang --version' works." >&2
        exit 1
    fi
    case "$lto" in
        none) WANT_LTO=LTO_NONE ;;
        thin) WANT_LTO=LTO_CLANG_THIN ;;
        full) WANT_LTO=LTO_CLANG_FULL ;;
    esac
    if ! grep -q "^CONFIG_${WANT_LTO}=y" .config; then
        echo "ERROR: lto=$lto (CONFIG_$WANT_LTO) did not stick after olddefconfig." >&2
        echo "This kernel_version/arch combination may not support it." >&2
        exit 1
    fi
fi

echo "==> Config ready"
