#!/usr/bin/env bash
set -euo pipefail

echo "==> Post-create setup for OnePlus kernel dev container"

# Configure git inside container
git config --global --add safe.directory /workspaces/android-docker
git config --global init.defaultBranch main

# Setup ccache
ccache -M 50G 2>/dev/null || true

# Verify USB access
echo ""
echo "==> USB device check:"
if lsusb &>/dev/null; then
    echo "    USB bus accessible."
    # Check for Android devices
    if lsusb | grep -qi "oneplus\|oppo\|google\|qualcomm"; then
        echo "    Android device detected on USB!"
    else
        echo "    No Android device currently connected (plug in to use adb/fastboot)."
    fi
else
    echo "    WARNING: Cannot access USB bus. Check container privileges."
fi

# Verify adb/fastboot
echo ""
echo "==> Tool versions:"
echo "    adb:      $(adb --version 2>/dev/null | head -1 || echo 'not found')"
echo "    fastboot:  $(fastboot --version 2>/dev/null | head -1 || echo 'not found')"
echo "    clang:     $(clang --version 2>/dev/null | head -1 || echo 'not installed yet')"
echo "    ccache:    $(ccache --version 2>/dev/null | head -1 || echo 'not found')"
echo "    make:      $(make --version 2>/dev/null | head -1 || echo 'not found')"

echo ""
echo "==> Container ready. Next steps:"
echo "    1. Run ./setup.sh to clone kernel source + toolchain"
echo "    2. Run ./build.sh <device> to compile"
echo "    3. Use 'adb devices' or 'fastboot devices' to verify device connection"
