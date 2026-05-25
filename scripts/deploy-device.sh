#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Deploy k3s agent boot script + binaries to any device
# ==============================================================================
# Usage: ./scripts/deploy-device.sh <device>
#   device: oneplus7pro | oneplus8pro | oneplus10pro
#
# Prerequisites:
#   - Device booted into Android with adb connected (USB or wireless)
#   - adb root available (LineageOS userdebug) or Magisk root
#   - k3s arm64 binary at k3s-arm64
#   - mount_nfs compiled (tools/mount_nfs)
#   - .envrc filled with K3S_TOKEN and K3S_NODE_* vars
# ==============================================================================

DEVICE="${1:?Usage: $0 <device>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONF_FILE="${SCRIPT_DIR}/devices.conf"

# --- Look up device in registry ----------------------------------------------
DEVICE_LINE=$(grep "^${DEVICE}|" "$CONF_FILE" || true)
if [[ -z "$DEVICE_LINE" ]]; then
    echo "ERROR: Unknown device '$DEVICE'"
    echo "Known devices:"
    grep -v '^#' "$CONF_FILE" | cut -d'|' -f1 | sed 's/^/  /'
    exit 1
fi

IFS='|' read -r _ SERIAL CODENAME PLATFORM PRODUCT HAS_RECOVERY HAS_SUPER NFS_VERSION HOSTNAME WIFI_IP K3S_NODE_IP <<< "$DEVICE_LINE"

if [[ -z "${K3S_NODE_IP:-}" || "$K3S_NODE_IP" == "-" ]]; then
    echo "ERROR: ${DEVICE} has no k3s_node_ip in devices.conf — cannot deploy."
    exit 1
fi

echo "============================================================"
echo " Deploy k3s to ${DEVICE} (${SERIAL})"
echo "============================================================"
echo ""

# --- Verify device is connected ----------------------------------------------
# Prefer the USB serial when present (faster, less brittle), otherwise fall
# back to the wireless-ADB endpoint. Wireless adb (service.adb.tcp.port=5555,
# set by start-k3s.sh) advertises the device as "<ip>:5555" instead of the
# USB serial, so a hard match on $SERIAL fails once the phone is off USB.
if ! adb -s "$SERIAL" get-state 2>/dev/null | grep -q "device"; then
    for candidate in "${K3S_NODE_IP:-}:5555" "${WIFI_IP:-}:5555"; do
        [ "$candidate" = ":5555" ] && continue
        if adb -s "$candidate" get-state 2>/dev/null | grep -q "device"; then
            echo "    USB serial ${SERIAL} not connected; using wireless ${candidate}"
            SERIAL="$candidate"
            break
        fi
    done
fi
if ! adb -s "$SERIAL" get-state 2>/dev/null | grep -q "device"; then
    echo "ERROR: Device ${DEVICE} not reachable (tried USB serial + wireless on ${WIFI_IP}:5555, ${K3S_NODE_IP}:5555)"
    exit 1
fi
echo "    Device connected (${SERIAL})"

# --- Get root -----------------------------------------------------------------
echo "==> Getting root..."
if adb -s "$SERIAL" root 2>/dev/null | grep -q "already running as root\|restarting"; then
    sleep 5
    echo "    Root via adb root"
else
    if adb -s "$SERIAL" shell "su -c id" 2>/dev/null | grep -q "uid=0"; then
        echo "    Root via Magisk su"
    else
        echo "ERROR: No root access. Need LineageOS userdebug (adb root) or Magisk."
        exit 1
    fi
fi

# Helper: run a command as root on device
adb_root() {
    adb -s "$SERIAL" shell "$@"
}

# --- Build mount_nfs if needed ------------------------------------------------
MOUNT_NFS="${BASE_DIR}/tools/mount_nfs"
if [[ ! -f "$MOUNT_NFS" ]]; then
    echo "==> Compiling mount_nfs..."
    aarch64-linux-gnu-gcc -static -o "$MOUNT_NFS" "${BASE_DIR}/tools/mount_nfs.c"
fi

# --- Create directories -------------------------------------------------------
echo "==> Creating /data/docker/ directories..."
adb_root 'mkdir -p /data/docker/bin /data/docker/lib /data/docker/run'

# --- Push k3s binary ----------------------------------------------------------
K3S_BIN="${BASE_DIR}/k3s-arm64"
if [[ ! -f "$K3S_BIN" ]]; then
    echo "ERROR: k3s binary not found at $K3S_BIN"
    echo "Run: curl -Lo k3s-arm64 'https://github.com/k3s-io/k3s/releases/download/v1.34.5%2Bk3s1/k3s-arm64'"
    exit 1
fi

echo "==> Pushing k3s binary..."
adb -s "$SERIAL" push "$K3S_BIN" /data/docker/bin/k3s 2>&1 | tail -1

# --- Push GlusterFS host tree -------------------------------------------------
# start-k3s.sh's gluster block mounts /swarm/ha at boot using these binaries +
# libs; without them the in-cluster glusterfs-client DaemonSet can only mount
# the volume inside its own mount namespace (invisible to every other pod).
GFS_TREE="${BASE_DIR}/glusterfs-host-tree"
if [[ ! -d "$GFS_TREE" ]]; then
    echo "==> Extracting GlusterFS host tree (first run only)..."
    "${SCRIPT_DIR}/extract-glusterfs-host-tree.sh"
fi

echo "==> Pushing GlusterFS host tree to /data/glusterfs/..."
adb_root 'mkdir -p /data/glusterfs'
# Recursive push refreshes the tree on every deploy so version bumps from the
# hr-fleet container ship to the device.
adb -s "$SERIAL" push "$GFS_TREE/bin" /data/glusterfs/ 2>&1 | tail -1
adb -s "$SERIAL" push "$GFS_TREE/lib" /data/glusterfs/ 2>&1 | tail -1
adb -s "$SERIAL" push "$GFS_TREE/MANIFEST" /data/glusterfs/MANIFEST 2>&1 | tail -1
adb_root 'chmod 755 /data/glusterfs/bin/glusterfs /data/glusterfs/bin/glusterfsd /data/glusterfs/lib/ld-linux-aarch64.so.1'

adb_root 'chmod 755 /data/docker/bin/*'

# --- Push POSIX zoneinfo ------------------------------------------------------
# Android lacks the standard IANA zoneinfo directory tree that Go binaries (like
# kube-state-metrics) expect at /usr/share/zoneinfo. Push the host's copy.
ZONEINFO_SRC="/usr/share/zoneinfo"
if [[ -d "$ZONEINFO_SRC" ]]; then
    echo "==> Pushing POSIX zoneinfo..."
    TMPTZ=$(mktemp)
    tar czf "$TMPTZ" -C /usr/share zoneinfo
    adb -s "$SERIAL" push "$TMPTZ" /data/docker/zoneinfo.tar.gz 2>&1 | tail -1
    adb_root 'rm -rf /data/docker/zoneinfo && mkdir -p /data/docker && cd /data/docker && tar xzf zoneinfo.tar.gz && rm zoneinfo.tar.gz'
    rm -f "$TMPTZ"
else
    echo "    SKIP: /usr/share/zoneinfo not found on host"
fi

# --- Push mount_nfs -----------------------------------------------------------
echo "==> Pushing mount_nfs..."
adb -s "$SERIAL" push "$MOUNT_NFS" /data/docker/bin/mount_nfs 2>&1 | tail -1
adb_root 'chmod 755 /data/docker/bin/mount_nfs'

# --- Push config and secrets --------------------------------------------------
ENVRC="${BASE_DIR}/.envrc"
if [[ ! -f "$ENVRC" ]]; then
    echo "ERROR: .envrc not found at $ENVRC"
    echo "Copy .envrc.example to .envrc and fill in your NFS/k3s values."
    exit 1
fi
# shellcheck source=../.envrc
source "$ENVRC"

echo "==> Pushing swarm.conf..."
adb -s "$SERIAL" push "${SCRIPT_DIR}/swarm.conf" /data/docker/swarm.conf 2>&1 | tail -1

echo "==> Pushing swarm.env (secrets)..."
TMPENV=$(mktemp)
cat > "$TMPENV" << ENVEOF
# Auto-generated by deploy-device.sh — do not edit on device
NFS_SERVER="${NFS_SERVER}"
NFS_MOUNTS="${NFS_MOUNTS}"
NFS_VERSION=${NFS_VERSION}
DEVICE_HOSTNAME=${HOSTNAME}
K3S_NODE_IP="${K3S_NODE_IP}"
K3S_NODE_1="${K3S_NODE_1}"
K3S_NODE_2="${K3S_NODE_2}"
K3S_NODE_3="${K3S_NODE_3}"
K3S_NODE_4="${K3S_NODE_4}"
ENVEOF

adb -s "$SERIAL" push "$TMPENV" /data/docker/swarm.env 2>&1 | tail -1
adb_root 'chmod 600 /data/docker/swarm.env'
rm -f "$TMPENV"

# --- Push k3s agent boot script + agent config --------------------------------
echo "==> Pushing k3s scripts and config..."
adb -s "$SERIAL" push "${SCRIPT_DIR}/start-k3s.sh" /data/docker/start-k3s.sh 2>&1 | tail -1
adb_root 'chmod 755 /data/docker/start-k3s.sh'

echo "==> Generating k3s-config.yaml..."
TMPCONF=$(mktemp)
cat > "$TMPCONF" << CONFEOF
server: https://10.10.0.1:6443
token: ${K3S_TOKEN}
node-name: ${HOSTNAME}
node-ip: ${K3S_NODE_IP}
flannel-iface: wlan0
data-dir: /data/docker/k3s-data
kubelet-arg:
  - cgroup-driver=cgroupfs
  - resolv-conf=/etc/resolv.conf
  - cgroup-root=/
node-label:
  - hr-home.xyz/android=true
  - hr-home.xyz/device=${DEVICE}
node-taint:
  - android=true:NoSchedule
CONFEOF
adb -s "$SERIAL" push "$TMPCONF" /data/docker/k3s-config.yaml 2>&1 | tail -1
adb_root 'chmod 600 /data/docker/k3s-config.yaml'
rm -f "$TMPCONF"

# --- Install init.rc boot trigger ---------------------------------------------
echo "==> Installing init.rc..."
adb_root 'mount -o rw,remount / 2>/dev/null'

# k3s agent runs as an init service (init keeps it alive / restarts on crash).
# NOTE: no `writepid /dev/cpuset/...` here — with the cpuset-v2 backport
# plus the cgroups.json edit, /dev/cpuset is no longer mounted (cpuset
# lives in v2 at /sys/fs/cgroup). Writing the pid to a non-existent path
# would make init refuse to start the service.
adb_root 'cat > /system/etc/init/k3s-agent.rc << "INITEOF"
service k3sagent /system/bin/sh /data/docker/start-k3s.sh
    class late_start
    user root
    group root
    seclabel u:r:su:s0
INITEOF'
adb_root 'chmod 644 /system/etc/init/k3s-agent.rc'

# --- Verify -------------------------------------------------------------------
echo ""
echo "==> Verifying installation..."
adb_root 'ls -la /data/docker/start-k3s.sh /data/docker/k3s-config.yaml /data/docker/swarm.conf /system/etc/init/k3s-agent.rc /data/docker/bin/k3s /data/docker/bin/mount_nfs'
echo ""
echo "==> Done! Reboot the device to start k3s agent automatically."
echo ""
echo "    To check logs after reboot:"
echo "      adb -s ${SERIAL} root && sleep 5"
echo "      adb -s ${SERIAL} shell 'tail -50 /data/docker/k3s-agent.log'"
echo ""
echo "    To verify on cluster:"
echo "      kubectl get node ${HOSTNAME}"
