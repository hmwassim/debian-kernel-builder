# debian-kernel-builder

Automated, non-interactive kernel build + patch tool for Debian 13 (Trixie).
Edit `kbuild.conf`, run `./build.sh`, get `.deb` packages in `output/`. No
prompts, no wizard.

## Usage

```sh
chmod +x build.sh scripts/*.sh
./build.sh --install-deps   # first run only: apt-get install build deps
./build.sh                  # every run after that
```

Output packages land in `output/` (`linux-image-*.deb`, `linux-headers-*.deb`).
Install with `sudo dpkg -i output/*.deb`.

## How it works

1. **Source** - downloads the vanilla kernel.org release tarball for
   `kernel_version` from `cdn.kernel.org`. This is deliberately plain
   upstream source, not CachyOS's own tree - see the note below.
2. **Patches** - if `scheduler` is `bore`, `pds`, or `bmq`, downloads the
   matching patch from
   [CachyOS/kernel-patches](https://github.com/CachyOS/kernel-patches) for
   that kernel's major.minor branch and applies it. Those patches are
   generated against vanilla kernel.org sources, which is exactly why stage
   1 fetches vanilla rather than CachyOS's own pre-patched tree - applying
   a vanilla-targeted patch on an already-patched tree produces hunk
   failures from mismatched offsets/context. `cfs`/`eevdf` need no patch -
   they're just the kernel's own scheduler for that version range.
3. **Configure** - starts from `/boot/config-$(uname -r)` if present (else
   `make defconfig`), then flips the scheduler Kconfig options via the
   kernel's own `scripts/config`. CPU tuning isn't a Kconfig option here -
   see below.
4. **Build** - `make bindeb-pkg` with `KCFLAGS=-march=<target>` for the
   chosen `cpu`, then collects the resulting `.deb`s.

## kbuild.conf fields

| Field | Values | Notes |
|---|---|---|
| `kernel_version` | e.g. `7.2.2` | Must match a real release at [kernel.org](https://kernel.org) |
| `cpu` | `generic`, `native`, or a microarch name | Compiled in as a `-march=` flag - see below |
| `scheduler` | `cfs`, `eevdf`, `bore`, `pds`, `bmq` | `cfs` needs `kernel_version < 6.6`, `eevdf` needs `>= 6.6` |
| `jobs` | number, or empty | Empty = `nproc` |
| `localversion` | string | Appended to the package version, e.g. `-custom` |
| `verify_signature` | `no` (default) or `yes` | Verify the kernel.org tarball against its PGP signature before building. `yes` needs `gpg` and a reachable keyserver on first run to import the release-signing keys |

### CPU names

`generic` maps to `-march=x86-64-v3` (a safe baseline that boots on any
modern 64-bit CPU). `native` maps to `-march=native` (tuned for the machine
doing the build - not portable to other machines). Anything else is passed
straight through as the `-march` value - `rocketlake`, `alderlake`,
`tigerlake`, `znver4`, etc. are already valid GCC/Clang `-march` names, so
there's no lookup table and no Kconfig symbol involved. If your compiler
doesn't recognize a name (usually only an issue for very new microarchs on
an older GCC/Clang), the build fails with GCC's own "bad value" error for
`-march`.

## Caveats worth knowing before you script this into a habit

- **Reruns reuse the source tree, and the applied patches stick.** `work/src`
  persists between runs (see stage 1), so changing the `scheduler` in the
  middle of a series of builds leaves the previous scheduler's patch applied
  to a reused tree; the build then errors out on the patch apply. Fix it by
  wiping the workspace: `rm -rf work/` (and `output/` if you want the debs
  rebuilt too). Keeping the same config between runs is fine - already
  applied patches are detected and skipped.
- **Patch coverage is real, not automatic.** CachyOS publishes scheduler
  patches per kernel major.minor branch as they cut them - a brand new point
  release may not have a `bore`/`pds`/`bmq` patch yet even if the kernel
  itself is out. The build fails loudly with a link to check rather than
  silently falling back to something else.
- **Source comes straight from kernel.org now**, so `kernel_version` just
  needs to be a version that's actually been released - check
  [kernel.org](https://kernel.org) for what's current. If the tarball isn't
  there, stage 1 fails with the directory URL so you can pick a version
  that exists.
- Because the base source is vanilla, CachyOS's own tuning conveniences
  beyond scheduler/CPU (their `-O3` default, HZ choices, etc.) aren't
  carried over automatically - plain `make defconfig`/`olddefconfig`
  defaults apply unless you add your own Kconfig tweaks.
- `-march` support depends on your installed GCC/Clang version - a
  brand-new microarch name may need a newer compiler than what ships in
  Debian 13's repos.
- Building a kernel needs real time and disk (expect 20-60+ minutes and
  15-25GB free, depending on config and hardware).
