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

# Docker/Swarm/NFS config fragment. Set SKIP_FRAGMENT=1 to build pure stock
# (used for bisecting which option breaks boot).
EXTRA_CONFIG="${EXTRA_CONFIG:-$(pwd)/docker-swarm-nfs.config}"
if [[ "${SKIP_FRAGMENT:-0}" == "1" ]]; then
    EXTRA_CONFIG=""
fi

# --- Device defconfigs -------------------------------------------------------
# shellcheck source=scripts/kernel-devices.sh
source "$(dirname "$0")/scripts/kernel-devices.sh"

# Maps device -> defconfig(s)
declare -A DEFCONFIGS=(
    [oneplus7pro]="vendor/sm8150-perf_defconfig vendor/oplus.config"
    [oneplus8pro]="vendor/kona-perf_defconfig vendor/oplus.config"
    [oneplus10pro]="gki_defconfig vendor/waipio_GKI.config vendor/oplus_GKI.config"
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

# LLVM_IAS=1 required for GKI kernels (LTO/CFI). Also required on OP7/OP8 when
# the build environment lacks aarch64-linux-gnu-as binutils (e.g. fresh
# devcontainer): without it, clang invokes /usr/bin/as which doesn't
# understand arm64 assembler flags. The original "breaks DTS on older kernels"
# concern doesn't seem to apply with current clang — leave it on for all.
LLVM_IAS_FLAG="LLVM_IAS=1"

mkdir -p "$OUT_DIR"

# Generate base defconfig
make -C "$KERNEL_DIR" O="$(pwd)/$OUT_DIR" \
    ARCH=arm64 \
    CC=clang \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    LLVM=1 $LLVM_IAS_FLAG \
    $DEFCONFIG

# Merge Docker/Swarm/NFS config fragment
if [[ -f "$EXTRA_CONFIG" ]]; then
    echo "==> Merging $(basename "$EXTRA_CONFIG")..."
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
        LLVM=1 $LLVM_IAS_FLAG \
        olddefconfig
fi

# Compile
# Build Image + modules. Modules must be rebuilt in lockstep with Image because
# CONFIG_MODVERSIONS=y embeds per-symbol CRCs in each .ko, and any kernel change
# that perturbs symbol CRCs (sched/cgroup backports, etc.) breaks insmod with
# "disagrees about version of symbol" — notably qca_cld3_wlan.ko, which is the
# OnePlus WiFi driver shipped in /vendor/lib/modules.
# Skip DTS/DTBO targets which fail for unused device variants.
make -C "$KERNEL_DIR" O="$(pwd)/$OUT_DIR" \
    ARCH=arm64 \
    CC=clang \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    LLVM=1 $LLVM_IAS_FLAG \
    -j"$THREADS" Image modules

# --- Package -----------------------------------------------------------------
KERNEL_IMAGE="$OUT_DIR/arch/arm64/boot/Image"
# Some older kernels produce Image.gz-dtb instead
if [[ ! -f "$KERNEL_IMAGE" ]]; then
    KERNEL_IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
fi

if [[ ! -f "$KERNEL_IMAGE" ]]; then
    echo "Error: Kernel image not found"
    exit 1
fi

echo "==> Kernel image built: $KERNEL_IMAGE"

# AnyKernel3 zip (non-GKI devices)
if [[ -d "$ANYKERNEL_DIR" ]]; then
    cp "$KERNEL_IMAGE" "$ANYKERNEL_DIR/"
    cd "$ANYKERNEL_DIR"
    zip -r9 "../${DEVICE}-kernel-$(date +%Y%m%d).zip" . -x '*.git*'
    cd ..
    echo "==> Flashable zip: ${DEVICE}-kernel-$(date +%Y%m%d).zip"
fi

# boot.img creation — unpack stock boot, replace kernel, repack
CODENAME=$(awk -F'|' -v dev="$DEVICE" '$1 == dev { print $3 }' scripts/devices.conf)
STOCK_BOOT="lineageos/${CODENAME}/boot.img"
MKBOOTIMG="tools/mkbootimg-aosp/mkbootimg.py"

if [[ -f "$MKBOOTIMG" && -f "$STOCK_BOOT" ]]; then
    UNPACK_DIR="/tmp/boot-${DEVICE}-$$"
    UNPACK_OUT=$(python3 tools/mkbootimg-aosp/unpack_bootimg.py \
        --boot_img "$STOCK_BOOT" --out "$UNPACK_DIR" 2>&1)
    HEADER_VER=$(echo "$UNPACK_OUT" | grep 'boot image header version' | awk '{print $NF}')
    OS_VER=$(echo "$UNPACK_OUT" | grep '^os version' | awk '{print $NF}')
    OS_PATCH=$(echo "$UNPACK_OUT" | grep '^os patch level' | awk '{print $NF}')
    CMDLINE=$(echo "$UNPACK_OUT" | grep '^command line args' | sed 's/^command line args: //')

    if [[ "$HEADER_VER" == "4" ]]; then
        echo "==> Creating boot.img (header v4 / GKI)..."
        python3 "$MKBOOTIMG" \
            --kernel "$KERNEL_IMAGE" \
            --ramdisk "$UNPACK_DIR/ramdisk" \
            --header_version 4 \
            --os_version "$OS_VER" \
            --os_patch_level "$OS_PATCH" \
            --output "out/${DEVICE}-boot.img"
    elif [[ "$HEADER_VER" == "2" ]]; then
        echo "==> Creating boot.img (header v2)..."
        python3 "$MKBOOTIMG" \
            --kernel "$KERNEL_IMAGE" \
            --ramdisk "$UNPACK_DIR/ramdisk" \
            --dtb "$UNPACK_DIR/dtb" \
            --header_version 2 --pagesize 4096 --base 0x0 \
            --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
            --tags_offset 0x100 --dtb_offset 0x1f00000 \
            --cmdline "$CMDLINE" \
            --os_version "$OS_VER" \
            --os_patch_level "$OS_PATCH" \
            --output "out/${DEVICE}-boot.img"
    fi

    if [[ -f "out/${DEVICE}-boot.img" ]]; then
        echo "==> Boot image: out/${DEVICE}-boot.img"
    fi
    rm -rf "$UNPACK_DIR"
fi

echo "==> Done: $DEVICE"
