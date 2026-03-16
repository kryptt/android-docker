#!/system/bin/sh
# ==============================================================================
# Docker Swarm boot script (all devices)
# ==============================================================================
# Installed at: /data/docker/boot-worker.sh
# Triggered by: /system/etc/init/docker-swarm.rc (Android init service)
#
# On every boot this script:
#   1. Sets SELinux permissive (required for Docker)
#   2. Waits for WiFi connectivity
#   3. Remounts / read-write (for mount points)
#   4. Mounts tmpfs, cgroups
#   5. Mounts NFS shares via mount_nfs helper
#   6. Starts Docker daemon
#   7. Joins Docker Swarm (if not already a member)
#   8. Stays alive (so Android init doesn't kill dockerd)
# ==============================================================================

# --- Load config (pushed alongside this script) ------------------------------
CONF_FILE="/data/docker/swarm.conf"
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
else
    echo "FATAL: $CONF_FILE not found" >&2
    exit 1
fi

# --- Derived paths -----------------------------------------------------------
LOGFILE="/data/docker/boot.log"
DOCKER_SOCK="unix://${DOCKER_RUN}/docker.sock"
DOCKER_PID="${DOCKER_RUN}/docker.pid"
DOCKERD_LOG="/data/docker/dockerd.log"
MOUNT_NFS="${DOCKER_BIN}/mount_nfs"

export PATH="${DOCKER_BIN}:${PATH}"
export DOCKER_HOST="${DOCKER_SOCK}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

# --- Start logging -----------------------------------------------------------
echo "" >> "$LOGFILE"
log "========== BOOT START =========="

# --- Set SELinux to permissive (required for Docker) -------------------------
setenforce 0 2>/dev/null
log "SELinux: $(getenforce 2>/dev/null || echo unknown)"

# --- Set hostname -------------------------------------------------------------
if [ -n "${DEVICE_HOSTNAME:-}" ]; then
    hostname "$DEVICE_HOSTNAME" 2>/dev/null
    setprop net.hostname "$DEVICE_HOSTNAME" 2>/dev/null
    log "Hostname: $DEVICE_HOSTNAME"
fi

# --- Wait for WiFi connectivity ----------------------------------------------
log "Waiting for WiFi..."
WIFI_WAIT=0
while [ $WIFI_WAIT -lt $WIFI_WAIT_MAX ]; do
    WIFI_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    if [ -n "$WIFI_IP" ]; then
        log "WiFi connected: $WIFI_IP"
        break
    fi
    sleep 2
    WIFI_WAIT=$((WIFI_WAIT + 2))
done

if [ -z "$WIFI_IP" ]; then
    log "ERROR: WiFi not connected after ${WIFI_WAIT_MAX}s, continuing anyway..."
fi

# --- Remount root as read-write (needed for mount points and /run) -----------
log "Remounting / as rw..."
mount -o rw,remount / 2>/dev/null
log "Root remounted: $(mount | grep ' / ' | grep -o 'rw\|ro' | head -1)"

# --- DNS setup (Android has no /etc/resolv.conf by default) ------------------
if [ ! -f /etc/resolv.conf ] || ! grep -q nameserver /etc/resolv.conf 2>/dev/null; then
    log "Setting up DNS..."
    echo "nameserver 1.1.1.1" > /etc/resolv.conf
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
fi

# --- TLS CA certificates (Docker needs these for registry pulls) -------------
if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
    log "Creating CA certificate bundle..."
    mkdir -p /etc/ssl/certs
    cat /system/etc/security/cacerts/*.0 > /etc/ssl/certs/ca-certificates.crt 2>/dev/null
fi

# --- Mount /run tmpfs ---------------------------------------------------------
log "Mounting /run tmpfs..."
if ! mountpoint -q /run 2>/dev/null; then
    mkdir -p /run
    mount -t tmpfs tmpfs /run
fi
mkdir -p /run/lock /run/docker /run/containerd
if [ ! -d /var ] || [ ! -L /var/run ]; then
    mkdir -p /var
    ln -sf /run /var/run 2>/dev/null
fi
log "/run mounted"

# --- Mount cgroups ------------------------------------------------------------
log "Mounting cgroups..."
if ! mountpoint -q /sys/fs/cgroup 2>/dev/null; then
    mount -t tmpfs cgroup_root /sys/fs/cgroup 2>/dev/null
fi

for cg in cpuset cpu,cpuacct memory devices freezer pids blkio; do
    subsys=$(echo "$cg" | cut -d, -f1)
    dir="/sys/fs/cgroup/${subsys}"
    if ! mountpoint -q "$dir" 2>/dev/null; then
        mkdir -p "$dir"
        mount -t cgroup -o "$cg" none "$dir" 2>/dev/null
    fi
done
log "Cgroups mounted"

# --- Fix networking for Docker containers -------------------------------------
log "Configuring network..."
# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
# Add default route via WiFi gateway (Android uses per-app routing, no global default)
if [ -n "$WIFI_IP" ]; then
    GATEWAY=$(ip route show table all | grep "default via" | grep wlan0 | head -1 | awk '{print $3}')
    if [ -n "$GATEWAY" ]; then
        ip route add default via "$GATEWAY" dev wlan0 2>/dev/null
        log "Default route: via $GATEWAY"
    fi
fi
# Flush Android's tethering firewall (blocks all FORWARD by default)
iptables -F tetherctrl_FORWARD 2>/dev/null
log "Network configured"

# --- Mount NFS shares ---------------------------------------------------------
log "Mounting NFS shares..."

do_mount_nfs() {
    local src="$1"
    local dst="$2"
    mkdir -p "$dst"
    if mountpoint -q "$dst" 2>/dev/null; then
        log "  $dst already mounted"
        return 0
    fi
    if [ -x "$MOUNT_NFS" ]; then
        if "$MOUNT_NFS" "$src" "$dst" "${NFS_VERSION:-3}" >> "$LOGFILE" 2>&1; then
            log "  Mounted $src -> $dst"
        else
            log "  ERROR: Failed to mount $src -> $dst"
            return 1
        fi
    else
        log "  ERROR: mount_nfs binary not found at $MOUNT_NFS"
        return 1
    fi
}

if [ -n "$WIFI_IP" ]; then
    if ping -c 1 -W 3 "$NFS_SERVER" > /dev/null 2>&1; then
        log "NFS server $NFS_SERVER is reachable"
        echo "$NFS_MOUNTS" | while IFS=: read -r server_path mount_point; do
            [ -z "$server_path" ] && continue
            do_mount_nfs "${NFS_SERVER}:${server_path}" "${mount_point}"
        done
    else
        log "ERROR: NFS server $NFS_SERVER not reachable"
    fi
else
    log "Skipping NFS mounts (no WiFi)"
fi

# --- Start Docker daemon -----------------------------------------------------
log "Starting Docker daemon..."

if [ -f "$DOCKER_PID" ]; then
    OLD_PID=$(cat "$DOCKER_PID" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        log "Docker already running (PID $OLD_PID), skipping start"
    else
        log "Removing stale PID file"
        rm -f "$DOCKER_PID"
    fi
fi

if [ ! -f "$DOCKER_PID" ] || ! kill -0 "$(cat "$DOCKER_PID" 2>/dev/null)" 2>/dev/null; then
    : > "$DOCKERD_LOG"

    setsid dockerd \
        --data-root "$DOCKER_DATA" \
        --exec-root "$DOCKER_RUN" \
        --pidfile "$DOCKER_PID" \
        --host "$DOCKER_SOCK" \
        --iptables=true \
        >> "$DOCKERD_LOG" 2>&1 &

    log "Docker daemon starting (PID $!)"

    DOCKER_WAIT=0
    while [ $DOCKER_WAIT -lt $DOCKER_STARTUP_MAX ]; do
        if docker info > /dev/null 2>&1; then
            log "Docker is ready"
            break
        fi
        sleep 2
        DOCKER_WAIT=$((DOCKER_WAIT + 2))
    done

    if [ $DOCKER_WAIT -ge $DOCKER_STARTUP_MAX ]; then
        log "ERROR: Docker did not start within ${DOCKER_STARTUP_MAX}s"
        log "Check $DOCKERD_LOG for details"
    fi
fi

# --- Join Docker Swarm --------------------------------------------------------
log "Checking Swarm status..."

SWARM_STATUS=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)
log "Swarm state: $SWARM_STATUS"

if [ "$SWARM_STATUS" = "active" ]; then
    log "Already in Swarm, no action needed"
elif [ "$SWARM_STATUS" = "inactive" ] || [ "$SWARM_STATUS" = "" ]; then
    if [ -n "$WIFI_IP" ]; then
        log "Joining Swarm..."
        if docker swarm join --token "$SWARM_TOKEN" "$SWARM_MANAGER" >> "$LOGFILE" 2>&1; then
            log "Successfully joined Swarm"
        else
            log "ERROR: Failed to join Swarm"
        fi
    else
        log "Skipping Swarm join (no WiFi)"
    fi
else
    log "Swarm in state '$SWARM_STATUS', not joining"
fi

# --- Start SSH server (via Docker container with host networking) -------------
log "Starting SSH server..."
if docker inspect phone-sshd > /dev/null 2>&1; then
    docker start phone-sshd >> "$LOGFILE" 2>&1
    log "SSH container restarted"
else
    log "SSH container not found (run deploy-device.sh to set up)"
fi

# --- Final status -------------------------------------------------------------
log "Boot script complete"
docker info 2>/dev/null | grep -E 'Server Version|Swarm|Node Address' >> "$LOGFILE"
log "========== BOOT DONE =========="

# --- Keep script alive so init doesn't kill dockerd --------------------------
# Android init kills all children of a service when it exits.
# Wait forever so the service process (and its children) stay alive.
while kill -0 "$(cat "$DOCKER_PID" 2>/dev/null)" 2>/dev/null; do
    sleep 60
done
log "Docker daemon exited, boot script ending"
