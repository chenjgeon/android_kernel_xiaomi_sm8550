# Vermeer kernel feature stack (CI recipe)

This directory is a drop-in addition for `chenjgeon/android_kernel_xiaomi_sm8550`
(`lineage-24.0`, Linux 5.15.223, Poco F6 Pro / vermeer). It does **not** modify
kernel source in place locally; a GitHub Actions workflow applies everything on
a fresh checkout and publishes an AnyKernel3 ZIP.

## What is included

| Group | Implementation |
|---|---|
| KernelSU-Next | `KernelSU-Next/KernelSU-Next` @ `3660779e` (dev tip tracked by the upstream 5.15 recipe), linked into `drivers/kernelsu` |
| SUSFS4KSU | `simonpunk/susfs4ksu` @ `c1d1da42` on `gki-android13-5.15`; 5.15 `i_user_ns` compat + credential-helper guard. `sus_map` comes from KernelSU-Next's built-in `kernel/susfs/sus_map.c`, so the standalone `xx_maps_sus_kernel.patch` is intentionally not applied. |
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
- `ci/` → `ci/` (patches, config fragments, scripts, AnyKernel3 template)

Then commit and push to `lineage-24.0`:

```bash
git add .github/workflows/build-kernel.yml ci
git commit -m "CI: build vermeer GKI kernel with KernelSU-Next/SUSFS feature stack"
git push origin lineage-24.0
```

Trigger the workflow from the Actions tab ("Run workflow"), or push a `v*` tag.

## What the workflow does

1. Checks out the fork.
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
- No local kernel build was performed while preparing these files (Windows host, no Linux build environment). Validate the first CI run carefully.

## Updating pins

Edit the defaults at the top of `ci/scripts/apply-patches.sh`, or override via repository variables/environment:
`KSU_COMMIT`, `SUSFS_COMMIT`, `NOMOUNT_COMMIT`, `BBG_COMMIT`.
