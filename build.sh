#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OnePlus Kernel Build Script
# ============================================================
# Usage: ./build.sh [device] [variant]
#   device:  oneplus7pro | oneplus8pro | oneplus10pro
#   variant: user | userdebug | eng (default: user)
# ============================================================

DEVICE="${1:-oneplus7pro}"
VARIANT="${2:-user}"

# --- Configuration -----------------------------------------------------------
ANYKERNEL_DIR="${ANYKERNEL_DIR:-AnyKernel3}"
THREADS="${THREADS:-$(nproc)}"

# Toolchain: expects clang in PATH or set CLANG_PATH
CLANG_PATH="${CLANG_PATH:-clang}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"

# Docker/Swarm/NFS config fragment
EXTRA_CONFIG="$(pwd)/docker-swarm-nfs.config"

# --- Device defconfigs -------------------------------------------------------
# shellcheck source=scripts/kernel-devices.sh
source "$(dirname "$0")/scripts/kernel-devices.sh"

# Maps device -> defconfig(s)
declare -A DEFCONFIGS=(
    [oneplus7pro]="vendor/sm8150-perf_defconfig vendor/oplus.config"
    [oneplus8pro]="vendor/kona-perf_defconfig vendor/oplus.config"
    [oneplus10pro]="gki_defconfig vendor/waipio_GKI.config"
)

KERNEL_DIR="${KERNEL_DIRS[$DEVICE]:-}"
DEFCONFIG="${DEFCONFIGS[$DEVICE]:-}"

if [[ -z "$DEFCONFIG" ]]; then
    echo "Error: Unknown device '$DEVICE'"
    echo "Supported devices: ${!DEFCONFIGS[*]}"
    exit 1
fi

if [[ ! -d "$KERNEL_DIR" ]]; then
    echo "Error: Kernel source not found at $KERNEL_DIR"
    echo "Run: ./setup.sh $DEVICE"
    exit 1
fi

OUT_DIR="${OUT_DIR:-out/$DEVICE}"

# --- Build -------------------------------------------------------------------
echo "==> Building kernel for $DEVICE ($VARIANT)"
echo "    Source:    $KERNEL_DIR"
echo "    Defconfig: $DEFCONFIG"
echo "    Output:    $OUT_DIR"
echo "    Threads:   $THREADS"
echo ""

export ARCH=arm64
export SUBARCH=arm64
export PATH="$(dirname "$CLANG_PATH"):$PATH"

mkdir -p "$OUT_DIR"

# Generate base defconfig
make -C "$KERNEL_DIR" O="$(pwd)/$OUT_DIR" \
    ARCH=arm64 \
    CC=clang \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    LLVM=1 \
    $DEFCONFIG

# Merge Docker/Swarm/NFS config fragment
if [[ -f "$EXTRA_CONFIG" ]]; then
    echo "==> Merging docker-swarm-nfs.config..."
    CONFIGS_TO_MERGE="$(pwd)/$OUT_DIR/.config $EXTRA_CONFIG"
    # Merge device-specific fixes if they exist
    DEVICE_FIXES="$(pwd)/${DEVICE}-fixes.config"
    if [[ -f "$DEVICE_FIXES" ]]; then
        CONFIGS_TO_MERGE="$CONFIGS_TO_MERGE $DEVICE_FIXES"
    fi
    "$KERNEL_DIR/scripts/kconfig/merge_config.sh" \
        -m -O "$(pwd)/$OUT_DIR" \
        $CONFIGS_TO_MERGE
    # Resolve dependencies after merge
    make -C "$KERNEL_DIR" O="$(pwd)/$OUT_DIR" \
        ARCH=arm64 \
        CC=clang \
        CLANG_TRIPLE=aarch64-linux-gnu- \
        CROSS_COMPILE="$CROSS_COMPILE" \
        CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
        LLVM=1 \
        olddefconfig
fi

# Compile
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
# Some older kernels produce Image.gz-dtb instead
if [[ ! -f "$KERNEL_IMAGE" ]]; then
    KERNEL_IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
fi

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
    echo "Error: Kernel image not found"
    exit 1
fi

echo "==> Done: $DEVICE"
