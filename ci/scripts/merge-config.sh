#!/usr/bin/env bash
# Build .config: gki_defconfig + vermeer vendor fragment + feature fragments.
set -euo pipefail

KERNEL_ROOT=""
OUT_DIR=""
ADDITIONS=""
WORKSPACE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --kernel) KERNEL_ROOT="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --additions) ADDITIONS="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd)"
ADDITIONS="$(cd "$ADDITIONS" && pwd)"
[ -n "$WORKSPACE" ] || WORKSPACE="$(dirname "$KERNEL_ROOT")"
[ -n "$OUT_DIR" ] || OUT_DIR="$WORKSPACE/out"
mkdir -p "$OUT_DIR"

VENDOR_CONFIG="$KERNEL_ROOT/arch/arm64/configs/vendor/vermeer_GKI.config"
[ -f "$VENDOR_CONFIG" ] || { echo "missing $VENDOR_CONFIG" >&2; exit 1; }

MAKE_ARGS=( -C "$KERNEL_ROOT" O="$OUT_DIR" ARCH=arm64 LLVM=1 CC=clang )

echo "[*] generating gki_defconfig"
make "${MAKE_ARGS[@]}" gki_defconfig

FRAGMENTS=(
  "$VENDOR_CONFIG"
  "$ADDITIONS/config/features.fragment"
  "$ADDITIONS/config/networking.fragment"
  "$ADDITIONS/config/cifs.fragment"
  "$ADDITIONS/config/droidspaces.fragment"
)
if [ -s "$WORKSPACE/fuse-bpf.fragment" ]; then
  FRAGMENTS+=( "$WORKSPACE/fuse-bpf.fragment" )
fi

echo "[*] merging fragments"
KCONFIG_CONFIG="$OUT_DIR/.config" \
  "$KERNEL_ROOT/scripts/kconfig/merge_config.sh" -m -r -y "${FRAGMENTS[@]}"

echo "[*] resolving dependencies with olddefconfig"
make "${MAKE_ARGS[@]}" olddefconfig

echo "[*] key config checks"
for opt in CONFIG_KSU=y CONFIG_KSU_SUSFS=y CONFIG_BBG=y CONFIG_NOMOUNT=y \
           CONFIG_TCP_CONG_BBR3=y CONFIG_NTSYNC=y CONFIG_WIREGUARD=y \
           CONFIG_CIFS=y CONFIG_TMPFS_XATTR=y CONFIG_DEBUG_INFO_BTF=y; do
  grep -qx "$opt" "$OUT_DIR/.config" || { echo "missing $opt in .config" >&2; exit 1; }
done
echo "[+] .config ready at $OUT_DIR/.config"
