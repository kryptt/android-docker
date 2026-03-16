#!/system/bin/sh
# ==============================================================================
# Post-boot setup: Swarm join + SSH container
# ==============================================================================
# Runs via exec_background on sys.boot_completed=1.
# Infrastructure (Docker, NFS, networking) is set up by start-dockerd.sh.
# This script just waits for Docker to be ready, joins the swarm, and
# starts the SSH container.
# ==============================================================================

# --- Load config --------------------------------------------------------------
CONF_FILE="/data/docker/swarm.conf"
if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
else
    echo "FATAL: $CONF_FILE not found" >&2
    exit 1
fi

LOGFILE="/data/docker/boot.log"
DOCKER_SOCK="unix://${DOCKER_RUN}/docker.sock"

export PATH="${DOCKER_BIN}:${PATH}"
export DOCKER_HOST="${DOCKER_SOCK}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

echo "" >> "$LOGFILE"
log "========== BOOT START =========="

# --- Wait for Docker daemon (managed by init service 'dockerd') ---------------
log "Waiting for Docker daemon..."
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
    log "ERROR: Docker not ready after ${DOCKER_STARTUP_MAX}s"
    exit 1
fi

# --- Join Docker Swarm --------------------------------------------------------
log "Checking Swarm status..."

SWARM_STATUS=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)
log "Swarm state: $SWARM_STATUS"

if [ "$SWARM_STATUS" = "active" ]; then
    log "Already in Swarm, no action needed"
elif [ "$SWARM_STATUS" = "inactive" ] || [ "$SWARM_STATUS" = "" ]; then
    WIFI_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')
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
