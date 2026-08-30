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
   preemption model via `scripts/config`; enables sched-ext support on
   `kernel_version >= 6.12`.
4. **Build** - runs `make bindeb-pkg` with `KCFLAGS=-march=<cpu>` and
   collects the resulting `.deb` files into `output/`.

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

### CPU targeting

`cpu` is applied as a compiler flag, not a Kconfig option: `generic` becomes
`-march=x86-64-v3` (a safe modern baseline), `native` becomes `-march=native`,
and any other value is passed through as `-march=<value>` - so
`rocketlake`, `znver4`, `alderlake`, `x86-64-v4`, etc. are all valid.

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
  `gnupg`/`xz-utils` (installed by `--install-deps`) and network access
  to a keyserver.

## Not included

This is intentionally smaller than [linux-tkg](https://github.com/Frogging-Family/linux-tkg):

- **ccache** - not wired in.
- **Clang/LLVM/ThinLTO builds** - always builds with GCC.
- **Runtime-switchable tuning** - `preempt`, `hz`, and `scheduler` are
  compile-time choices, not `CONFIG_PREEMPT_DYNAMIC`-style boot-time toggles.

## Limitations

- CachyOS publishes scheduler patches per kernel branch as releases come
  out, so a brand-new point release may not have a `bore`/`pds`/`bmq`
  patch yet. The build fails with a link to check rather than falling
  back silently.
- On `kernel_version >= 6.12`, sched-ext's debug-info requirement makes
  `bindeb-pkg` also produce a `linux-image-*-dbg.deb` with full debug
  symbols. It isn't needed to boot or run the kernel and can be deleted.
