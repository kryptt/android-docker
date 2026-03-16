#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Clean flash LineageOS + custom kernel on any supported device
# ==============================================================================
# Usage: ./scripts/flash-device.sh <device>
#   device: oneplus7pro | oneplus8pro | oneplus10pro
#
# Device must be in fastboot mode.
# ==============================================================================

DEVICE="${1:?Usage: $0 <device>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF_FILE="${SCRIPT_DIR}/devices.conf"

# --- Look up device in registry ----------------------------------------------
DEVICE_LINE=$(grep "^${DEVICE}|" "$CONF_FILE" || true)
if [[ -z "$DEVICE_LINE" ]]; then
    echo "ERROR: Unknown device '$DEVICE'"
    grep -v '^#' "$CONF_FILE" | cut -d'|' -f1 | sed 's/^/  /'
    exit 1
fi

IFS='|' read -r _ SERIAL CODENAME PLATFORM PRODUCT HAS_RECOVERY HAS_SUPER NFS_VERSION HOSTNAME <<< "$DEVICE_LINE"

LINEAGE_DIR="${BASE_DIR}/lineageos/${CODENAME}"
LINEAGE_ZIP=$(ls "${LINEAGE_DIR}"/lineage-*.zip 2>/dev/null | head -1)
BOOT_IMG="${BASE_DIR}/out/${DEVICE}-boot.img"
VBMETA_IMG="${LINEAGE_DIR}/vbmeta.img"
DTBO_IMG="${LINEAGE_DIR}/dtbo.img"
RECOVERY_IMG="${LINEAGE_DIR}/recovery.img"
SUPER_EMPTY_IMG="${LINEAGE_DIR}/super_empty.img"

echo "============================================================"
echo " Clean Flash: ${DEVICE} (${CODENAME})"
echo "============================================================"
echo ""

# --- Preflight checks --------------------------------------------------------
echo "==> Preflight checks..."

if ! fastboot -s "$SERIAL" getvar product 2>&1 | grep -q "$PRODUCT"; then
    echo "ERROR: Device ${SERIAL} not found in fastboot or wrong product (expected: $PRODUCT)"
    fastboot devices
    exit 1
fi
echo "    Device in fastboot: OK (product=$PRODUCT)"

REQUIRED_FILES="$VBMETA_IMG $DTBO_IMG $BOOT_IMG"
[[ -n "$LINEAGE_ZIP" ]] && REQUIRED_FILES="$REQUIRED_FILES $LINEAGE_ZIP" || { echo "ERROR: No LineageOS zip in $LINEAGE_DIR"; exit 1; }
[[ "$HAS_RECOVERY" == "true" ]] && REQUIRED_FILES="$REQUIRED_FILES $RECOVERY_IMG"
[[ "$HAS_SUPER" == "true" ]] && REQUIRED_FILES="$REQUIRED_FILES $SUPER_EMPTY_IMG"

for f in $REQUIRED_FILES; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Missing file: $f"
        exit 1
    fi
    echo "    Found: $(basename "$f")"
done

CURRENT_SLOT=$(fastboot -s "$SERIAL" getvar current-slot 2>&1 | grep "current-slot:" | awk '{print $2}')
echo "    Current slot: ${CURRENT_SLOT}"
echo ""

# --- Flash vbmeta -------------------------------------------------------------
echo "==> Flashing vbmeta (disable AVB verification)..."
echo "    *** CONFIRM: Flash vbmeta + dtbo? [y/N] ***"
read -r CONFIRM
[[ "$CONFIRM" == [yY] ]] || { echo "Aborted."; exit 0; }

fastboot -s "$SERIAL" flash vbmeta "$VBMETA_IMG"
fastboot -s "$SERIAL" flash dtbo "$DTBO_IMG"
echo "    Done"

# --- Flash recovery (if device has it) ----------------------------------------
if [[ "$HAS_RECOVERY" == "true" ]]; then
    echo "==> Flashing LineageOS recovery..."
    fastboot -s "$SERIAL" flash recovery "$RECOVERY_IMG"
    echo "    Done"
fi

# --- Wipe userdata ------------------------------------------------------------
echo ""
echo "==> Wipe userdata (factory reset)"
echo "    *** WARNING: This erases ALL user data! [y/N] ***"
read -r CONFIRM
[[ "$CONFIRM" == [yY] ]] || { echo "Aborted."; exit 0; }

fastboot -s "$SERIAL" -w
[[ "$HAS_SUPER" == "true" ]] && fastboot -s "$SERIAL" wipe-super "$SUPER_EMPTY_IMG"
echo "    Done"

# --- Flash custom kernel boot image ------------------------------------------
echo "==> Flashing custom kernel boot image..."
fastboot -s "$SERIAL" flash boot "$BOOT_IMG"
echo "    Done"

# --- Reboot to recovery for sideload -----------------------------------------
echo ""
echo "==> Rebooting to recovery..."
echo "    In recovery:"
echo "    1. 'Factory Reset' -> 'Format data / factory reset'"
echo "    2. 'Apply update' -> 'Apply from ADB'"
echo ""
echo "    *** CONFIRM: Reboot to recovery? [y/N] ***"
read -r CONFIRM
[[ "$CONFIRM" == [yY] ]] || { echo "Aborted."; exit 0; }

fastboot -s "$SERIAL" reboot recovery

echo ""
echo "    Complete the recovery menu steps, then press Enter when in sideload mode."
read -r

# --- Sideload LineageOS -------------------------------------------------------
echo "==> Sideloading $(basename "$LINEAGE_ZIP")..."
adb -s "$SERIAL" sideload "$LINEAGE_ZIP"

echo ""
echo "==> Sideload complete."
echo ""
echo "============================================================"
echo " IMPORTANT: Post-sideload boot image fix"
echo "============================================================"
echo " LineageOS sideload may have changed the active slot."
echo " After rebooting to system, reflash boot to the active slot:"
echo ""
echo "   adb -s $SERIAL reboot bootloader"
echo "   fastboot -s $SERIAL getvar current-slot"
echo "   fastboot -s $SERIAL flash boot $BOOT_IMG"
echo "   fastboot -s $SERIAL reboot"
echo ""
echo " Then verify: adb shell 'cat /proc/filesystems | grep nfs'"
echo ""
echo " After kernel is verified, run:"
echo "   ./scripts/deploy-device.sh $DEVICE"
echo "============================================================"
