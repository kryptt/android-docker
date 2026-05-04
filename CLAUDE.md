# Android Docker Swarm Cluster

## Project Overview
Build environment for turning Android phones into Docker Swarm worker nodes with
persistent NFS mounts. Custom kernels add Docker/Swarm/NFS/VLAN support that stock
Android kernels lack. The phones auto-start Docker, mount NFS shares, and join
the swarm on every boot. The cluster is planned to migrate from Docker Swarm to k3s.

## Devices
| Serial | Model | OS | Kernel | Codename | Platform | Status |
|--------|-------|-----|--------|----------|----------|--------|
| 2e2e5cbf | OnePlus 7 Pro (GM1911) | LineageOS 23.2 | 4.14.356 (custom) | guacamole | SM8150 | Working (Docker + NFS) |
| 8e1cdcbe | OnePlus 8 Pro (IN2023) | LineageOS 23.2 | 4.19.325 (custom) | instantnoodlep | SM8250 | Working (Docker + NFS) |
| 8e81497e | OnePlus 10 Pro (NE2213) | LineageOS 23.0 (unofficial) | 5.10.239 (stock) | wly | SM8450 | NFS only (no Docker) |

**OnePlus 10 Pro limitations:** GKI kernel ABI constraints prevent enabling CGROUP_PIDS
(required by container runtimes). Qualcomm HypX blocks KVM at EL2 (no VM workaround).
See `feedback_gki_vendor_dlkm.md` in memory for full details.

See `scripts/devices.conf` for serial numbers, codenames, and feature flags.

## Network
Network config (NFS server, swarm manager, join token, mount paths) is in `.envrc`
(gitignored). Copy `.envrc.example` to `.envrc` and fill in your values.
The deploy script pushes these secrets to each device as `/data/docker/swarm.env`.

## Directory Structure
```
.devcontainer/          Dev container config with USB passthrough
build.sh                Main kernel build script (merges docker-swarm-nfs.config)
setup.sh                Clones kernel sources + clang toolchain + AnyKernel3
docker-swarm-nfs.config Kernel config fragment: Docker/Swarm/iptables/NFS/IPVS/VLAN
oneplus7pro-fixes.config  Device-specific: disables NFS v4 (boot failure on 4.14)
oneplus10pro-fixes.config Device-specific: disables oplus sensor + MODVERSIONS
tools/mkbootimg-aosp/   AOSP mkbootimg for creating boot.img (header v2/v4)
kernel/sm8150/          OnePlus 7 Pro kernel source (LineageOS lineage-23.2)
kernel/sm8250/          OnePlus 8 Pro kernel source (LineageOS lineage-23.2)
kernel/sm8450/          OnePlus 10 Pro kernel source (LineageOS lineage-22.2)
clang/                  Android clang toolchain (gitignored, cloned by setup.sh)
AnyKernel3/             Flashable zip packager (gitignored)
out/                    Build output: kernel images + boot.img files (gitignored)
lineageos/              LineageOS flash images per codename (gitignored)
docker-binaries/        Docker static aarch64 binaries (gitignored)
tools/                  Host-side utilities (mount_nfs.c source)
scripts/                Per-device flash, deploy, and boot scripts
```

## Scripts
| Script | Purpose |
|--------|---------|
| `scripts/flash-device.sh <device>` | Interactive clean flash: wipe + LineageOS + custom kernel |
| `scripts/deploy-device.sh <device>` | Push Docker binaries + boot script to device via adb |
| `scripts/docker-swarm-boot.sh` | On-device boot script (Docker + NFS + Swarm) — shared by all devices |
| `scripts/devices.conf` | Device registry (serial, codename, platform, features) |
| `scripts/swarm.conf` | Cluster config (timeouts, paths); secrets loaded from `.envrc`/`swarm.env` |
| `.envrc` / `.envrc.example` | Network secrets: NFS server, swarm token, manager IP (gitignored) |
| `scripts/kernel-devices.sh` | Device -> kernel source directory mapping (shared by build.sh/setup.sh) |
| `tools/mount_nfs.c` | NFS mount helper source (Android toybox can't mount NFS) |

## Safety Rules for Agents
- **NEVER run `fastboot flash` or `fastboot oem` commands without explicit user confirmation**
- **NEVER run `adb reboot bootloader` or `adb reboot edl` without explicit user confirmation**
- **NEVER wipe/erase partitions** -- these are destructive and irreversible on-device
- Prefer `fastboot boot <image>` (temporary boot) over `fastboot flash` when testing
- Always verify device state with `adb devices` or `fastboot devices` before operations
- Always check battery level (`adb shell dumpsys battery`) before flashing -- must be >50%
- Build operations (make, build.sh) are safe to run freely
- Use `adb shell` read-only commands freely for device inspection

## Build Commands
```bash
./setup.sh                    # First-time: clone sources + toolchain
CLANG_PATH=$(pwd)/clang/bin/clang ./build.sh oneplus7pro
CLANG_PATH=$(pwd)/clang/bin/clang ./build.sh oneplus8pro
CLANG_PATH=$(pwd)/clang/bin/clang ./build.sh oneplus10pro
```
Note: `CLANG_PATH` must be set to the absolute path. The default `clang` won't be
found in PATH inside the devcontainer.

## Device Interaction
```bash
adb devices                   # List connected devices
fastboot devices              # List devices in bootloader mode
adb -s <serial> shell         # Shell into specific device
adb -s <serial> root          # Restart adbd as root (LineageOS userdebug)
```
