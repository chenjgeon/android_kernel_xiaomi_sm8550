#!/usr/bin/env bash
# Build Image.gz + modules + dtbs with AOSP Clang 14 and GNU binutils.
set -euo pipefail

KERNEL_ROOT=""
OUT_DIR=""
JOBS="$(nproc)"

while [ $# -gt 0 ]; do
  case "$1" in
    --kernel) KERNEL_ROOT="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

KERNEL_ROOT="$(cd "$KERNEL_ROOT" && pwd)"
[ -n "$OUT_DIR" ] || OUT_DIR="$KERNEL_ROOT/../out"
mkdir -p "$OUT_DIR"

: "${CLANG_BIN:?set CLANG_BIN to the AOSP clang bin directory}"
: "${BINUTILS_BIN:?set BINUTILS_BIN to the binutils bin directory}"
export PATH="$CLANG_BIN:$BINUTILS_BIN:$PATH"

echo "[*] building kernel with $(clang --version | head -n1)"
make -C "$KERNEL_ROOT" O="$OUT_DIR" \
  ARCH=arm64 \
  LLVM=1 LLVM_IAS=1 \
  CC=clang CXX=clang++ \
  AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabihf- \
  KCFLAGS="-D__ANDROID_COMMON_KERNEL__" \
  -j"$JOBS" \
  Image.gz modules dtbs

echo "[+] artifacts in $OUT_DIR/arch/arm64/boot"
