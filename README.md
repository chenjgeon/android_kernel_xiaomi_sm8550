# Vermeer kernel feature stack (CI recipe)

This directory is a drop-in addition for `chenjgeon/android_kernel_xiaomi_sm8550`
(`lineage-24.0`, Linux 5.15.223, Poco F6 Pro / vermeer). It does **not** modify
kernel source in place locally; a GitHub Actions workflow applies everything on
a fresh checkout and publishes an AnyKernel3 ZIP.

## What is included

| Group | Implementation |
|---|---|
| KernelSU-Next | `pershoot/KernelSU-Next` `dev-susfs` @ `e726c598` — the SUSFS-capable fork used by WildKernels; linked into `drivers/kernelsu` |
| SUSFS4KSU | `simonpunk/susfs4ksu` @ `c1d1da42b74771944207ec45aaceff9c57e84985` on `gki-android13-5.15` + pershoot's two `fs/susfs.c` fixes; 5.15 `i_user_ns`/credential-helper/fanotify compat. Declares `CONFIG_KSU_SUSFS*` and builds `SUSFS_VERSION v2.4.0`. The standalone `xx_maps_sus_kernel.patch` is intentionally not applied. |
| NoMount | `maxsteeel/nomount` @ `c803cbf0`; `fs/nomount` symlink + `CONFIG_NOMOUNT=y` |
| Mountify | userspace companion (not kernel-side; install the module on device) |
| Baseband Guard | `vc-teahouse/Baseband-guard` @ `48d9fde`; LSM enabled with `baseband_guard` in `CONFIG_LSM` |
| Networking | ipset, netfilter helpers/REJECT, WireGuard, FQ/FQ-CoDel/CAKE |
| BBRv3 | 5.15 backport patch + `CONFIG_TCP_CONG_BBR3=y` |
| TMPFS | `CONFIG_TMPFS_XATTR` + POSIX ACLs |
| BPF / eBPF / FUSE-BPF | `CONFIG_DEBUG_INFO_BTF`, BPF events, `CONFIG_FUSE_BPF` when declared, pahole 1.31 |
| NTSync | 5.15 compat patch + `ntsync_base.patch` + `CONFIG_NTSYNC=y` |
| Performance | optional 5.15-adapted upstream performance patch set |
| DroidSpaces | kABI fix + USER_NS guard + ghost-task patch + namespace/overlay/xattr configs |
| Hardening | `gki_ptrace.patch` and `unicode_bypass_fix_6.1-.patch` for < 5.16 / < 6.1 |

## How to install into your fork

Copy the contents of this directory into the **root of your kernel fork**:

- `.github/workflows/build-kernel.yml` → `.github/workflows/build-kernel.yml`
- `.github/workflows/check-susfs-updates.yml` → `.github/workflows/check-susfs-updates.yml`
- `ci/` → `ci/` (patches, config fragments, scripts, AnyKernel3 template)

Then commit and push to `lineage-24.0`:

```bash
git add .github/workflows ci
git commit -m "CI: build vermeer kernel and check SUSFS updates"
git push origin lineage-24.0
```

Trigger the workflow from the Actions tab ("Run workflow"), or push a `v*` tag.

## What the workflow does

1. Checks out the fork and reports whether a newer SUSFS commit exists.
2. Installs build deps + GNU AArch64/ARM32 binutils.
3. Downloads AOSP Clang **r450784e** (the version pinned in `build.config.constants`) and builds pahole 1.31 for BTF.
4. Applies vendored 5.15 patches (required) and optional performance patches, then integrates KernelSU-Next, SUSFS, NoMount and BBG at pinned commits.
5. Creates `.config` from `gki_defconfig` + `arch/arm64/configs/vendor/vermeer_GKI.config` + `ci/config/*.fragment`.
6. Builds `Image.gz`, modules and DTBs with Clang 14.
7. Packages an AnyKernel3 ZIP (boot kernel only) plus raw artifacts into a GitHub Release.

## Important caveats

- The patch recipes come from `WildKernels/kernel_patches` / `GKI_KernelSU_SUSFS`. Upstream's 5.15 matrix stops before sublevel **223**, so context drift is possible. Required patches are applied with `--fuzz=3` and fail the job on rejects; fix the affected patch or adjust the manifest line if that happens.
- The AnyKernel3 script intentionally patches **boot only**. Keep vendor_boot (DTBs/modules/ramdisk) from your ROM. Verify offsets on-device before flashing.
- `CONFIG_LSM` changes and GKI KMI symbol changes may break vendor module loading on some ROMs. Test on a disposable slot with a backup.
- The SUSFS-enabled build was verified in CI (`vermeer-10`): `CONFIG_KSU_SUSFS=y`, 131 `susfs_*` symbols in `System.map`, and `SUSFS_VERSION: v2.4.0` in the build log. On-device boot/root/SUSFS behaviour was subsequently verified by the device owner on xiaomi.eu; still back up your boot slot before flashing.
- No local kernel build was performed while preparing these files (Windows host, no Linux build environment). Validate each CI run carefully.

## SUSFS update checker

`ci/scripts/check-susfs-update.sh` compares the SUSFS pin in
`ci/scripts/apply-patches.sh` against the GitLab API for the configured branch
(`gki-android13-5.15`) and reports:

- pinned commit and latest commit
- SUSFS version string from `kernel_patches/include/linux/susfs.h`
- commit title/date/URL
- `update_available=true|false`

Usage:

```bash
bash ci/scripts/check-susfs-update.sh \
  --pin-file ci/scripts/apply-patches.sh \
  --doc-file README.md \
  --json susfs-update.json
```

Add `--update` to rewrite the pin (and matching SHA in `--doc-file`) when a newer
commit exists. Add `--fail-on-update` to exit with status `2` for gating.

Two workflows use it:

- `.github/workflows/build-kernel.yml` runs it on every build and uploads
  `susfs-update.json`. A newer commit produces a `::warning::` annotation but
  does not fail the build.
- `.github/workflows/check-susfs-updates.yml` runs daily. When an update is
  available it opens/refreshes an issue and a pin-bump pull request. Manual
  dispatch also offers **Dispatch build with latest SUSFS**, which calls
  `build-kernel.yml` with `susfs_commit=<latest>` without merging the PR.

`build-kernel.yml` also accepts a `susfs_commit` workflow_dispatch input, so you
can test any SUSFS commit immediately without editing the repository pin.

## Updating pins

Edit the defaults at the top of `ci/scripts/apply-patches.sh`, or override via
repository variables/environment / workflow inputs:
`KSU_COMMIT`, `SUSFS_COMMIT`, `NOMOUNT_COMMIT`, `BBG_COMMIT`.
