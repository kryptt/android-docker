# Onboarding a New Phone as a Docker Swarm Worker

## Prerequisites

- Phone with unlocked bootloader and USB debugging enabled
- Build environment set up (`./setup.sh` has been run)
- Phone connected via USB

## What Gets Installed

| Component | On Device | Purpose |
|-----------|-----------|---------|
| Custom kernel | `boot` partition | Docker/NFS/IPVS support |
| WiFi module | `/vendor/lib/modules/` | Rebuilt to match custom kernel |
| Docker binaries | `/data/docker/bin/` | dockerd, containerd, runc, etc. |
| mount_nfs | `/data/docker/bin/mount_nfs` | NFS mount helper (toybox can't mount NFS) |
| swarm.conf | `/data/docker/swarm.conf` | Cluster config (NFS server, swarm token) |
| boot-worker.sh | `/data/docker/boot-worker.sh` | Boot script: Docker + NFS + Swarm |
| init.rc trigger | `/system/etc/init/docker-swarm.rc` | Starts boot-worker.sh on boot |

---

## Step 1: Register the Device

Add entries to three files:

**`scripts/kernel-devices.sh`** — kernel source directory:
```bash
[mydevice]="kernel/<platform>"
```

**`scripts/devices.conf`** — device registry (see file for format):
```
mydevice|<serial>|<codename>|<platform>|<fastboot-product>|<has_recovery>|<has_super>|<nfs_version>|<hostname>
```

**`setup.sh`** — kernel repo and branch in `KERNEL_REPOS` and `KERNEL_BRANCHES`.

**`build.sh`** — defconfig in `DEFCONFIGS`.

## Step 2: Build the Kernel

```bash
./setup.sh mydevice
CLANG_PATH=$(pwd)/clang/bin/clang ./build.sh mydevice
```

Verify the config was applied:
```bash
grep -E 'CONFIG_NFS_FS=|CONFIG_IP_VS=|CONFIG_OVERLAY_FS=' out/mydevice/.config
```

If the build fails on DTB errors but the Image was produced, that's OK — the
kernel binary is separate from device trees. If configs are missing, check that
`docker-swarm-nfs.config` was merged (look for the "Merging" line in build output).

Create `mydevice-fixes.config` if needed for device-specific kernel build fixes.

## Step 3: Create the Boot Image

Unpack the stock boot image to extract ramdisk and dtb:
```bash
unpack_bootimg --boot_img lineageos/<codename>/boot.img --out /tmp/boot-mydevice
```

Repack with the custom kernel:
```bash
mkbootimg \
    --kernel out/mydevice/arch/arm64/boot/Image \
    --ramdisk /tmp/boot-mydevice/ramdisk \
    --dtb /tmp/boot-mydevice/dtb \
    --header_version 2 --pagesize 4096 --base 0x0 \
    --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
    --tags_offset 0x100 --dtb_offset 0x1f00000 \
    --cmdline "<cmdline from unpack output>" \
    --output out/mydevice-boot.img
```

Use the exact cmdline and offsets from the stock image.

## Step 4: Flash

```bash
./scripts/flash-device.sh mydevice
```

This handles vbmeta, dtbo, recovery (if applicable), userdata wipe, boot image,
and LineageOS sideload. Follow the on-screen prompts.

**After sideloading**, reflash boot to the new active slot (sideload changes it):
```bash
adb reboot bootloader
fastboot flash boot out/mydevice-boot.img
fastboot reboot
```

Verify: `adb shell 'uname -r'` should show `-dirty` suffix,
and `adb shell 'cat /proc/filesystems | grep nfs'` should show `nfs`.

## Step 5: Fix WiFi

Custom kernels break the stock WiFi module (ABI mismatch). Replace it with the
module built from your kernel tree:
```bash
adb root && sleep 5
adb shell 'mount -o rw,remount /vendor'
adb push out/mydevice/drivers/staging/qcacld-3.0/wlan.ko /vendor/lib/modules/qca_cld3_wlan.ko
adb reboot
```

After reboot, verify WiFi connects: `adb shell 'ip -4 addr show wlan0'`

## Step 6: Deploy Docker + NFS + Swarm

```bash
./scripts/deploy-device.sh mydevice
```

This pushes Docker binaries, mount_nfs, swarm.conf, the boot script, and
installs the init.rc trigger. Then reboot and verify:

```bash
adb reboot
# Wait ~2 minutes
adb root && sleep 5
adb shell 'cat /data/docker/boot.log'
adb shell 'DOCKER_HOST=unix:///data/docker/run/docker.sock /data/docker/bin/docker info'
adb shell 'mount | grep "type nfs"'
```

---

## Gotchas

1. **Toybox mount can't do NFS.** That's why we need `mount_nfs` (cross-compiled
   C binary using the mount() syscall directly).

2. **Android init kills children.** The boot script must not exit while dockerd
   runs, or init kills the whole process group. It loops on `wait $DOCKERD_PID`.

3. **Root filesystem is read-only.** Boot script remounts `/` rw before creating
   NFS mount points. These don't persist — they're re-created every boot.

4. **A/B slots shift after sideload.** Always reflash boot.img after sideloading
   LineageOS (Step 4).

5. **WiFi module is ABI-coupled to the kernel.** Must replace
   `/vendor/lib/modules/qca_cld3_wlan.ko` with the one from your build output.

6. **SELinux must be permissive.** Boot script runs `setenforce 0`. Only works
   on userdebug builds. Production builds need Magisk.

7. **NFS v4 crashes 4.14 kernels.** Set `nfs_version=3` in `devices.conf` for
   older kernels. Safe to use `4` on 4.19+.

8. **`CLANG_PATH` must be absolute** in the devcontainer. Set it to
   `$(pwd)/clang/bin/clang`.

9. **`adb root` disconnects USB** for 5-15 seconds. Always `sleep 5` after it.

---

## Checklist

```
[ ] Device added to kernel-devices.sh, devices.conf, setup.sh, build.sh
[ ] Kernel built with NFS_FS, IP_VS, OVERLAY_FS confirmed in .config
[ ] Boot image repacked with custom kernel
[ ] Flashed via ./scripts/flash-device.sh
[ ] Boot reflashed to correct A/B slot after sideload
[ ] Custom kernel verified (uname -r, /proc/filesystems has nfs)
[ ] WiFi module replaced and working after reboot
[ ] Deployed via ./scripts/deploy-device.sh
[ ] Reboot test: Docker running, NFS mounted, Swarm joined
```
