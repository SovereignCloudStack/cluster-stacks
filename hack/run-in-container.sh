#!/usr/bin/env bash
# Run cluster-stack build commands in a Docker container
# Usage: BUILD_IN_CONTAINER=true ./hack/run-in-container.sh <command>

set -euo pipefail

# Configuration
BUILDER_IMAGE="${BUILDER_IMAGE:-ghcr.io/sovereigncloudstack/cluster-stack-builder:latest}"
USE_PODMAN="${USE_PODMAN:-true}"

# Detect container runtime
if [[ "$USE_PODMAN" == "true" ]] || command -v podman >/dev/null 2>&1 && ! command -v docker >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
else
    CONTAINER_CMD="docker"
fi

# Get the repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Volume mount flags (for SELinux systems like Fedora/RHEL)
MOUNT_FLAGS=""
if [[ -f /etc/selinux/config ]] && grep -q "SELINUX=enforcing" /etc/selinux/config 2>/dev/null; then
    MOUNT_FLAGS=":z"
fi

# Run command in container
echo "🐳 Running in container: $BUILDER_IMAGE"
echo "   Command: $*"
echo ""

exec $CONTAINER_CMD run --rm -it \
    -v "${REPO_ROOT}:/workspace${MOUNT_FLAGS}" \
    -w /workspace \
    -e "OCI_REGISTRY=${OCI_REGISTRY:-}" \
    -e "OCI_REPOSITORY=${OCI_REPOSITORY:-}" \
    -e "OCI_USERNAME=${OCI_USERNAME:-}" \
    -e "OCI_PASSWORD=${OCI_PASSWORD:-}" \
    -e "OCI_ACCESS_TOKEN=${OCI_ACCESS_TOKEN:-}" \
    -e "OUTPUT_DIR=${OUTPUT_DIR:-.release}" \
    "$BUILDER_IMAGE" \
    "$@"
