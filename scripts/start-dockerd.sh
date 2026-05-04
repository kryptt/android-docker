#!/system/bin/sh
# ==============================================================================
# Docker daemon starter — runs as Android init service
# ==============================================================================
# init keeps this process alive (restarts on crash).
# The shell exec's into dockerd so init tracks dockerd directly.
#
# Network-dependent tasks (NFS, GlusterFS, default route) run in a
# background subshell so dockerd starts immediately without waiting
# for WiFi.
# ==============================================================================

setenforce 0
mount -o rw,remount / 2>/dev/null

# Load config
. /data/docker/swarm.conf 2>/dev/null
. /data/docker/swarm.env 2>/dev/null

# DNS + TLS certs
echo "nameserver 1.1.1.1" > /etc/resolv.conf 2>/dev/null
echo "nameserver 8.8.8.8" >> /etc/resolv.conf 2>/dev/null
if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
    mkdir -p /etc/ssl/certs
    cat /system/etc/security/cacerts/*.0 > /etc/ssl/certs/ca-certificates.crt 2>/dev/null
fi

# Standard Docker path symlinks
mkdir -p /var/lib /run/lock /run/docker /run/containerd /var/empty
[ -L /var/run ] || ln -sf /run /var/run 2>/dev/null
[ -L /var/lib/docker ] || ln -sf /data/docker/lib /var/lib/docker 2>/dev/null
[ -L /var/run/docker.sock ] || ln -sf /data/docker/run/docker.sock /var/run/docker.sock 2>/dev/null

# Networking — clear Android firewall chains that block Docker bridge traffic
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
echo 1 > /proc/sys/net/ipv4/conf/all/forwarding 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null

# Flush all Android FORWARD sub-chains (they default-DROP and block container traffic)
for chain in tetherctrl_FORWARD oem_fwd fw_FORWARD bw_FORWARD natctrl_FORWARD; do
    iptables -F "$chain" 2>/dev/null
    ip6tables -F "$chain" 2>/dev/null
done

# Set FORWARD policy to ACCEPT — dockerd will manage its own DOCKER-FORWARD rules
iptables -P FORWARD ACCEPT 2>/dev/null
ip6tables -P FORWARD ACCEPT 2>/dev/null

# Bridge netfilter — required for Docker bridge networking to apply iptables to bridged traffic
if [ -d /proc/sys/net/bridge ]; then
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-ip6tables 2>/dev/null
fi

# Policy routing — Android never looks up the "main" routing table where Docker
# adds its bridge/overlay subnet routes.  Without these rules, container traffic
# to Docker subnets is routed out wlan0 instead of docker0/docker_gwbridge.
for subnet in 172.16.0.0/12 10.0.0.0/8; do
    ip rule add to "$subnet" lookup main prio 9000 2>/dev/null
    ip rule add from "$subnet" lookup main prio 9000 2>/dev/null
done

# Cgroups — mount full hierarchy that Docker expects under /sys/fs/cgroup
mountpoint -q /sys/fs/cgroup 2>/dev/null || \
    mount -t tmpfs -o mode=755 cgroup_root /sys/fs/cgroup 2>/dev/null

for subsys in cpu,cpuacct cpuset blkio memory pids devices freezer; do
    dir="/sys/fs/cgroup/${subsys}"
    mkdir -p "$dir"
    if ! mountpoint -q "$dir" 2>/dev/null; then
        # Use the real subsystem name for mount (strip comma-joined aliases)
        mount -t cgroup -o "${subsys}" "cgroup_${subsys}" "$dir" 2>/dev/null
    fi
done

# Ensure cpuset defaults are set (Docker needs these to create child cgroups)
if [ -f /sys/fs/cgroup/cpuset/cpuset.cpus ] && [ ! -s /sys/fs/cgroup/cpuset/cpuset.cpus ]; then
    grep Cpus_allowed_list /proc/self/status | awk '{print $2}' > /sys/fs/cgroup/cpuset/cpuset.cpus 2>/dev/null
    grep Mems_allowed_list /proc/self/status | awk '{print $2}' > /sys/fs/cgroup/cpuset/cpuset.mems 2>/dev/null
fi

# Hostname
[ -n "${DEVICE_HOSTNAME:-}" ] && hostname "$DEVICE_HOSTNAME" 2>/dev/null

# Create mount points
mkdir -p /swarm/ha /var/log/glusterfs /var/lib/glusterd

# GlusterFS xlator symlinks (needed even before mount)
GFS_BIN=/data/glusterfs/bin/glusterfs
if [ -x "$GFS_BIN" ]; then
    mkdir -p /usr/lib/aarch64-linux-gnu /usr/sbin
    [ -L /usr/lib/aarch64-linux-gnu/glusterfs ] || \
        ln -sf /data/glusterfs/lib/glusterfs /usr/lib/aarch64-linux-gnu/glusterfs 2>/dev/null
    [ -L /usr/sbin/glusterfs ] || \
        ln -sf /data/glusterfs/bin/glusterfs /usr/sbin/glusterfs 2>/dev/null
fi

# --- Background: WiFi-dependent mounts (don't block dockerd startup) ---------
(
    LOGFILE="/data/docker/mounts.log"
    echo "$(date '+%Y-%m-%d %H:%M:%S') Waiting for WiFi..." > "$LOGFILE"

    # Wait for WiFi
    WIFI_WAIT=0
    while [ $WIFI_WAIT -lt "${WIFI_WAIT_MAX:-120}" ]; do
        WIFI_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')
        [ -n "$WIFI_IP" ] && break
        sleep 2
        WIFI_WAIT=$((WIFI_WAIT + 2))
    done

    if [ -z "$WIFI_IP" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: WiFi not connected after ${WIFI_WAIT_MAX:-120}s" >> "$LOGFILE"
        exit 1
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') WiFi: $WIFI_IP" >> "$LOGFILE"

    # Default route — must exist in the main table for Docker container forwarding.
    # Android keeps the default route only in the per-interface wlan0 table, so we
    # copy it into main (where our prio-9000 ip rules direct Docker traffic).
    GATEWAY=$(ip route show table wlan0 | grep "default via" | head -1 | awk '{print $3}')
    if [ -n "$GATEWAY" ]; then
        ip route replace default via "$GATEWAY" dev wlan0 table main 2>/dev/null
    fi

    # NFS mounts
    MOUNT_NFS="/data/docker/bin/mount_nfs"
    if [ -n "${NFS_SERVER:-}" ] && [ -x "$MOUNT_NFS" ] && ping -c 1 -W 5 "$NFS_SERVER" > /dev/null 2>&1; then
        echo "$NFS_MOUNTS" | while IFS=: read -r server_path mount_point; do
            [ -z "$server_path" ] && continue
            mkdir -p "$mount_point"
            if ! mountpoint -q "$mount_point" 2>/dev/null; then
                if "$MOUNT_NFS" "${NFS_SERVER}:${server_path}" "$mount_point" "${NFS_VERSION:-3}" 2>/dev/null; then
                    echo "$(date '+%Y-%m-%d %H:%M:%S') NFS: ${server_path} -> ${mount_point}" >> "$LOGFILE"
                else
                    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: NFS mount failed: ${server_path}" >> "$LOGFILE"
                fi
            fi
        done
    fi

    # GlusterFS
    if [ -x "$GFS_BIN" ] && [ -n "${NFS_SERVER:-}" ] && ! mountpoint -q /swarm/ha 2>/dev/null; then
        LD_LIBRARY_PATH=/data/glusterfs/lib "$GFS_BIN" \
            --volfile-server="${NFS_SERVER}" \
            --volfile-id=ha0 \
            --xlator-option=transport.address-family=inet \
            --log-file=/data/docker/glusterfs.log \
            /swarm/ha 2>/dev/null
        sleep 3
        if mountpoint -q /swarm/ha 2>/dev/null; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') GlusterFS: /swarm/ha mounted" >> "$LOGFILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: GlusterFS mount failed" >> "$LOGFILE"
        fi
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') Mounts complete" >> "$LOGFILE"
) &

# --- Start dockerd immediately (no WiFi dependency) --------------------------
export PATH="/data/docker/bin:${PATH}"
rm -f /data/docker/run/docker.pid

exec dockerd \
    --data-root /data/docker/lib \
    --exec-root /data/docker/run \
    --pidfile /data/docker/run/docker.pid \
    --host unix:///data/docker/run/docker.sock \
    --iptables=true \
    >> /data/docker/dockerd.log 2>&1
