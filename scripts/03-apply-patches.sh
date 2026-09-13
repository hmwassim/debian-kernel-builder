#!/bin/bash
set -euo pipefail

SRC_DIR="$WORK_DIR/src"
cd "$SRC_DIR"

apply_patch() {
    local patch_path="$1"
    local patch_desc="$2"

    if [[ ! -f "$patch_path" ]]; then
        echo "ERROR: patch file '$patch_path' not found." >&2
        exit 1
    fi

    if patch -Np1 --fuzz=0 --batch --dry-run -i "$patch_path" &>/dev/null </dev/null; then
        echo "==> Applying patch: $patch_desc"
        patch -Np1 --fuzz=0 --batch -i "$patch_path" </dev/null
    elif patch -Np1 --fuzz=0 --batch -R --dry-run -i "$patch_path" &>/dev/null </dev/null; then
        echo "==> Patch '$patch_desc' already applied, skipping"
    else
        echo "ERROR: patch '$patch_desc' failed to apply cleanly against kernel $kernel_version." >&2
        exit 1
    fi
}

# A handful of the Solus-ported changes are really a single constant flip
# buried in a header/Makefile that upstream keeps reorganizing around (new
# macros, comments, moved lines) - the actual line never gets touched, but
# a 3-line context diff around it goes stale as soon as anything nearby
# shifts, and fails outright rather than just drifting by an offset (that's
# what happened here on kernel 7.2.5: the two lines immediately after
# DEFAULT_MAX_MAP_COUNT in include/linux/mm.h aren't what they were when
# this patch was authored, even though the macro itself is untouched).
# For these, match on the macro/line content itself instead of its
# surroundings - that survives header reshuffling as long as upstream
# doesn't rename the symbol outright, which would need attention anyway.
set_define() {
    local file="$1" macro="$2" from_value="$3" to_value="$4" desc="$5"
    local from_re to_re

    from_re="^([[:space:]]*#[[:space:]]*define[[:space:]]+${macro}[[:space:]]+)$(printf '%s' "$from_value" | sed -E 's/[][\.^$*+?(){}|\\/]/\\&/g')[[:space:]]*$"
    to_re="^([[:space:]]*#[[:space:]]*define[[:space:]]+${macro}[[:space:]]+)$(printf '%s' "$to_value" | sed -E 's/[][\.^$*+?(){}|\\/]/\\&/g')[[:space:]]*$"

    if grep -qE "$to_re" "$file"; then
        echo "==> '$desc' already applied, skipping"
    elif grep -qE "$from_re" "$file"; then
        echo "==> Applying: $desc"
        sed -i -E "s/${from_re}/\\1${to_value//\\/\\\\}/" "$file"
    else
        echo "ERROR: couldn't find '#define $macro $from_value' (or the already-applied form) in $file." >&2
        echo "       Upstream may have renamed or restructured this macro on kernel $kernel_version - check it manually." >&2
        exit 1
    fi
}

# ---- 1. CPU Scheduler patch ----------------------------------------------
SCHED_PATCH="$WORK_DIR/patches/scheduler.patch"
if [[ -f "$SCHED_PATCH" ]]; then
    apply_patch "$SCHED_PATCH" "scheduler ($scheduler)"
else
    echo "==> No scheduler patch to apply ($scheduler needs none)"
fi

# ---- 2. Gaming tweaks (bundled under one kbuild.conf toggle) -------------
if [[ "${gaming_tweaks:-no}" == "yes" ]]; then
    apply_patch "$ROOT_DIR/patches/amdgpu-overdrive.patch" "AMDGPU Overdrive argument"
    set_define include/linux/mm.h DEFAULT_MAX_MAP_COUNT \
        "(USHRT_MAX - MAPCOUNT_ELF_CORE_MARGIN)" \
        "(INT_MAX - MAPCOUNT_ELF_CORE_MARGIN)" \
        "vm.max_map_count = INT_MAX - 5"
fi

if [[ "${acs_override:-no}" == "yes" ]]; then
    apply_patch "$ROOT_DIR/patches/acs-override.patch" "PCIe ACS Override"
fi

# Always applied: pure build-tooling compatibility fix (documented -MMD -MF
# flags instead of an internal -Wp,-MMD passthrough), no effect on the
# resulting kernel and no downside without ccache either.
apply_patch "$ROOT_DIR/patches/ccache-friendly.patch" "ccache-friendly Makefile"

# ---- 3. Custom User patches ----------------------------------------------
if [[ -d "$ROOT_DIR/patches/user" ]]; then
    for p in "$ROOT_DIR/patches/user"/*.patch; do
        [[ -f "$p" ]] || continue
        apply_patch "$p" "User patch: $(basename "$p")"
    done
fi


