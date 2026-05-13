#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Extract a self-contained GlusterFS install from the hr-fleet container
# image into a directory tree that deploy-device.sh pushes verbatim to
# /data/glusterfs/ on each Android host. start-k3s.sh's existing
# host-side mount block then has the binaries + libs it needs.
#
# Why: glusterfs is dynamically linked against glibc + several libs and
# dlopens its translators from a build-time-hardcoded path (
# /usr/lib/<arch>-linux-gnu/glusterfs/<ver>/xlator/...). The Android
# host has neither glibc nor /usr, so we ship the entire dependency
# chain alongside the binary and use a wrapper script that invokes the
# bundled dynamic linker explicitly so the kernel doesn't try to
# resolve the ELF INTERP path (/lib/ld-linux-aarch64.so.1) on host.
#
# Usage:
#     scripts/extract-glusterfs-host-tree.sh [IMAGE]
#         IMAGE  default: registry.hr-home.xyz/glusterfs-client:0.0.11
#
# Output: <repo>/glusterfs-host-tree/ (gitignored) containing:
#     bin/glusterfs      # wrapper script invoked by start-k3s.sh
#     bin/glusterfsd     # the real binary
#     lib/ld-linux-aarch64.so.1
#     lib/lib<deps>.so.* # ldd-resolved transitive deps
#     lib/glusterfs/<v>/xlator/{mount,performance,protocol,...}/*.so
# ==============================================================================

IMAGE="${1:-registry.hr-home.xyz/glusterfs-client:0.0.11}"
PLATFORM=linux/arm64
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/glusterfs-host-tree"

echo "==> Pulling $IMAGE ($PLATFORM)..."
docker pull --platform="$PLATFORM" "$IMAGE" >/dev/null

echo "==> Creating staging container..."
CID=$(docker create --platform="$PLATFORM" "$IMAGE")
trap 'docker rm -v "$CID" >/dev/null 2>&1 || true' EXIT

# Determine arch dir inside the image (aarch64-linux-gnu on arm64).
ARCH_DIR=$(docker run --rm --platform="$PLATFORM" --entrypoint sh "$IMAGE" -c \
    'ls /usr/lib | grep -E "^(aarch64|arm)-linux-gnu$" | head -n1')
echo "    image arch dir: $ARCH_DIR"

# Discover all shared-library dependencies of the real binary AND every
# xlator .so under /usr/lib/<arch>/glusterfs/. ldd on glusterfsd alone
# only sees DT_NEEDED of the binary itself — it doesn't follow the
# dlopen chain into xlators (rpc-transport/socket.so pulls libssl, the
# performance xlators pull libaio, etc.). Without walking those, the
# bundled tree was missing ~12 libs and the host mount died with
# "Transport endpoint is not connected".
echo "==> Resolving library dependencies (binary + every xlator)..."
DEPS=$(docker run --rm --platform="$PLATFORM" --entrypoint sh "$IMAGE" -c "
    set -e
    targets=\$(find /usr/lib/$ARCH_DIR/glusterfs -name '*.so' -type f)
    targets=\"\$targets /usr/sbin/glusterfsd\"
    for t in \$targets; do
        ldd \"\$t\" 2>/dev/null | awk '/=>/ {print \$3}' | grep -v '^(' || true
    done | sort -u
")

echo "==> Staging tree at $OUT_DIR..."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/bin" "$OUT_DIR/lib"

# Real binary
docker cp "$CID:/usr/sbin/glusterfsd" "$OUT_DIR/bin/glusterfsd"

# Dynamic linker — the binary's ELF INTERP path; the wrapper calls it
# explicitly so the kernel doesn't look for /lib/ld-linux-* on host.
docker cp "$CID:/lib/$ARCH_DIR/ld-linux-aarch64.so.1" "$OUT_DIR/lib/" 2>/dev/null \
    || docker cp "$CID:/usr/lib/$ARCH_DIR/ld-linux-aarch64.so.1" "$OUT_DIR/lib/"

# Every transitive shared library.
#
# `docker cp` without -L preserves symlinks verbatim. In Debian-based
# images the paths `ldd` reports are sonames like `libtirpc.so.3` that
# are themselves symlinks to versioned reals like `libtirpc.so.3.0.0`.
# Without -L we ship the soname symlink and orphan the target, so the
# bundled ld-linux can't open libtirpc.so.3 on the device. -L follows
# the symlink and writes the real ELF under the soname name, which is
# what DT_NEEDED in glusterfsd resolves against directly.
for lib in $DEPS; do
    base=$(basename "$lib")
    if [[ ! -f "$OUT_DIR/lib/$base" ]]; then
        docker cp -L "$CID:$lib" "$OUT_DIR/lib/$base"
    fi
done

# xlator tree. glusterfs uses dlopen with a path hardcoded to
# /usr/lib/<arch>-linux-gnu/glusterfs/<ver>/xlator/ at build time, so
# start-k3s.sh symlinks /usr/lib/aarch64-linux-gnu/glusterfs to
# /data/glusterfs/lib/glusterfs to keep that path resolvable.
docker cp "$CID:/usr/lib/$ARCH_DIR/glusterfs" "$OUT_DIR/lib/glusterfs"

# Wrapper. start-k3s.sh invokes /data/glusterfs/bin/glusterfs as the
# entry point. We can't just symlink to glusterfsd because the kernel
# would try to load the binary's hardcoded INTERP (/lib/ld-linux-*)
# from the host's mount ns where it doesn't exist. The wrapper sets
# the right paths and uses ld.so's --argv0 so the binary still
# self-identifies as `glusterfs` (which selects FUSE-client mode vs
# server mode based on argv[0]). --argv0 requires glibc >= 2.33;
# bookworm ships 2.36.
cat > "$OUT_DIR/bin/glusterfs" <<'WRAPPER'
#!/system/bin/sh
# Auto-generated by android-docker/scripts/extract-glusterfs-host-tree.sh
# Bundled dynamic linker invocation so the Android host doesn't need
# /lib/ld-linux-aarch64.so.1 or a system glibc.
HERE=$(cd "$(dirname "$0")" && pwd)
LIBDIR="$HERE/../lib"
exec "$LIBDIR/ld-linux-aarch64.so.1" \
    --library-path "$LIBDIR" \
    --argv0 "$(basename "$0")" \
    "$HERE/glusterfsd" "$@"
WRAPPER
chmod +x "$OUT_DIR/bin/glusterfs"

# Sanity manifest — surfaces size + version so the deploy script can
# spot mismatched builds at a glance.
SIZE=$(du -sh "$OUT_DIR" | awk '{print $1}')
VER=$(docker run --rm --platform="$PLATFORM" --entrypoint sh "$IMAGE" -c \
    'glusterfs --version 2>&1 | head -n1')

cat > "$OUT_DIR/MANIFEST" <<MANIFEST
image:    $IMAGE
platform: $PLATFORM
arch_dir: $ARCH_DIR
version:  $VER
size:     $SIZE
files:
$(cd "$OUT_DIR" && find . -type f -o -type l | sort | sed 's|^|    |')
MANIFEST

echo
echo "==> Wrote $OUT_DIR ($SIZE)"
echo "    Version: $VER"
echo "    Run 'scripts/deploy-device.sh --k3s <device>' to push it."
