#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OnePlus Kernel Build Script
# ============================================================
# Usage: ./build.sh [device] [variant]
#   device:  oneplus12 | oneplus13 | ace3pro | ...
#   variant: user | userdebug | eng (default: user)
# ============================================================

DEVICE="${1:-oneplus12}"
VARIANT="${2:-user}"

# --- Configuration -----------------------------------------------------------
# Override these via environment or edit below for your setup.
KERNEL_DIR="${KERNEL_DIR:-kernel/source}"
OUT_DIR="${OUT_DIR:-out}"
ANYKERNEL_DIR="${ANYKERNEL_DIR:-AnyKernel3}"
THREADS="${THREADS:-$(nproc)}"

# Toolchain: expects clang in PATH or set CLANG_PATH
CLANG_PATH="${CLANG_PATH:-clang}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"

# --- Device defconfigs -------------------------------------------------------
declare -A DEFCONFIGS=(
    [oneplus12]="gki_defconfig vendor/pineapple_GKI.config vendor/oplus/oneplus12.config"
    [oneplus13]="gki_defconfig vendor/sun_GKI.config vendor/oplus/oneplus13.config"
    [ace3pro]="gki_defconfig vendor/pineapple_GKI.config vendor/oplus/ace3pro.config"
)

DEFCONFIG="${DEFCONFIGS[$DEVICE]:-}"
if [[ -z "$DEFCONFIG" ]]; then
    echo "Error: Unknown device '$DEVICE'"
    echo "Supported devices: ${!DEFCONFIGS[*]}"
    exit 1
fi

# --- Build -------------------------------------------------------------------
echo "==> Building kernel for $DEVICE ($VARIANT)"
echo "    Defconfig: $DEFCONFIG"
echo "    Threads:   $THREADS"
echo ""

export ARCH=arm64
export SUBARCH=arm64
export PATH="$(dirname "$CLANG_PATH"):$PATH"

mkdir -p "$OUT_DIR"

make -C "$KERNEL_DIR" O="$(pwd)/$OUT_DIR" \
    ARCH=arm64 \
    CC=clang \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    LLVM=1 \
    $DEFCONFIG

make -C "$KERNEL_DIR" O="$(pwd)/$OUT_DIR" \
    ARCH=arm64 \
    CC=clang \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    LLVM=1 \
    -j"$THREADS"

# --- Package -----------------------------------------------------------------
KERNEL_IMAGE="$OUT_DIR/arch/arm64/boot/Image"
if [[ -f "$KERNEL_IMAGE" ]]; then
    echo "==> Kernel image built: $KERNEL_IMAGE"
    if [[ -d "$ANYKERNEL_DIR" ]]; then
        cp "$KERNEL_IMAGE" "$ANYKERNEL_DIR/"
        cd "$ANYKERNEL_DIR"
        zip -r9 "../${DEVICE}-kernel-$(date +%Y%m%d).zip" . -x '*.git*'
        cd ..
        echo "==> Flashable zip: ${DEVICE}-kernel-$(date +%Y%m%d).zip"
    else
        echo "    (AnyKernel3 not found — skipping zip packaging)"
    fi
else
    echo "Error: Kernel image not found at $KERNEL_IMAGE"
    exit 1
fi

echo "==> Done."
