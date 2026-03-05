#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-amd64}"
DEBIAN_IMAGE="${2:-debian:bookworm-slim}"

TIER1="bash python3 python3-pip python3-venv coreutils grep sed"
TIER2="findutils curl wget git tar unzip jq gawk ca-certificates"

echo "Building rootfs for architecture: ${ARCH}"

# Pull image for target arch
docker pull --platform "linux/${ARCH}" "${DEBIAN_IMAGE}"

# Create container and install packages
CONTAINER_ID=$(docker create --platform "linux/${ARCH}" "${DEBIAN_IMAGE}" sleep infinity)

docker start "${CONTAINER_ID}"
docker exec "${CONTAINER_ID}" apt-get update
docker exec "${CONTAINER_ID}" apt-get install -y --no-install-recommends ${TIER1} ${TIER2}
docker exec "${CONTAINER_ID}" apt-get clean
docker exec "${CONTAINER_ID}" rm -rf /var/lib/apt/lists/*
docker exec "${CONTAINER_ID}" rm -rf /tmp/* /var/tmp/*

# Create /var/tmp -> /tmp symlink
docker exec "${CONTAINER_ID}" bash -c "rm -rf /var/tmp && ln -s /tmp /var/tmp"

# Stop container and export filesystem
docker stop "${CONTAINER_ID}"
FILENAME="debian-rootfs-${ARCH}.tar.gz"
docker export "${CONTAINER_ID}" | gzip > "${FILENAME}"

# Checksum
sha256sum "${FILENAME}" > "${FILENAME}.sha256"

# Cleanup
docker rm -f "${CONTAINER_ID}"

echo "Built ${FILENAME}"
cat "${FILENAME}.sha256"
