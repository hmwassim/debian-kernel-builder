# debian-kernel-builder

Automated, non-interactive kernel build tool for Debian 13 (Trixie). Edit
`kbuild.conf`, run `./build.sh`, and install the resulting `.deb` packages.

## Requirements

- Debian 13 (Trixie), x86_64
- Root or sudo access for `--install-deps` and package installation
- ~15-25 GB free disk space and 20-60+ minutes per build, depending on
  configuration and hardware

## Usage

```sh
chmod +x build.sh scripts/*.sh
./build.sh --install-deps   # first run only: installs build dependencies
./build.sh                  # every run after that
```

Packages land in `output/` (`linux-image-*.deb`, `linux-headers-*.deb`).
Install with:

```sh
sudo dpkg -i output/*.deb
```

## How it works

1. **Source** - downloads the vanilla kernel.org tarball for `kernel_version`.
2. **Patches** - for `scheduler = bore`, `pds`, or `bmq`, downloads and
   applies the matching patch from
   [CachyOS/kernel-patches](https://github.com/CachyOS/kernel-patches) for
   that kernel's major.minor branch. `cfs` and `eevdf` need no patch.
3. **Configure** - starts from `/boot/config-$(uname -r)` if present,
   otherwise `make defconfig`; sets the scheduler, tick rate, and
   preemption model via `scripts/config`; enables NTSYNC on
   `kernel_version >= 6.14` and sched-ext support on `kernel_version >= 6.12`.
4. **Build** - runs `make bindeb-pkg` with `KCFLAGS=-march=<cpu>` and
   collects the resulting `.deb` files into `output/`.
5. **Install & activate** - `build.sh` installs the resulting `.deb`, then
   runs `scripts/06-postinstall.sh` to load and assign the BFQ/Kyber I/O
   scheduler modules built in step 3 (unless [debforge](#debforge-compatibility)
   is already doing that, or `manage_io_schedulers=no`).

## Configuration

All settings are in `kbuild.conf`.

| Field | Values | Notes |
|---|---|---|
| `kernel_version` | e.g. `7.2.2` | Must be a real kernel.org release |
| `cpu` | `generic`, `native`, or any GCC/Clang `-march` name | See [CPU targeting](#cpu-targeting) |
| `scheduler` | `cfs`, `eevdf`, `bore`, `pds`, `bmq` | `cfs` requires `kernel_version < 6.6`; `eevdf` requires `>= 6.6` |
| `jobs` | number, or empty | Empty uses `nproc` |
| `localversion` | string | Appended to the package version, e.g. `-custom` |
| `hz` | `100`, `250`, `300`, `1000` | Timer tick rate (`CONFIG_HZ`); `250` is upstream's default |
| `preempt` | `lazy`, `full` | Preemption model - see [below](#preemption-model) |
| `trim_modules` | `yes`/`no` | Shrinks the module list to `lsmod` on the build machine; default `no` |
| `verify_signature` | `yes`/`no` | Verifies the tarball against kernel.org's PGP signature; default `yes` |
| `gaming_tweaks` | `yes`/`no` | Bundle of Solus-ported tweaks - see [below](#gaming-tweaks); default `yes` |
| `acs_override` | `yes`/`no` | Adds PCIe ACS Override patch for VFIO IOMMU group separation; default `no` |
| `manage_io_schedulers` | `yes`/`no` | Loads & assigns the BFQ/Kyber I/O scheduler modules per-device after install, unless [debforge](#debforge-compatibility) is already doing it; default `yes` |


### CPU targeting

`cpu` is applied as a compiler flag, not a Kconfig option: `generic` becomes
`-march=x86-64-v3` (a safe modern baseline), `native` becomes `-march=native`,
and any other value is passed through as `-march=<value>` - so
`rocketlake`, `znver4`, `alderlake`, `x86-64-v4`, etc. are all valid.

### NTSYNC

[NTSYNC](https://docs.kernel.org/next/userspace-api/ntsync.html)
(`CONFIG_NTSYNC`, mainlined in kernel 6.14, used by Wine 11+/Proton 11+)
is enabled unconditionally whenever `kernel_version >= 6.14` - it's not a
`kbuild.conf` field because it's not hardware- or preference-dependent,
just a device node (`/dev/ntsync`) that sits idle unless something opens
it, so there's nothing to weigh.

### sched-ext

On `kernel_version >= 6.12`, the build enables [sched-ext](https://github.com/sched-ext/scx)
support: `CONFIG_SCHED_CLASS_EXT` and its required Kconfig options
(`BPF`, `BPF_SYSCALL`, `BPF_JIT`, `DEBUG_INFO`/`DEBUG_INFO_BTF`,
`KALLSYMS_ALL`, `FUNCTION_TRACER`, `IKCONFIG`/`IKCONFIG_PROC`). This lets
`scx_*` BPF schedulers run on the resulting kernel alongside whichever
`scheduler` you picked as the fallback. `pds`/`bmq` replace the core
scheduler class, so combining either with sched-ext is untested;
`bore`/`cfs`/`eevdf` are the supported pairings.

### Preemption model

`preempt` only offers `lazy` and `full`. Current x86_64 kernels no longer
support `PREEMPT_NONE`/`PREEMPT_VOLUNTARY` as selectable options
(`kernel/Kconfig.preempt`). `lazy` (`CONFIG_PREEMPT_LAZY`) is the kernel's
own current default; `full` (`CONFIG_PREEMPT`) is the low-latency option.
The build verifies the choice stuck in `.config` after `olddefconfig`
rather than silently falling back to a default.

### Module trimming and signature verification

- `trim_modules=yes` runs `make localmodconfig` against the build
  machine's `lsmod` output. Only appropriate when building on the exact
  machine that will run the kernel, since it can drop drivers for
  hardware that isn't currently attached or active.
- `verify_signature=yes` checks the downloaded tarball against
  kernel.org's PGP signature before it's extracted or built. Requires
  `gnupg`/`xz-utils` (installed by `--install-deps`) and, once, network
  access to a keyserver to import the release keys.

### Gaming tweaks

`gaming_tweaks=yes` (default) applies a bundle of low-risk changes ported
from Solus OS's kernel packaging, all complementary and grouped under one
toggle rather than five separate ones:

- **AMD private color** - `-DAMD_PRIVATE_COLOR` in `KCFLAGS`, for
  Gamescope/HDR color pipelines.
- **AMDGPU Overdrive** - `amdgpu.overdrive_enabled=1`, for fan curves and
  overclocking in LACT/CoreCtrl without the `ppfeaturemask` bitmask.
- **Elevated `vm.max_map_count`** - raised to `INT_MAX - 5`, matching
  SteamOS/Fedora, to stop Proton/Wine mmap-exhaustion crashes.
- **Transparent Hugepages = always** - cuts page fault/TLB overhead for
  gaming and memory-heavy workloads.
- **Legacy GCN Vulkan support** - `CONFIG_DRM_AMDGPU_SI`/`_CIK`, so older
  Radeon HD 7000/8000/R7/R9 cards use `amdgpu` (Vulkan/RADV) instead of
  the legacy `radeon` driver.

`acs_override=yes` is kept separate because it's a real trade-off, not a
free win: it applies `pcie_acs_override=downstream,multifunction` to split
IOMMU groups for GPU/PCIe passthrough to KVM/QEMU VMs, at the cost of
bypassing hardware isolation between devices in the same group. Off by
default; only turn it on if you're actually doing passthrough.

### debforge compatibility

If you use [debforge](https://github.com/hmwassim/debforge) (a separate,
optional Debian post-install/system-config tool) alongside this kernel
builder, the two are designed to never fight each other - and if you don't
use debforge at all, this project still delivers the same day-to-day
behavior on its own:

| Feature | This tool (kernel build) | debforge (system config) | Result |
|---|---|---|---|
| NTSYNC | `CONFIG_NTSYNC=m` unconditionally on `>= 6.14` | `wine.yaml` modprobes it + a udev rule | Module loads at boot either way |
| BFQ / Kyber I/O schedulers | `CONFIG_IOSCHED_BFQ=m`, `CONFIG_MQ_IOSCHED_KYBER=m` (never built-in; `BFQ_GROUP_IOSCHED` is a `bool` sub-option that just follows BFQ into the module) | `config-system.yaml` modprobes both + assigns per-device via udev | If debforge's files exist, this tool defers to them entirely. If not, `06-postinstall.sh` installs its own equivalent modules-load + udev rule (same policy: bfq for rotational/SD, kyber for SATA SSD, none for NVMe) so it still works without debforge. Controlled by `manage_io_schedulers` |
| `vm.max_map_count` | kernel *default* raised to `INT_MAX - 5` via patch (`gaming_tweaks=yes`) | `config-system.yaml` sets the same value via `/etc/sysctl.d/99-debforge.conf` | Redundant but harmless together; the kernel default alone already covers users without debforge |
| Transparent Hugepages | `CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y` (compile-time promotion policy) | `tmpfiles-thp.conf`/`tmpfiles-thp-shrinker.conf` tune the separate runtime `defrag`/shrinker knobs | Complementary - different knobs, no overlap |
| sched-ext | `CONFIG_SCHED_CLASS_EXT` and friends on `>= 6.12` | `scx-scheds`/`scx-switcher`/`scx-tools` packages depend on exactly this | debforge's scx packages need this tool's kernel (or any kernel with the same config) to function |
| Kernel package | builds `linux-image-<version><localversion>` from source | `step_kernel.go` installs stock `linux-image-amd64` from Debian backports | Different package names, both can be installed side by side; whichever you boot into (GRUB) is the one that's active |

Why BFQ/Kyber are modules and not built directly into the kernel: a
built-in scheduler can't be `modprobe`'d, so debforge's
`/etc/modules-load.d/storage-schedulers.conf` would fail every boot with a
"module not found" error from `systemd-modules-load.service` - annoying,
not harmful, but avoidable. Building them as modules keeps debforge's
modprobe working, and `06-postinstall.sh` covers the case where debforge
isn't installed at all.

### Custom User Patches

Place any additional `.patch` files directly inside `patches/user/`. Stage 3
(`03-apply-patches.sh`) automatically dry-runs and applies every patch in
alphabetical order with full idempotence (skips already-applied patches on retries).

## Not included

This is intentionally smaller than [linux-tkg](https://github.com/Frogging-Family/linux-tkg):

- **ccache** - not wired in.
- **Clang/LLVM/ThinLTO builds** - always builds with GCC.
- **Runtime-switchable tuning** - `preempt`, `hz`, and `scheduler` are
  compile-time choices, not `CONFIG_PREEMPT_DYNAMIC`-style boot-time toggles.

## Limitations

- No Rust kernel support (`CONFIG_RUST`) - needs a pinned rustc/bindgen
  toolchain, not worth the fragility for what it currently gates (mainly
  the QR-code kernel-panic screen). If your baseline `.config` inherited
  `DRM_PANIC_SCREEN="qr_code"` from a Rust-enabled stock kernel,
  `04-configure.sh` resets it to `"user"` so it matches what's actually
  built, instead of silently falling back at boot with a dmesg warning.
- CachyOS publishes scheduler patches per kernel branch as releases come
  out, so a brand-new point release may not have a `bore`/`pds`/`bmq`
  patch yet. The build fails with a link to check rather than falling
  back silently.
- On `kernel_version >= 6.12`, sched-ext's debug-info requirement makes
  `bindeb-pkg` also produce a `linux-image-*-dbg.deb` with full debug
  symbols. It isn't needed to boot or run the kernel and can be deleted.
- `acs_override` (opt-in) and `ccache-friendly.patch` (always applied) are
  still context-diff patch files pinned to a specific historical kernel
  snapshot - the same class of patch that broke for `vm.max_map_count` on
  kernel 7.2.5 (see [Gaming tweaks](#gaming-tweaks); that one's since been
  changed to a version-tolerant substitution instead). Neither has been
  observed failing, but if you hit "failed to apply cleanly" on either,
  that's the same upstream-drift issue, not something specific to your
  setup - check the target file's current context against the patch by
  hand, or open an issue with the exact `kernel_version`.
