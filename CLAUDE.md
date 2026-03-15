# Android Kernel Development for OnePlus Devices

## Project Overview
Dockerized build environment for compiling and flashing custom Android kernels
targeting OnePlus devices (OnePlus 12, 13, Ace 3 Pro, etc.).

## Directory Structure
- `.devcontainer/` — Dev container config with USB passthrough for adb/fastboot
- `build.sh` — Main kernel build script (edit DEFCONFIGS for your device)
- `setup.sh` — Clones kernel source, clang toolchain, AnyKernel3
- `docker-build.sh` — Standalone Docker build wrapper (not devcontainer)
- `kernel/source/` — Kernel source tree (cloned by setup.sh, gitignored)
- `clang/` — Toolchain (cloned by setup.sh, gitignored)
- `AnyKernel3/` — Flashable zip packager (cloned by setup.sh, gitignored)
- `out/` — Build output directory (gitignored)

## Safety Rules for Agents
- **NEVER run `fastboot flash` or `fastboot oem` commands without explicit user confirmation**
- **NEVER run `adb reboot bootloader` or `adb reboot edl` without explicit user confirmation**
- **NEVER wipe/erase partitions** — these are destructive and irreversible on-device
- Prefer `fastboot boot <image>` (temporary boot) over `fastboot flash` when testing
- Always verify device state with `adb devices` or `fastboot devices` before operations
- Always check battery level (`adb shell dumpsys battery`) before flashing — must be >50%
- Build operations (make, build.sh) are safe to run freely
- Use `adb shell` read-only commands freely for device inspection

## Build Commands
```bash
./setup.sh                    # First-time: clone sources + toolchain
./build.sh oneplus12          # Build kernel for OnePlus 12
./build.sh oneplus13          # Build kernel for OnePlus 13
```

## Device Interaction
```bash
adb devices                   # List connected devices
fastboot devices              # List devices in bootloader mode
adb shell getprop ro.product.model  # Check device model
```
