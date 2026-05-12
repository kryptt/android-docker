# Plan: roll the GlusterFS host-side install to op7 / op8

Context: commit `9d332b4` added `scripts/extract-glusterfs-host-tree.sh`
plus the `deploy-device.sh --k3s` integration that ships a
self-contained GlusterFS tree to `/data/glusterfs/` on each phone.
`start-k3s.sh` already has the boot-time block that mounts `ha0` onto
`/swarm/ha` using that tree (lines roughly 110–135). When it works, the
FUSE mount lives in PID 1's mount namespace — every pod on the node
sees the same `/swarm/ha` via hostPath, just like on the amd64 nodes.

Until this plan is executed, the in-cluster `glusterfs-client`
DaemonSet (`hr-fleet/fleet/infra/glusterfs-client.yaml`, image
`0.0.11`) mounts gluster only inside its own container namespace.
That's the current state — `cec9f34` in hr-fleet.

## Pre-flight

Done already; just verify before starting:

- [ ] `docker manifest inspect registry.hr-home.xyz/glusterfs-client:0.0.11`
      shows both `amd64` and `arm64` platforms. (It does.)
- [ ] `scripts/extract-glusterfs-host-tree.sh` exists and runs to
      completion. (It does — produces a ~21 MB tree.)
- [ ] Both phones reachable via `adb`:
      ```
      adb devices
      # 2e2e5cbf      device   (op7)
      # 8e1cdcbe      device   (op8)
      ```
- [ ] `kubectl -n fleet-local get gitrepo hr-home -o jsonpath='{.status.commit}'`
      is at `cec9f34` or later. (Don't proceed if Fleet is mid-rollout
      of something else — wait for `ready=16/16` first.)

## Phase 1 — populate /data/glusterfs on op7 and op8

```
cd ~/workspace/misc/android-docker
./scripts/extract-glusterfs-host-tree.sh         # idempotent
./scripts/deploy-device.sh --k3s oneplus7pro
./scripts/deploy-device.sh --k3s oneplus8pro
```

The deploy script auto-extracts on first run; the second invocation
reuses `glusterfs-host-tree/`. Each push transfers ~21 MB. The
script also chmods `bin/glusterfs`, `bin/glusterfsd`, and
`lib/ld-linux-aarch64.so.1`.

Verify on each device, e.g. for op7:

```
adb -s 2e2e5cbf shell 'ls -la /data/glusterfs/bin/ /data/glusterfs/lib/glusterfs/10.3/xlator/mount/'
```

Should list `glusterfsd` (~278 KB), the wrapper `glusterfs`, and
`fuse.so` + `api.so` under the xlator dir.

Smoke-test the wrapper without mounting:

```
adb -s 2e2e5cbf shell '/data/glusterfs/bin/glusterfs --version'
```

Should print `glusterfs 10.3` plus the copyright. If it doesn't,
**stop** — the bundled dynamic linker / library set is broken or the
Android kernel doesn't accept some part of the ELF. Read
`/data/docker/glusterfs.log` if it exists.

## Phase 2 — restart k3s so start-k3s.sh runs the gluster block

The gluster mount block in `start-k3s.sh` runs only at agent startup.
After phase 1 you have two options:

a) Reboot the device (clean):
```
adb -s 2e2e5cbf reboot
```

b) Restart k3s-agent in place (no userspace reset):
```
adb -s 2e2e5cbf shell 'pidof k3s-agent | xargs -r kill -TERM'
# Android init's `class late_start` will respawn it.
```

`(b)` is faster but assumes the phone has been up long enough that
Android init won't trip on missing dependencies. `(a)` is the safer
default.

**Watch out for `/usr/lib/aarch64-linux-gnu` creation.** start-k3s.sh
does `mkdir -p /usr/lib/aarch64-linux-gnu /usr/sbin` and then
`ln -sf /data/glusterfs/lib/glusterfs /usr/lib/aarch64-linux-gnu/glusterfs`.
On op7 the root partition was at ~100% during this session — the
mkdir may fail. If it does, ext4 reserves blocks for root that root
can still write to, but only ~52 MB on that partition. If even
`mkdir` returns ENOSPC:

```
adb -s 2e2e5cbf shell 'df /'
# Find the worst /var/log/* or /tmp/* offenders to clear.
adb -s 2e2e5cbf shell 'du -shx /system/*'   # don't touch this, just curious
adb -s 2e2e5cbf shell 'ls /data/local/tmp /tmp 2>/dev/null'
```

If you free space and want to re-trigger the block without a reboot:
```
adb -s 2e2e5cbf shell 'pidof k3s-agent | xargs -r kill -TERM'
```

## Phase 3 — verify /swarm/ha is host-visible

From a privileged debug pod on each Android node — easiest is to run
the snippet below twice with `$NODE` swapped:

```
NODE=hr-op7   # or hr-op8
kubectl run check-$NODE --rm -i --restart=Never \
  --image=alpine:3 \
  --overrides='{"spec":{"nodeName":"'$NODE'","tolerations":[{"operator":"Exists"}],"hostPID":true,"containers":[{"name":"c","image":"alpine:3","securityContext":{"privileged":true},"command":["sh","-c","grep /swarm/ha /proc/1/mountinfo; echo ---; ls /proc/1/root/swarm/ha | head"]}]}}'
```

Expected output (op7, op8):

```
NNNN .. /swarm/ha rw,relatime shared:X - fuse.glusterfs 192.168.2.10:ha0 ...
---
bulwark
config-opnsense.hr-home.xyz-1774656589.8566.xml
eufy-security
...
```

If `/proc/1/mountinfo` is empty for `/swarm/ha`, check
`/data/docker/glusterfs.log` on the device:

```
adb -s 2e2e5cbf shell 'tail -50 /data/docker/glusterfs.log'
```

Common failures and what they actually mean:

- `xlator/mount/fuse.so: cannot open shared object file` → the symlink
  `/usr/lib/aarch64-linux-gnu/glusterfs → /data/glusterfs/lib/glusterfs`
  didn't get created. start-k3s.sh creates it, but only if `mkdir -p
  /usr/lib/aarch64-linux-gnu` succeeded first. Free disk space and
  retry.

- `failed to fetch volume file` → the device can't reach the gluster
  servers. Check ping/route from the host to
  192.168.2.{10,21,22,23}.

- `Permission denied` on `/swarm/ha/...` from inside a pod → the
  GlusterFS volume's POSIX perms are 770 root:root by default;
  workloads either need to run as root or have a matching gid. This
  is the same behaviour as on the amd64 nodes, not something this
  rollout changed.

## Phase 4 — drop the workarounds in hr-fleet

Only after Phase 3 verifies BOTH op7 and op8 cleanly.

In `~/workspace/misc/hr-fleet`:

1. `fleet/home/onlyoffice.yaml` — change

   ```yaml
   nodeSelector:
     hr-home.xyz/has-udev: "true"
   ```

   back to

   ```yaml
   nodeSelector:
     hr-home.xyz/stable: "true"
   ```

   (the comment block above it explaining the `has-udev` pin can come
   out at the same time — leave a one-line note in the commit
   message about why this is now safe).

2. Decide what to do with `fleet/infra/glusterfs-client.yaml`:

   - Option A: delete the DaemonSet entirely. start-k3s.sh now owns
     the mount on Android nodes; the amd64 nodes have a native
     `glusterfs-client` package (systemd / fstab) doing the same job.
     Cleanest.

   - Option B: keep the DS but scope it to Android nodes as a
     *fallback* for the case where start-k3s.sh's mount block fails
     at boot (e.g. NFS server hadn't come up in time). The DS would
     run a `mountpoint -q /swarm/ha || mount …` loop. More moving
     parts, but useful insurance until the host-side path is
     well-soaked.

   My vote: Option A after a week of clean uptime. Option B in the
   meantime.

3. Validate, push, watch Fleet roll:

   ```
   ./scripts/validate-manifests.sh fleet/home fleet/infra
   git add fleet/home/onlyoffice.yaml [fleet/infra/glusterfs-client.yaml]
   git commit -m 'feat(home): allow onlyoffice on Android (host-side gluster works)'
   git push origin main
   ```

4. Trigger the `onlyoffice` Sablier route (visit
   https://office-docs.hr-home.xyz/) and watch it land on op7 or op8
   via:

   ```
   kubectl -n home get pods -l app=onlyoffice -o wide
   ```

   Container should go `Init → Running` without `FailedMount`
   events.

## Rollback

If any of phases 1–3 break, the system stays in the pre-rollout
state — the in-cluster DaemonSet keeps mounting gluster inside its
own ns and `onlyoffice` keeps running on the amd64 nodes via the
`has-udev=true` pin. To explicitly back out a partial deploy:

```
adb -s 2e2e5cbf shell 'rm -rf /data/glusterfs && reboot'
```

(Don't run that on a healthy device — it's a wipe-and-retry.)

## Notes for the agent

- Don't bump the in-cluster `glusterfs-client` image version unless
  you also rerun `scripts/extract-glusterfs-host-tree.sh` and
  re-deploy via `deploy-device.sh --k3s`. The two are paired — the
  host tree is just an extraction of the in-cluster image.

- The wrapper script uses `--argv0` which requires glibc ≥ 2.33. If a
  future image bump moves to an older base (unlikely; we're on
  bookworm), the wrapper needs a different approach (e.g. an
  `exec -a` symlink dance).

- `start-k3s.sh` swallows GlusterFS errors (`2>/dev/null`). For
  debugging, temporarily edit the on-device copy at
  `/data/docker/start-k3s.sh` to remove that redirect, then restart
  the agent. Don't commit that change — the redirect is intentional
  to keep the agent log clean for normal operation.

- Memory entries that touch this area:
  `~/.claude/projects/-home-rhansen-workspace-misc-hr-fleet/memory/feedback_android_k3s_umask.md`
  (umask 0077 → 0022 fix from earlier this session, already in
  start-k3s.sh).
  `~/.claude/projects/-home-rhansen-workspace-misc-hr-fleet/memory/feedback_avoid_subpath_mounts.md`
  (subPath bind-mounts fail on Android — applied to onlyoffice and
  pgadmin already).
