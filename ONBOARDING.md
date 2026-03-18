# Onboarding a New Phone as a Docker Swarm Worker

## Prerequisites

- Phone with unlocked bootloader and USB debugging enabled
- Build environment set up (`./setup.sh` has been run)
- Phone connected via USB

## What Gets Installed

| Component | On Device | Purpose |
|-----------|-----------|---------|
| Custom kernel | `boot` partition | Docker/NFS support (IPVS on non-GKI only) |
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

**SM8150/SM8250 (OnePlus 7 Pro, 8 Pro):**
```bash
./setup.sh mydevice
CLANG_PATH=$(pwd)/clang/bin/clang ./build.sh mydevice
```

Verify the config was applied:
```bash
grep -E 'CONFIG_NFS_FS=|CONFIG_IP_VS=|CONFIG_OVERLAY_FS=' out/mydevice/.config
```

**SM8450 GKI (OnePlus 10 Pro) — requires stock config base:**

GKI kernels cannot use `build.sh` directly — the stock config must be used as the
base to preserve LTO/CFI and GKI module ABI compatibility. The `docker-swarm-nfs.config`
fragment is too aggressive for GKI; many configs break vendor module loading.

```bash
./setup.sh oneplus10pro
export PATH="$(pwd)/clang/bin:$PATH"
mkdir -p out/oneplus10pro

# Extract running kernel's config as base (boot stock kernel first)
adb root && sleep 5
adb shell 'zcat /proc/config.gz' > out/oneplus10pro/.config

# Merge ONLY the GKI-safe Docker/NFS fragment
kernel/sm8450/scripts/kconfig/merge_config.sh -m -O out/oneplus10pro \
    out/oneplus10pro/.config oneplus10pro-docker.config oneplus10pro-fixes.config

# Resolve with LLVM_IAS=1 (required for LTO/CFI)
make -C kernel/sm8450 O="$(pwd)/out/oneplus10pro" \
    ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1 olddefconfig

# Build
make -C kernel/sm8450 O="$(pwd)/out/oneplus10pro" \
    ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 LLVM_IAS=1 -j$(nproc)
```

Verify: `CONFIG_LTO_CLANG_FULL=y`, `CONFIG_CFI_CLANG=y`, `CONFIG_NFS_FS=y` must
all be set. If LTO/CFI are missing, you forgot `LLVM_IAS=1`.

Create `mydevice-fixes.config` if needed for device-specific kernel build fixes.

## Step 3: Create the Boot Image

The system `unpack_bootimg` is too old for GKI (header v3/v4) images. Use AOSP's:
```bash
git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg /tmp/mkbootimg-aosp
```

Unpack the stock boot image to extract ramdisk (and dtb on older devices):
```bash
python3 /tmp/mkbootimg-aosp/unpack_bootimg.py \
    --boot_img lineageos/<codename>/boot.img --out /tmp/boot-mydevice
```

Check `boot image header version` in the output and repack accordingly:

**Header v2 (SM8150/SM8250 — OnePlus 7 Pro, 8 Pro):**
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

**Header v4 (SM8450+ GKI — OnePlus 10 Pro):**
```bash
python3 /tmp/mkbootimg-aosp/mkbootimg.py \
    --kernel out/mydevice/arch/arm64/boot/Image \
    --ramdisk /tmp/boot-mydevice/ramdisk \
    --header_version 4 \
    --os_version <from unpack> --os_patch_level <from unpack> \
    --output out/mydevice-boot.img
```

GKI header v4 has no DTB or cmdline in boot.img — those live in `vendor_boot.img`.

## Step 4: Flash

**SM8150/SM8250 (uses `flash-device.sh` + sideload):**
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

**SM8450 GKI (uses fastbootd + payload extraction):**

The `flash-device.sh` script doesn't work for GKI devices because the recovery
image from the unofficial LineageOS build doesn't boot. Instead, extract all
partitions from the OTA payload and flash via fastbootd:

```bash
# Extract partitions from LineageOS OTA zip
pip3 install payload_dumper
unzip lineageos/wly/lineage-*.zip payload.bin -d /tmp
payload_dumper --out /tmp/lineage-images /tmp/payload.bin

# Flash from fastboot: vbmeta + dtbo + boot (stock) first
adb reboot bootloader
fastboot flash vbmeta lineageos/wly/vbmeta.img
fastboot flash dtbo lineageos/wly/dtbo.img
fastboot flash recovery lineageos/wly/recovery.img
fastboot flash vendor_boot lineageos/wly/vendor_boot.img
fastboot flash boot lineageos/wly/boot.img   # stock boot for fastbootd
fastboot -w                                    # wipe userdata
fastboot wipe-super lineageos/wly/super_empty.img

# Enter fastbootd (userspace fastboot) for dynamic partitions
fastboot reboot fastboot

# Flash all dynamic partitions
fastboot flash system /tmp/lineage-images/system.img
fastboot flash system_ext /tmp/lineage-images/system_ext.img
fastboot flash product /tmp/lineage-images/product.img
fastboot flash vendor /tmp/lineage-images/vendor.img
fastboot flash odm /tmp/lineage-images/odm.img
fastboot flash vendor_dlkm /tmp/lineage-images/vendor_dlkm.img

# Flash custom kernel boot.img and reboot
fastboot flash boot out/oneplus10pro-boot.img
fastboot reboot
```

**Critical:** You must flash ALL dynamic partitions including `odm.img` and
`vendor_dlkm.img` — missing these causes boot failure.

Verify: `adb shell 'uname -r'` should show custom version,
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

### All devices

1. **Toybox mount can't do NFS.** That's why we need `mount_nfs` (cross-compiled
   C binary using the mount() syscall directly).

2. **Android init kills children.** The boot script must not exit while dockerd
   runs, or init kills the whole process group. It loops on `wait $DOCKERD_PID`.

3. **A/B slots shift after sideload.** Always reflash boot.img after sideloading
   LineageOS (Step 4).

4. **WiFi module is ABI-coupled to the kernel.** Must replace
   `/vendor/lib/modules/qca_cld3_wlan.ko` with the one from your build output.

5. **`CLANG_PATH` must be absolute** in the devcontainer. Set it to
   `$(pwd)/clang/bin/clang`.

### GKI devices (SM8450+ / OnePlus 10 Pro)

6. **GKI kernel configs that change core struct layouts cause bootloops.**
   `vendor_dlkm` modules are compiled against the stock kernel ABI. Enabling
   configs like `BRIDGE_NETFILTER` (changes `sk_buff`), `IPVLAN` (changes
   `net_device`), `IP_VS`, `CGROUP_PIDS`, or `USER_NS` breaks module CRC
   checksums and the phone won't boot. Use `oneplus10pro-docker.config` instead
   of `docker-swarm-nfs.config` — it contains only GKI-safe configs.

7. **GKI builds require `LLVM_IAS=1`** in make args. Without it, `HAS_LTO_CLANG`
   fails its dependency check and LTO/CFI are silently disabled. Vendor modules
   built with CFI won't load on a non-CFI kernel.

8. **GKI boot images use header v4** — no DTB, no cmdline (both live in
   `vendor_boot.img`). The system `unpack_bootimg` is too old; use the AOSP
   version from `platform/system/tools/mkbootimg`.

9. **Must flash ALL dynamic partitions** including `odm.img` and `vendor_dlkm.img`
   when installing LineageOS via fastbootd. Missing either causes boot failure.

10. **Kernel source must match the ROM.** The OnePlus 10 Pro ROM uses
    `pjgowtham/android_kernel_oneplus_sm8450` branch `lineage-23.0`, NOT the
    upstream `LineageOS/android_kernel_oneplus_sm8450` on `lineage-22.2`.
    Version mismatch causes boot failure.

---

## Checklist

### All devices
```
[ ] Device added to kernel-devices.sh, devices.conf, setup.sh, build.sh
[ ] Kernel built with NFS_FS, OVERLAY_FS confirmed in .config
[ ] Boot image repacked with custom kernel (correct header version)
[ ] Custom kernel verified (uname -r, /proc/filesystems has nfs)
[ ] WiFi working after reboot
[ ] Deployed via ./scripts/deploy-device.sh
[ ] Reboot test: Docker running, NFS mounted, Swarm joined
```

### GKI devices (SM8450+) — additional checks
```
[ ] Used stock /proc/config.gz as base (NOT build.sh defconfigs)
[ ] Used oneplus10pro-docker.config (NOT docker-swarm-nfs.config)
[ ] LTO_CLANG_FULL=y and CFI_CLANG=y in .config
[ ] Built with LLVM=1 LLVM_IAS=1
[ ] Used AOSP mkbootimg.py with --header_version 4
[ ] Flashed ALL dynamic partitions via fastbootd (including odm + vendor_dlkm)
[ ] WiFi configured manually in Settings after first boot
```
