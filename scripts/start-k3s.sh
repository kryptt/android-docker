#!/system/bin/sh
# ==============================================================================
# K3s agent starter — runs as Android init service
# ==============================================================================
# init keeps this process alive (restarts on crash).
# The shell exec's into k3s agent so init tracks the k3s process directly.
#
# Unlike start-dockerd.sh which mounts NFS in the background, this script
# mounts NFS synchronously before starting k3s — pods with NFS-backed
# volumes need mounts ready at schedule time.
#
# Networking: phones use their WiFi IPs as k3s node IPs. Flannel
# VXLAN+DirectRouting tunnels pod traffic to Gentoo nodes on VLAN 20.
# ==============================================================================

LOGFILE="/data/docker/k3s-agent.log"
K3S_BIN="/data/docker/bin/k3s"
K3S_CONFIG="/data/docker/k3s-config.yaml"
MOUNT_NFS="/data/docker/bin/mount_nfs"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

log "========== K3S AGENT START =========="

# --- umask --------------------------------------------------------------------
# Android init's `seclabel u:r:su:s0` services start with umask 077, which
# makes containerd create every snapshot's `fs/` directory as drwx------
# (0700). The merged overlay rootfs is then 0700, so any container running
# as a non-root user (Fleet's gitcloner-initializer at uid=1000, for one)
# can't traverse `/` and fails with "exec: foo: file not found in $PATH"
# or "shared library: Permission denied". Setting umask 022 here is
# inherited by k3s-agent → containerd → all snapshots.
umask 022

# --- Wireless ADB -------------------------------------------------------------
# Make adbd listen on TCP 5555 so the host devcontainer can `adb connect
# <node-ip>:5555` over VLAN 10 without USB. Idempotent: setprop+restart is a
# no-op if adbd is already listening on the same port.
setprop service.adb.tcp.port 5555 2>/dev/null
stop adbd 2>/dev/null
start adbd 2>/dev/null

# --- SELinux & filesystem -----------------------------------------------------
setenforce 0
mount -o rw,remount / 2>/dev/null

# --- Load config --------------------------------------------------------------
. /data/docker/swarm.conf 2>/dev/null
. /data/docker/swarm.env 2>/dev/null

# --- DNS + TLS certs ----------------------------------------------------------
echo "nameserver 192.168.2.254" > /etc/resolv.conf 2>/dev/null
echo "nameserver 8.8.4.4" >> /etc/resolv.conf 2>/dev/null
if [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
    mkdir -p /etc/ssl/certs
    cat /system/etc/security/cacerts/*.0 > /etc/ssl/certs/ca-certificates.crt 2>/dev/null
fi

# --- Standard path setup ------------------------------------------------------
mkdir -p /var/lib /run/lock /run/containerd /var/empty /var/log /tmp
[ -L /var/run ] || ln -sf /run /var/run 2>/dev/null

# POSIX zoneinfo — Android ships only /system/usr/share/zoneinfo/{tzdata,tz_version}
# (binary ICU format), but kube-state-metrics and other Go binaries need the
# standard IANA directory tree. deploy-device.sh pushes it to /data/docker/zoneinfo/.
if [ -d /data/docker/zoneinfo ] && [ ! -e /usr/share/zoneinfo/America ]; then
    mkdir -p /usr/share
    ln -sfn /data/docker/zoneinfo /usr/share/zoneinfo 2>/dev/null
    log "zoneinfo: /usr/share/zoneinfo -> /data/docker/zoneinfo"
fi

# k3s extracts ~65MB of embedded binaries to /var/lib/rancher/k3s/data/ which
# is on the root partition (~50MB free). Symlink to /data (164GB+ free).
mkdir -p /data/docker/k3s-data/rancher
[ -L /var/lib/rancher ] || ln -sf /data/docker/k3s-data/rancher /var/lib/rancher 2>/dev/null

# /run/k3s, /var/lib/{kubelet,cni}, and /var/log/pods all grow fast and live
# on Android's tiny rootfs (1GB, ~16MB free after boot). Redirect them to
# /data (162GB free) BEFORE k3s starts.
for pair in \
    "/run/k3s:/data/docker/k3s-run" \
    "/run/containerd:/data/docker/k3s-run-containerd" \
    "/var/lib/kubelet:/data/docker/k3s-kubelet" \
    "/var/lib/cni:/data/docker/k3s-cni" \
    "/var/log/pods:/data/docker/k3s-log-pods" \
    "/var/log/containers:/data/docker/k3s-log-containers"; do
    target="${pair#*:}"
    link="${pair%:*}"
    parent_dir="${link%/*}"
    [ -d "$parent_dir" ] || mkdir -p "$parent_dir"
    # Ensure target dir exists even if link already does (target can be wiped
    # while symlink survives across reboots, leaving containerd unable to mkdir).
    mkdir -p "$target"
    if [ ! -L "$link" ]; then
        rm -rf "$link" 2>/dev/null
        ln -sfn "$target" "$link"
    fi
done

# --- Networking — clear Android firewall chains -------------------------------
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
echo 1 > /proc/sys/net/ipv4/conf/all/forwarding 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null

# Flush all Android FORWARD sub-chains (they default-DROP and block container traffic)
for chain in tetherctrl_FORWARD oem_fwd fw_FORWARD bw_FORWARD natctrl_FORWARD; do
    iptables -F "$chain" 2>/dev/null
    ip6tables -F "$chain" 2>/dev/null
done

# Set FORWARD policy to ACCEPT — kube-proxy will manage its own rules
iptables -P FORWARD ACCEPT 2>/dev/null
ip6tables -P FORWARD ACCEPT 2>/dev/null

# Bridge netfilter — required for kube-proxy to apply iptables to bridged traffic
if [ -d /proc/sys/net/bridge ]; then
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null
    echo 1 > /proc/sys/net/bridge/bridge-nf-call-ip6tables 2>/dev/null
fi

# --- Policy routing -----------------------------------------------------------
# Android never looks up the "main" routing table where k3s adds pod/service
# routes. Without these rules, pod and service traffic gets routed out wlan0.
# Subnets:
#   10.10.0.0/24 — control plane (API server)
#   10.20.0.0/24 — pod-network underlay (dual-IP secondary on wlan0)
#   10.42.0.0/16 — pod CIDRs (Flannel)
#   10.43.0.0/16 — service CIDR (kube-proxy)
for subnet in 10.10.0.0/24 10.20.0.0/24 10.42.0.0/16 10.43.0.0/16; do
    ip rule add to "$subnet" lookup main prio 9000 2>/dev/null
    ip rule add from "$subnet" lookup main prio 9000 2>/dev/null
done

# --- Cgroups — keep /sys/fs/cgroup as Android's cgroup2, add v1 controllers --
# DO NOT shadow /sys/fs/cgroup with tmpfs. That breaks libprocessgroup, which
# Android's Zygote uses when forking SystemServer — Zygote aborts and the
# phone bootloops (confirmed on OP8 Pro / SM8250 / kernel 4.19, 2026-05-03).
#
# DO NOT mount v1 controllers under /sys/fs/cgroup. With the cpuset/cpu v2
# backports in our patched kernels and the modified /system/etc/cgroups.json,
# Android's init already exposes cpu/cpuset/io/memory/pids in cgroup v2.
# A v1 mount loop here would *steal* those controllers back to v1 on 4.14
# (4.14 allows the promotion silently), making k3s fatal with
# "failed to find cpu cgroup (v2)". 4.19 happens to reject the v1 mount but
# we don't rely on that — just skip v1 entirely.
log "Cgroups v2 root: $(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)"

# --- Hostname -----------------------------------------------------------------
[ -n "${DEVICE_HOSTNAME:-}" ] && hostname "$DEVICE_HOSTNAME" 2>/dev/null

# --- Wait for WiFi (synchronous) ---------------------------------------------
log "Waiting for WiFi..."
WIFI_WAIT=0
while [ $WIFI_WAIT -lt "${WIFI_WAIT_MAX:-120}" ]; do
    WIFI_IP=$(ip -4 addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    [ -n "$WIFI_IP" ] && break
    sleep 2
    WIFI_WAIT=$((WIFI_WAIT + 2))
done

if [ -z "$WIFI_IP" ]; then
    log "ERROR: WiFi not connected after ${WIFI_WAIT_MAX:-120}s"
    exit 1
fi
log "WiFi: $WIFI_IP"

# --- Secondary IP for k3s node-ip (dual-IP scheme) ----------------------------
# The phone gets a second IP on wlan0 in the cluster's pod-network subnet
# (e.g. 10.20.0.24/32). That IP — not the WiFi IP — is k3s's --node-ip, so
# Flannel host-gw nexthops on Gentoo nodes are routable via static routes
# (one per phone, on each Gentoo node).
if [ -n "${K3S_NODE_IP:-}" ]; then
    ip addr replace "${K3S_NODE_IP}/32" dev wlan0 2>/dev/null
    log "Secondary IP: ${K3S_NODE_IP} on wlan0"
fi

# --- Default route ------------------------------------------------------------
# Android keeps the default route in the per-interface wlan0 table, not main.
# k3s/Flannel/kube-proxy add routes to main, so we need the default route there.
GATEWAY=$(ip route show table wlan0 | grep "default via" | head -1 | awk '{print $3}')
if [ -n "$GATEWAY" ]; then
    ip route replace default via "$GATEWAY" dev wlan0 table main 2>/dev/null
    log "Default route: via $GATEWAY"
fi

# Source IP override for cluster routes: when K3S_NODE_IP is set, all traffic
# the phone originates toward the cluster (control plane + pod traffic) uses
# the secondary IP as source so it presents one consistent identity.
if [ -n "${K3S_NODE_IP:-}" ]; then
    SRC_OPT="src ${K3S_NODE_IP}"
else
    SRC_OPT=""
fi

# Routes to every k3s cluster node — one entry per node, both VLAN 10 and
# VLAN 20 IPs reachable via the node's WiFi address.
#
# Why both: every node has a VLAN 10 (`--node-ip`) and a VLAN 20 IP. Pod-
# originated traffic on a Gentoo node arrives at the phone with src=VLAN10
# (because that's what the host route sets; SNAT on the Gentoo side picks
# the egress interface's primary). Without an explicit /32 route here the
# phone falls back to its default gateway and the reply is black-holed.
# Splitting "managers" (VLAN 10) and "nodes" (VLAN 20) used to mask this:
# control-plane nodes were in K3S_MANAGER_*, agents weren't, so any
# non-manager VLAN-10 IP had no return path from the phone.
#
# Format: K3S_NODE_N="vlan10_ip:vlan20_ip:wifi_ip"
for var in "${K3S_NODE_1:-}" "${K3S_NODE_2:-}" "${K3S_NODE_3:-}" "${K3S_NODE_4:-}"; do
    [ -z "$var" ] && continue
    vlan10_ip="${var%%:*}"
    rest="${var#*:}"
    vlan20_ip="${rest%%:*}"
    wifi_ip="${rest#*:}"
    ip route replace "${vlan10_ip}/32" via "$wifi_ip" dev wlan0 $SRC_OPT table main 2>/dev/null
    ip route replace "${vlan20_ip}/32" via "$wifi_ip" dev wlan0 $SRC_OPT table main 2>/dev/null
    log "Cluster node route: $vlan10_ip, $vlan20_ip via $wifi_ip ${SRC_OPT}"
done

# --- NFS mounts (synchronous — block until ready) -----------------------------
if [ -n "${NFS_SERVER:-}" ] && [ -x "$MOUNT_NFS" ]; then
    log "Waiting for NFS server ${NFS_SERVER}..."
    NFS_WAIT=0
    while [ $NFS_WAIT -lt 60 ]; do
        ping -c 1 -W 2 "$NFS_SERVER" > /dev/null 2>&1 && break
        sleep 2
        NFS_WAIT=$((NFS_WAIT + 2))
    done

    if ping -c 1 -W 2 "$NFS_SERVER" > /dev/null 2>&1; then
        echo "$NFS_MOUNTS" | while IFS=: read -r server_path mount_point; do
            [ -z "$server_path" ] && continue
            mkdir -p "$mount_point"
            if ! mountpoint -q "$mount_point" 2>/dev/null; then
                if "$MOUNT_NFS" "${NFS_SERVER}:${server_path}" "$mount_point" "${NFS_VERSION:-3}" 2>/dev/null; then
                    log "NFS: ${server_path} -> ${mount_point}"
                else
                    log "ERROR: NFS mount failed: ${server_path}"
                fi
            fi
        done
    else
        log "WARNING: NFS server unreachable after 60s, starting k3s without mounts"
    fi
fi

# --- GlusterFS (optional) ----------------------------------------------------
GFS_BIN=/data/glusterfs/bin/glusterfs
if [ -x "$GFS_BIN" ] && [ -n "${NFS_SERVER:-}" ]; then
    mkdir -p /swarm/ha /var/log/glusterfs /var/lib/glusterd
    mkdir -p /usr/lib/aarch64-linux-gnu /usr/sbin
    [ -L /usr/lib/aarch64-linux-gnu/glusterfs ] || \
        ln -sf /data/glusterfs/lib/glusterfs /usr/lib/aarch64-linux-gnu/glusterfs 2>/dev/null
    [ -L /usr/sbin/glusterfs ] || \
        ln -sf /data/glusterfs/bin/glusterfs /usr/sbin/glusterfs 2>/dev/null

    if ! mountpoint -q /swarm/ha 2>/dev/null; then
        LD_LIBRARY_PATH=/data/glusterfs/lib "$GFS_BIN" \
            --volfile-server="${NFS_SERVER}" \
            --volfile-id=ha0 \
            --xlator-option=transport.address-family=inet \
            --log-file=/data/docker/glusterfs.log \
            /swarm/ha 2>/dev/null
        sleep 3
        if mountpoint -q /swarm/ha 2>/dev/null; then
            log "GlusterFS: /swarm/ha mounted"
        else
            log "WARNING: GlusterFS mount failed"
        fi
    fi
fi

# --- mount binary override ----------------------------------------------------
# Android's /system/bin/mount is toybox, which can't handle the two-arg
# "bind,remount" form kubelet uses for subPath mounts. k3s bundles a busybox
# mount that works. Symlink it into /data/docker/bin so it's found first.
K3S_CURRENT=$(readlink -f /var/lib/rancher/k3s/data/current 2>/dev/null)
if [ -n "$K3S_CURRENT" ] && [ -f "$K3S_CURRENT/bin/busybox" ]; then
    ln -sf "$K3S_CURRENT/bin/busybox" /data/docker/bin/mount
    log "mount: busybox override -> $K3S_CURRENT/bin/busybox"
fi

# --- Start k3s agent ----------------------------------------------------------
log "Starting k3s agent (WiFi IP: $WIFI_IP)"

export PATH="/data/docker/bin:${PATH}"

exec "$K3S_BIN" agent \
    --config "$K3S_CONFIG" \
    >> "$LOGFILE" 2>&1
