#!/usr/bin/env bash
set -euo pipefail

# Build and run the kernel compilation inside Docker
IMAGE_NAME="oneplus-kernel-builder"
CONTAINER_NAME="kernel-build"

DEVICE="${1:-oneplus7pro}"
VARIANT="${2:-user}"

echo "==> Building Docker image..."
docker build -t "$IMAGE_NAME" .

echo "==> Running kernel build in container for $DEVICE..."
docker run --rm \
    --name "$CONTAINER_NAME" \
    -v "$(pwd)":/home/builder/workspace \
    -w /home/builder/workspace \
    "$IMAGE_NAME" \
    bash build.sh "$DEVICE" "$VARIANT"
