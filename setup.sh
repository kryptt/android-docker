#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Setup script: clone kernel sources and toolchains
# ============================================================
# Usage: ./setup.sh [device|all]
#   device: oneplus7pro | oneplus8pro | oneplus10pro | all (default: all)
# ============================================================

DEVICE="${1:-all}"

echo "==> Setting up OnePlus kernel development environment"

# --- Kernel sources per device/SoC -------------------------------------------
declare -A KERNEL_REPOS=(
    [oneplus7pro]="https://github.com/LineageOS/android_kernel_oneplus_sm8150"
    [oneplus8pro]="https://github.com/LineageOS/android_kernel_oneplus_sm8250"
    [oneplus10pro]="https://github.com/pjgowtham/android_kernel_oneplus_sm8450"
)

declare -A KERNEL_BRANCHES=(
    [oneplus7pro]="lineage-23.2"
    [oneplus8pro]="lineage-23.2"
    [oneplus10pro]="lineage-23.0"
)

# shellcheck source=scripts/kernel-devices.sh
source "$(dirname "$0")/scripts/kernel-devices.sh"

clone_kernel() {
    local device="$1"
    local repo="${KERNEL_REPOS[$device]}"
    local branch="${KERNEL_BRANCHES[$device]}"
    local dir="${KERNEL_DIRS[$device]}"

    if [[ ! -d "$dir" ]]; then
        echo "==> Cloning kernel source for $device ($branch)..."
        git clone --depth=1 -b "$branch" "$repo" "$dir"
    else
        echo "    $dir already exists, skipping."
    fi
}

if [[ "$DEVICE" == "all" ]]; then
    DEVICES=("oneplus7pro" "oneplus8pro" "oneplus10pro")
else
    DEVICES=("$DEVICE")
fi

for dev in "${DEVICES[@]}"; do
    if [[ -z "${KERNEL_REPOS[$dev]:-}" ]]; then
        echo "Error: Unknown device '$dev'"
        echo "Supported devices: ${!KERNEL_REPOS[*]}"
        exit 1
    fi
    clone_kernel "$dev"
done

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
echo "    1. Run: ./build.sh <device>"
echo "       Devices: oneplus7pro, oneplus8pro, oneplus10pro"
