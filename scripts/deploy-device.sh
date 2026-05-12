#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Deploy Docker Swarm or K3s boot script + binaries to any device
# ==============================================================================
# Usage: ./scripts/deploy-device.sh [--k3s] <device>
#   --k3s:  Deploy k3s agent instead of Docker Swarm
#   device: oneplus7pro | oneplus8pro | oneplus10pro
#
# Prerequisites:
#   - Device booted into Android with adb connected
#   - adb root available (LineageOS userdebug) or Magisk root
#   - Docker binaries downloaded (docker-binaries/docker/) [docker mode]
#   - k3s arm64 binary at k3s-arm64 [k3s mode]
#   - mount_nfs compiled (tools/mount_nfs)
#   - .envrc filled with K3S_TOKEN and K3S_NODE_* vars [k3s mode]
# ==============================================================================

DEPLOY_MODE="docker"
if [[ "${1:-}" == "--k3s" ]]; then
    DEPLOY_MODE="k3s"
    shift
fi

DEVICE="${1:?Usage: $0 [--k3s] <device>}"
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

# Validate k3s mode has a usable node IP (not "-" placeholder)
if [[ "$DEPLOY_MODE" == "k3s" && ( -z "${K3S_NODE_IP:-}" || "$K3S_NODE_IP" == "-" ) ]]; then
    echo "ERROR: ${DEVICE} has no k3s_node_ip in devices.conf — cannot deploy k3s."
    exit 1
fi

echo "============================================================"
echo " Deploy ${DEPLOY_MODE^^} to ${DEVICE} (${SERIAL})"
echo "============================================================"
echo ""

# --- Verify device is connected -----------------------------------------------
if ! adb -s "$SERIAL" get-state 2>/dev/null | grep -q "device"; then
    echo "ERROR: Device ${SERIAL} not found or not in 'device' state"
    exit 1
fi
echo "    Device connected"

# --- Get root -----------------------------------------------------------------
echo "==> Getting root..."
if adb -s "$SERIAL" root 2>/dev/null | grep -q "already running as root\|restarting"; then
    sleep 5
    echo "    Root via adb root"
else
    # Fall back to checking for su
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

# --- Push binaries ------------------------------------------------------------
if [[ "$DEPLOY_MODE" == "docker" ]]; then
    DOCKER_DIR="${BASE_DIR}/docker-binaries/docker"
    if [[ ! -d "$DOCKER_DIR" ]]; then
        echo "ERROR: Docker binaries not found at $DOCKER_DIR"
        echo "Run: mkdir -p docker-binaries && curl -sSL https://download.docker.com/linux/static/stable/aarch64/docker-28.2.2.tgz | tar xz -C docker-binaries"
        exit 1
    fi

    echo "==> Pushing Docker binaries..."
    for bin in dockerd docker containerd containerd-shim-runc-v2 runc docker-proxy docker-init ctr; do
        [[ -f "${DOCKER_DIR}/${bin}" ]] && adb -s "$SERIAL" push "${DOCKER_DIR}/${bin}" /data/docker/bin/ 2>&1 | tail -1
    done
else
    K3S_BIN="${BASE_DIR}/k3s-arm64"
    if [[ ! -f "$K3S_BIN" ]]; then
        echo "ERROR: k3s binary not found at $K3S_BIN"
        echo "Run: curl -Lo k3s-arm64 'https://github.com/k3s-io/k3s/releases/download/v1.34.5%2Bk3s1/k3s-arm64'"
        exit 1
    fi

    echo "==> Pushing k3s binary..."
    adb -s "$SERIAL" push "$K3S_BIN" /data/docker/bin/k3s 2>&1 | tail -1

    # GlusterFS host-side install. start-k3s.sh has an existing block
    # that wants /data/glusterfs/{bin/glusterfs,lib/glusterfs} on the
    # device; without these files it can't mount /swarm/ha at boot and
    # the in-cluster glusterfs-client DaemonSet can only mount the
    # volume inside its own mount namespace (invisible to every other
    # pod on the node).
    GFS_TREE="${BASE_DIR}/glusterfs-host-tree"
    if [[ ! -d "$GFS_TREE" ]]; then
        echo "==> Extracting GlusterFS host tree (first run only)..."
        "${SCRIPT_DIR}/extract-glusterfs-host-tree.sh"
    fi

    echo "==> Pushing GlusterFS host tree to /data/glusterfs/..."
    adb_root 'mkdir -p /data/glusterfs'
    # Push bin/ and lib/ as wholes; adb push handles directories
    # recursively. Refresh on every deploy so version bumps from the
    # hr-fleet container ship to the device.
    adb -s "$SERIAL" push "$GFS_TREE/bin" /data/glusterfs/ 2>&1 | tail -1
    adb -s "$SERIAL" push "$GFS_TREE/lib" /data/glusterfs/ 2>&1 | tail -1
    adb -s "$SERIAL" push "$GFS_TREE/MANIFEST" /data/glusterfs/MANIFEST 2>&1 | tail -1
    adb_root 'chmod 755 /data/glusterfs/bin/glusterfs /data/glusterfs/bin/glusterfsd /data/glusterfs/lib/ld-linux-aarch64.so.1'
fi
adb_root 'chmod 755 /data/docker/bin/*'

# --- Push mount_nfs -----------------------------------------------------------
echo "==> Pushing mount_nfs..."
adb -s "$SERIAL" push "$MOUNT_NFS" /data/docker/bin/mount_nfs 2>&1 | tail -1
adb_root 'chmod 755 /data/docker/bin/mount_nfs'

# --- Push config and secrets --------------------------------------------------
ENVRC="${BASE_DIR}/.envrc"
if [[ ! -f "$ENVRC" ]]; then
    echo "ERROR: .envrc not found at $ENVRC"
    echo "Copy .envrc.example to .envrc and fill in your NFS/Swarm values."
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
ENVEOF

if [[ "$DEPLOY_MODE" == "docker" ]]; then
    cat >> "$TMPENV" << ENVEOF
SWARM_TOKEN="${SWARM_TOKEN}"
SWARM_MANAGER="${SWARM_MANAGER}"
ENVEOF
else
    cat >> "$TMPENV" << ENVEOF
K3S_NODE_IP="${K3S_NODE_IP}"
K3S_NODE_1="${K3S_NODE_1}"
K3S_NODE_2="${K3S_NODE_2}"
K3S_NODE_3="${K3S_NODE_3}"
K3S_NODE_4="${K3S_NODE_4}"
ENVEOF
fi

adb -s "$SERIAL" push "$TMPENV" /data/docker/swarm.env 2>&1 | tail -1
adb_root 'chmod 600 /data/docker/swarm.env'
rm -f "$TMPENV"

if [[ "$DEPLOY_MODE" == "docker" ]]; then
    echo "==> Pushing scripts..."
    adb -s "$SERIAL" push "${SCRIPT_DIR}/start-dockerd.sh" /data/docker/start-dockerd.sh 2>&1 | tail -1
    adb -s "$SERIAL" push "${SCRIPT_DIR}/docker-swarm-boot.sh" /data/docker/boot-worker.sh 2>&1 | tail -1
    adb_root 'chmod 755 /data/docker/start-dockerd.sh /data/docker/boot-worker.sh'
else
    echo "==> Pushing k3s scripts and config..."
    adb -s "$SERIAL" push "${SCRIPT_DIR}/start-k3s.sh" /data/docker/start-k3s.sh 2>&1 | tail -1
    adb_root 'chmod 755 /data/docker/start-k3s.sh'

    # Generate k3s agent config
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
fi

# --- Install init.rc boot trigger -------------------------------------------------
echo "==> Installing init.rc..."
adb_root 'mount -o rw,remount / 2>/dev/null'

if [[ "$DEPLOY_MODE" == "docker" ]]; then
    # dockerd runs as an init service (init keeps it alive / restarts on crash).
    # boot-worker.sh runs once after boot_completed for swarm join + SSH.
    adb_root 'cat > /system/etc/init/docker-swarm.rc << "INITEOF"
service dockerd /system/bin/sh /data/docker/start-dockerd.sh
    class late_start
    user root
    group root
    seclabel u:r:su:s0
    writepid /dev/cpuset/foreground/tasks

on property:sys.boot_completed=1
    exec_background u:r:su:s0 root root -- /system/bin/sh /data/docker/boot-worker.sh
INITEOF'
    adb_root 'chmod 644 /system/etc/init/docker-swarm.rc'
    # Remove k3s init if it exists
    adb_root 'rm -f /system/etc/init/k3s-agent.rc'
else
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
    # Remove docker init to prevent conflict
    adb_root 'rm -f /system/etc/init/docker-swarm.rc'
fi

# --- Create SSH container (Docker mode only) ----------------------------------
if [[ "$DEPLOY_MODE" == "docker" ]]; then
    echo "==> Setting up SSH container..."
    SSH_PUBKEY_FILE="${BASE_DIR}/.ssh/authorized_keys"
    if [[ -f "$SSH_PUBKEY_FILE" ]]; then
        SSH_PUBKEY=$(cat "$SSH_PUBKEY_FILE")
    elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
        SSH_PUBKEY=$(cat "${HOME}/.ssh/id_ed25519.pub")
    elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
        SSH_PUBKEY=$(cat "${HOME}/.ssh/id_rsa.pub")
    else
        echo "    WARNING: No SSH public key found. SSH will not be set up."
        echo "    Place your public key in .ssh/authorized_keys or ~/.ssh/id_ed25519.pub"
        SSH_PUBKEY=""
    fi

    if [[ -n "$SSH_PUBKEY" ]]; then
        adb -s "$SERIAL" shell "
            export DOCKER_HOST=unix:///data/docker/run/docker.sock PATH=/data/docker/bin:\$PATH
            docker rm -f phone-sshd 2>/dev/null
            docker create \
                --name phone-sshd \
                --restart unless-stopped \
                --network host \
                --cap-add NET_ADMIN \
                -v /data:/data \
                alpine:latest \
                sh -c '
                    apk add --no-cache openssh-server && \
                    ssh-keygen -A && \
                    mkdir -p /root/.ssh && \
                    echo \"${SSH_PUBKEY}\" > /root/.ssh/authorized_keys && \
                    chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && \
                    sed -i \"s/#PermitRootLogin.*/PermitRootLogin yes/\" /etc/ssh/sshd_config && \
                    sed -i \"s/#Port 22/Port 8022/\" /etc/ssh/sshd_config && \
                    /usr/sbin/sshd -D -e -p 8022
                '
        " 2>&1 | tail -1
        echo "    SSH container created (port 8022, key-only auth)"
    fi
else
    echo "==> SSH: will be deployed as a k3s pod (use adb for access until then)"
fi

# --- Verify -------------------------------------------------------------------
echo ""
echo "==> Verifying installation..."
if [[ "$DEPLOY_MODE" == "docker" ]]; then
    adb_root 'ls -la /data/docker/boot-worker.sh /data/docker/swarm.conf /system/etc/init/docker-swarm.rc /data/docker/bin/dockerd /data/docker/bin/mount_nfs'
    echo ""
    echo "==> Done! Reboot the device to start Docker Swarm automatically."
    echo ""
    echo "    To test without reboot:"
    echo "      adb -s ${SERIAL} shell 'sh /data/docker/boot-worker.sh &'"
    echo ""
    echo "    To check logs after reboot:"
    echo "      adb -s ${SERIAL} root && sleep 5"
    echo "      adb -s ${SERIAL} shell 'cat /data/docker/boot.log'"
    echo "      adb -s ${SERIAL} shell 'DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker info'"
else
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
fi
