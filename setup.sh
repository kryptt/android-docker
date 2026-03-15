#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Setup script: clone kernel source and toolchains
# ============================================================

echo "==> Setting up OnePlus kernel development environment"

# --- Kernel source -----------------------------------------------------------
# Replace with the appropriate OnePlus kernel repo for your device/SoC.
# Common OnePlus open-source kernel repos:
#   SM8650 (Snapdragon 8 Gen 3) — OnePlus 12, Ace 3 Pro
#   SM8750 (Snapdragon 8 Elite) — OnePlus 13
KERNEL_REPO="${KERNEL_REPO:-https://github.com/OnePlusOSS/android_kernel_oneplus_sm8650}"
KERNEL_BRANCH="${KERNEL_BRANCH:-oneplus/sm8650_u_14.0.0_oneplus12}"

if [[ ! -d kernel/source ]]; then
    echo "==> Cloning kernel source..."
    git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" kernel/source
else
    echo "    kernel/source already exists, skipping."
fi

# --- Clang toolchain ---------------------------------------------------------
CLANG_URL="${CLANG_URL:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}"
CLANG_BRANCH="${CLANG_BRANCH:-main}"

if [[ ! -d clang ]]; then
    echo "==> Cloning clang toolchain (this may take a while)..."
    git clone --depth=1 -b "$CLANG_BRANCH" "$CLANG_URL" clang
else
    echo "    clang/ already exists, skipping."
fi

# --- AnyKernel3 (for flashable zip packaging) --------------------------------
if [[ ! -d AnyKernel3 ]]; then
    echo "==> Cloning AnyKernel3..."
    git clone --depth=1 https://github.com/osm0sis/AnyKernel3
else
    echo "    AnyKernel3/ already exists, skipping."
fi

echo ""
echo "==> Setup complete."
echo "    Next steps:"
echo "    1. Review/edit build.sh for your device's defconfig"
echo "    2. Run: ./docker-build.sh <device>"
echo "       or:  ./build.sh <device>"
