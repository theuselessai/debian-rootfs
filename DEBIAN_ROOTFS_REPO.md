# debian-rootfs

Minimal Debian rootfs tarballs for use as sandboxed execution environments in [Pipelit](https://github.com/theuselessai/Pipelit). Published as GitHub Release assets, downloaded at runtime by the Pipelit platform.

## What This Repo Does

A GitHub Actions workflow builds a minimal Debian (bookworm-slim) rootfs tarball with pre-installed packages, then publishes it as a GitHub Release asset. Two architectures are supported: `x86_64` and `aarch64`.

## Repository Structure

```
debian-rootfs/
├── .github/
│   └── workflows/
│       └── build-rootfs.yml    # CI workflow
├── build.sh                    # Build script (runs in CI)
└── README.md                   # This file (rename from DEBIAN_ROOTFS_REPO.md)
```

## build.sh

A bash script that:

1. Pulls `debian:bookworm-slim` Docker image for the target architecture
2. Creates a container from it
3. Installs packages inside the container via `apt-get`
4. Exports the container filesystem as a tarball
5. Computes SHA-256 checksum

### Packages to install

**Tier 1 (essential):**
```
bash python3 python3-pip python3-venv coreutils grep sed
```

**Tier 2 (tools):**
```
findutils curl wget git tar unzip jq gawk nodejs npm
```

### Build script outline

```bash
#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:-amd64}"  # amd64 or arm64
DEBIAN_IMAGE="debian:bookworm-slim"

TIER1="bash python3 python3-pip python3-venv coreutils grep sed"
TIER2="findutils curl wget git tar unzip jq gawk nodejs npm ca-certificates"

# Pull image for target arch
docker pull --platform "linux/${ARCH}" "${DEBIAN_IMAGE}"

# Create container and install packages
CONTAINER_ID=$(docker create --platform "linux/${ARCH}" "${DEBIAN_IMAGE}" /bin/true)

docker start "${CONTAINER_ID}"
docker exec "${CONTAINER_ID}" apt-get update
docker exec "${CONTAINER_ID}" apt-get install -y --no-install-recommends ${TIER1} ${TIER2}
docker exec "${CONTAINER_ID}" apt-get clean
docker exec "${CONTAINER_ID}" rm -rf /var/lib/apt/lists/*

# Create /var/tmp -> /tmp symlink
docker exec "${CONTAINER_ID}" bash -c "rm -rf /var/tmp && ln -s /tmp /var/tmp"

# Export filesystem
FILENAME="debian-rootfs-${ARCH}.tar.gz"
docker export "${CONTAINER_ID}" | gzip > "${FILENAME}"

# Checksum
sha256sum "${FILENAME}" > "${FILENAME}.sha256"

# Cleanup
docker rm -f "${CONTAINER_ID}"

echo "Built ${FILENAME}"
cat "${FILENAME}.sha256"
```

> **Note:** `docker create` + `docker start` + `docker exec` is used instead of `docker run` so we can install packages and then export the full filesystem. `docker export` gives us a flat rootfs (no layers), which is exactly what bwrap needs.

## GitHub Actions Workflow

File: `.github/workflows/build-rootfs.yml`

### Trigger

- **Manual dispatch** (`workflow_dispatch`) with an optional `version` input (e.g., `v1`, `v2`)
- The version input becomes the Git tag and release name

### Jobs

**Build matrix:** `amd64` and `arm64` (use QEMU for cross-arch)

### Workflow outline

```yaml
name: Build Debian Rootfs

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Release version tag (e.g., v1, v2)'
        required: true

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch: [amd64, arm64]
    steps:
      - uses: actions/checkout@v4

      - name: Set up QEMU (for arm64 cross-build)
        uses: docker/setup-qemu-action@v3

      - name: Build rootfs
        run: bash build.sh ${{ matrix.arch }}

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: rootfs-${{ matrix.arch }}
          path: |
            debian-rootfs-${{ matrix.arch }}.tar.gz
            debian-rootfs-${{ matrix.arch }}.tar.gz.sha256

  release:
    needs: build
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - name: Download artifacts
        uses: actions/download-artifact@v4

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ inputs.version }}
          name: Debian Rootfs ${{ inputs.version }}
          body: |
            Debian bookworm-slim rootfs tarballs for sandboxed execution.

            **Packages included:** bash, python3, python3-pip, python3-venv, coreutils, grep, sed, findutils, curl, wget, git, tar, unzip, jq, gawk, nodejs, npm, ca-certificates

            **Architectures:** amd64, arm64
          files: |
            rootfs-amd64/debian-rootfs-amd64.tar.gz
            rootfs-amd64/debian-rootfs-amd64.tar.gz.sha256
            rootfs-arm64/debian-rootfs-arm64.tar.gz
            rootfs-arm64/debian-rootfs-arm64.tar.gz.sha256
```

## Release Asset URLs

After a release is published (e.g., tag `v1`), the tarballs are available at:

```
https://github.com/theuselessai/debian-rootfs/releases/download/v1/debian-rootfs-amd64.tar.gz
https://github.com/theuselessai/debian-rootfs/releases/download/v1/debian-rootfs-amd64.tar.gz.sha256
https://github.com/theuselessai/debian-rootfs/releases/download/v1/debian-rootfs-arm64.tar.gz
https://github.com/theuselessai/debian-rootfs/releases/download/v1/debian-rootfs-arm64.tar.gz.sha256
```

## How Pipelit Will Consume This

In `platform/services/rootfs.py`, the Alpine-specific logic will be replaced:

- **Download URL:** `https://github.com/theuselessai/debian-rootfs/releases/download/{version}/debian-rootfs-{arch}.tar.gz`
- **Arch mapping:** `x86_64` → `amd64`, `aarch64` → `arm64`
- **Verification:** Download `.sha256` file and compare
- **Readiness check:** Look for `/etc/debian_version` instead of `/etc/alpine-release`
- **No `install_packages()`** — packages are pre-installed in the tarball, so no need for bwrap+apt at runtime
- **Version pinning:** A config setting (e.g., `ROOTFS_VERSION=v1`) controls which release to download

The bwrap sandbox (`sandboxed_backend.py`) needs zero changes — it just mounts whatever rootfs is at the workspace path.
