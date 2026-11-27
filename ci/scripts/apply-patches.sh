#!/usr/bin/env bash
# Apply the vermeer feature stack to a clean LineageOS android_kernel_xiaomi_sm8550 tree.
#
# Usage:
#   bash apply-patches.sh --kernel /path/to/kernel --additions /path/to/additions --workspace /path/to/workspace
#
# The script is idempotent for the integration steps (symlinks / Makefile lines)
# but patch application itself expects a fresh checkout.
set -euo pipefail

KERNEL_ROOT=""
ADDITIONS=""
WORKSPACE=""
APPLY_PERFORMANCE="${APPLY_PERFORMANCE:-yes}"
case "$APPLY_PERFORMANCE" in
  true|TRUE|True|yes|YES|Yes|1) APPLY_PERFORMANCE=yes ;;
  *) APPLY_PERFORMANCE=no ;;
esac

# Upstream pins used by the proven 5.15 recipes.
KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"
KSU_COMMIT="${KSU_COMMIT:-3660779ea2e2fe1adb27616d8aad9ffaad717501}"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="gki-android13-5.15"
SUSFS_COMMIT="${SUSFS_COMMIT:-c1d1da42b74771944207ec45aaceff9c57e84985}"
NOMOUNT_REPO="https://github.com/maxsteeel/nomount.git"
NOMOUNT_COMMIT="${NOMOUNT_COMMIT:-c803cbf0ad2c2dce695cece50259c16d0a84361c}"
BBG_REPO="https://github.com/vc-teahouse/Baseband-guard.git"
BBG_COMMIT="${BBG_COMMIT:-48d9fdea643bcb41d204541400e9d8656b97a54f}"

log()  { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

retry() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    [ "$n" -ge 5 ] && return 1
    warn "retry $n/5: $*"
    sleep 5
  done
}

# Idempotently add a `source "..."` line before the last endmenu of a Kconfig.
source_before_last_endmenu() {
  local file="$1" line="$2"
  grep -Fq "$line" "$file" && return 0
  if grep -q '^endmenu[[:space:]]*$' "$file"; then
    awk -v src="$line" '{a[NR]=$0} END{last=0; for(i=1;i<=NR;i++) if(a[i] ~ /^endmenu[[:space:]]*$/) last=i;
         for(i=1;i<=NR;i++){ if(i==last) print src; print a[i] }}' \
      "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
  else
    printf '\n%s\n' "$line" >> "$file"
  fi
  grep -Fq "$line" "$file" || die "could not add '$line' to $file"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --kernel)    KERNEL_ROOT="$2"; shift 2 ;;
    --additions) ADDITIONS="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --no-performance) APPLY_PERFORMANCE=no; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$KERNEL_ROOT" ] || KERNEL_ROOT="$(pwd)"
[ -n "$ADDITIONS" ]   || ADDITIONS="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$WORKSPACE" ]   || WORKSPACE="$(dirname "$KERNEL_ROOT")"

KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd)"
ADDITIONS="$(cd "$ADDITIONS" && pwd)"
mkdir -p "$WORKSPACE"

[ -f "$KERNEL_ROOT/Makefile" ] || die "no kernel Makefile at $KERNEL_ROOT"

# Detect and record the kernel sublevel (the patch set is 5.15-specific).
MAJ=$(awk '/^VERSION =/ {print $3; exit}' "$KERNEL_ROOT/Makefile")
MIN=$(awk '/^PATCHLEVEL =/ {print $3; exit}' "$KERNEL_ROOT/Makefile")
SUB=$(awk '/^SUBLEVEL =/ {print $3; exit}' "$KERNEL_ROOT/Makefile")
log "kernel ${MAJ}.${MIN}.${SUB}"
[ "${MAJ}.${MIN}" = "5.15" ] || die "this patch set targets 5.15, got ${MAJ}.${MIN}"
[ "$SUB" -ge 150 ] || warn "sublevel $SUB is older than the recipes were tested against"

# This fork ships stray *.rej files (e.g. under drivers/input/touchscreen/).
# Snapshot them so reject checks only see files created by this run.
BASELINE_REJECTS="$WORKSPACE/baseline-rejects.txt"
CURRENT_REJECTS="$WORKSPACE/current-rejects.txt"
find "$KERNEL_ROOT" -name '*.rej' -type f -print 2>/dev/null | LC_ALL=C sort > "$BASELINE_REJECTS"

new_rejects() {
  find "$KERNEL_ROOT" -name '*.rej' -type f -print 2>/dev/null | LC_ALL=C sort > "$CURRENT_REJECTS"
  LC_ALL=C comm -13 "$BASELINE_REJECTS" "$CURRENT_REJECTS"
}

# ---------------------------------------------------------------------------
# Helper: apply one patch, fail loudly on rejects (or warn for optional ones).
# ---------------------------------------------------------------------------
apply_patch() {
  local label="$1" file="$2" strip="$3" fuzz="$4" required="$5"
  local input="$file"
  [ -f "$file" ] || die "missing patch: $file"

  # Two performance patches need the 5.11-5.15 symbol form used upstream.
  case "$label" in
    perf-memcmp)
      input="$WORKSPACE/${label}.patch"
      sed -e 's/SYM_FUNC_START(__pi_memcmp)/SYM_FUNC_START_WEAK_PI(memcmp)/' \
          -e 's/SYM_FUNC_END(__pi_memcmp)/SYM_FUNC_END_PI(memcmp)/' \
          -e 's/SYM_FUNC_ALIAS_WEAK(memcmp, __pi_memcmp)/EXPORT_SYMBOL_NOKASAN(memcmp)/' \
          "$file" > "$input"
      ;;
    perf-clear-page)
      input="$WORKSPACE/${label}.patch"
      sed -e 's/SYM_FUNC_START_PI(clear_page)/SYM_FUNC_START_PI(__pi_clear_page)/' \
          "$file" > "$input"
      ;;
  esac

  log "patch: $label ($(basename "$input"))"
  if ! patch -d "$KERNEL_ROOT" -p"$strip" --forward --fuzz="$fuzz" -i "$input"; then
    if [ "$required" = yes ]; then
      die "required patch failed: $label"
    fi
    warn "optional patch failed, skipping: $label"
  fi

  local rejects
  rejects="$(new_rejects)"
  if [ -n "$rejects" ]; then
    printf '%s\n' "$rejects" >&2
    while IFS= read -r rej; do
      rm -f "$rej" "${rej%.rej}.orig"
    done <<< "$rejects"
    if [ "$required" = yes ]; then
      die "required patch left rejects: $label"
    fi
    warn "optional patch left rejects, skipping: $label"
  fi
}

# ---------------------------------------------------------------------------
# 1. Vendored 5.15 patches (manifest).
# ---------------------------------------------------------------------------
MANIFEST="$ADDITIONS/patches/manifest.tsv"
[ -f "$MANIFEST" ] || die "missing $MANIFEST"

while IFS=$'\t' read -r name rel strip fuzz required note; do
  case "${name:-}" in ''|\#*) continue ;; esac
  [ -z "${rel:-}" ] && continue
  if [ "$APPLY_PERFORMANCE" != yes ] && [ "${required:-}" = no ]; then
    warn "skipping optional patch $name (APPLY_PERFORMANCE=$APPLY_PERFORMANCE)"
    continue
  fi
  apply_patch "$name" "$ADDITIONS/patches/$rel" "${strip:-1}" "${fuzz:-3}" "${required:-yes}"
done < "$MANIFEST"

# ---------------------------------------------------------------------------
# 2. KernelSU-Next.
# ---------------------------------------------------------------------------
clone_pinned() {
  local repo="$1" commit="$2" dir="$3" branch_hint="${4:-}"
  if [ -d "$dir/.git" ]; then
    log "reusing $(basename "$dir") checkout"
  else
    rm -rf "$dir"
    log "cloning $repo -> $dir"
    retry git clone --no-checkout "$repo" "$dir"
  fi
  # Always checkout: a --no-checkout clone has an empty worktree even when
  # HEAD already happens to equal the requested commit.
  retry git -C "$dir" fetch --depth=1 origin "$commit" || \
    retry git -C "$dir" fetch --depth=1 origin "$branch_hint"
  git -C "$dir" checkout --detach "$commit"
  [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "pin mismatch in $dir"
}

KSU_DIR="$WORKSPACE/KernelSU-Next"
clone_pinned "$KSU_REPO" "$KSU_COMMIT" "$KSU_DIR" dev

[ -f "$KSU_DIR/kernel/Kconfig" ] && [ -f "$KSU_DIR/kernel/Makefile" ] || \
  die "KernelSU-Next checkout has no kernel/ integration"
ln -sfn "$(realpath --relative-to="$KERNEL_ROOT/drivers" "$KSU_DIR/kernel")" "$KERNEL_ROOT/drivers/kernelsu"
grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_ROOT/drivers/Makefile" || \
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_ROOT/drivers/Makefile"
source_before_last_endmenu "$KERNEL_ROOT/drivers/Kconfig" 'source "drivers/kernelsu/Kconfig"'
# build.sh's mrproper phase has no .config; demote the guard to a warning.
if grep -q 'KernelSU requires either CONFIG_KPROBES' "$KSU_DIR/kernel/Kbuild"; then
  sed -i 's/$(error "KernelSU requires either CONFIG_KPROBES=y or CONFIG_KSU_SUSFS=y")/$(warning "KernelSU requires either CONFIG_KPROBES=y or CONFIG_KSU_SUSFS=y")/' \
    "$KSU_DIR/kernel/Kbuild"
fi

# ---------------------------------------------------------------------------
# 3. SUSFS4KSU (kernel side) + 5.15 compatibility helpers.
# ---------------------------------------------------------------------------
SUSFS_DIR="$WORKSPACE/susfs4ksu"
clone_pinned "$SUSFS_REPO" "$SUSFS_COMMIT" "$SUSFS_DIR" "$SUSFS_BRANCH"

cp -a "$SUSFS_DIR/kernel_patches/fs/." "$KERNEL_ROOT/fs/"
cp -a "$SUSFS_DIR/kernel_patches/include/linux/." "$KERNEL_ROOT/include/linux/"
SUSFS_PATCH="$SUSFS_DIR/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
[ -f "$SUSFS_PATCH" ] || die "missing SUSFS patch $SUSFS_PATCH"
cp "$SUSFS_PATCH" "$WORKSPACE/susfs-base.patch"
apply_patch "susfs-base" "$WORKSPACE/susfs-base.patch" 1 3 yes

for helper in susfs_idmap_compat.py susfs_guard_priority_helpers.py; do
  [ -f "$ADDITIONS/scripts/compat/$helper" ] || die "missing compat helper $helper"
  python3 "$ADDITIONS/scripts/compat/$helper" "$KERNEL_ROOT/fs/susfs.c"
done

# ---------------------------------------------------------------------------
# 4. NoMount.
# ---------------------------------------------------------------------------
NOMOUNT_DIR="$WORKSPACE/NoMount"
clone_pinned "$NOMOUNT_REPO" "$NOMOUNT_COMMIT" "$NOMOUNT_DIR" dev
[ -d "$NOMOUNT_DIR/kernel/src" ] || die "NoMount checkout has no kernel/src"
ln -sfn "$(realpath --relative-to="$KERNEL_ROOT/fs" "$NOMOUNT_DIR/kernel/src")" "$KERNEL_ROOT/fs/nomount"
grep -q 'obj-$(CONFIG_NOMOUNT) += nomount/' "$KERNEL_ROOT/fs/Makefile" || \
  printf '\nobj-$(CONFIG_NOMOUNT) += nomount/\n' >> "$KERNEL_ROOT/fs/Makefile"
source_before_last_endmenu "$KERNEL_ROOT/fs/Kconfig" 'source "fs/nomount/Kconfig"'

# ---------------------------------------------------------------------------
# 5. Baseband Guard (BBG) LSM.
# ---------------------------------------------------------------------------
BBG_DIR="$WORKSPACE/Baseband-guard"
clone_pinned "$BBG_REPO" "$BBG_COMMIT" "$BBG_DIR" main
ln -sfn "$(realpath --relative-to="$KERNEL_ROOT/security" "$BBG_DIR")" "$KERNEL_ROOT/security/baseband-guard"
grep -q 'obj-$(CONFIG_BBG) += baseband-guard/' "$KERNEL_ROOT/security/Makefile" || \
  printf '\nobj-$(CONFIG_BBG) += baseband-guard/\n' >> "$KERNEL_ROOT/security/Makefile"
source_before_last_endmenu "$KERNEL_ROOT/security/Kconfig" 'source "security/baseband-guard/Kconfig"'
# Add baseband_guard to the built-in LSM list if the default is still stock.
if grep -q '^config LSM$' "$KERNEL_ROOT/security/Kconfig" && \
   ! grep -q 'default "landlock,yama,selinux,baseband_guard' "$KERNEL_ROOT/security/Kconfig"; then
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' \
    "$KERNEL_ROOT/security/Kconfig"
fi

# ---------------------------------------------------------------------------
# 6. Optional config additions and final reject scan.
# ---------------------------------------------------------------------------
: > "$WORKSPACE/fuse-bpf.fragment"
if grep -qs '^config FUSE_BPF' "$KERNEL_ROOT/fs/fuse/Kconfig"; then
  echo 'CONFIG_FUSE_BPF=y' > "$WORKSPACE/fuse-bpf.fragment"
  log "CONFIG_FUSE_BPF is declared; enabling it"
else
  warn "CONFIG_FUSE_BPF is not declared in this tree; skipping"
fi

REJECTS="$(new_rejects)"
[ -z "$REJECTS" ] || { printf '%s\n' "$REJECTS" >&2; die "patch rejects remain in the kernel tree"; }

log "feature stack applied to $KERNEL_ROOT"
