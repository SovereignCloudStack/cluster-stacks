#!/usr/bin/env bash
# Generate OpenStack Image CRD manifests for Kubernetes CAPI images.
#
# Reads versions.yaml to get K8s versions and Ubuntu releases, constructs
# image URLs, fetches SHA256 checksums, and outputs Image CRD YAML.
#
# The Ubuntu release is read from the "ubuntu" field in versions.yaml.
# Entries without an "ubuntu" field are skipped (e.g., docker provider stacks).
#
# Usage:
#   ./hack/generate-image-manifests.sh [stack-dir] [options]
#
# If <stack-dir> is omitted, it is derived from $PROVIDER and $CLUSTER_STACK
# (default: providers/openstack/scs2).
#
# Options:
#   --version X.Y         Generate for a specific K8s minor version only
#   --output-dir <dir>    Write individual YAML files instead of stdout
#   --skip-checksum       Skip fetching SHA256 checksums
#
# Environment:
#   PROVIDER          Provider name (default: openstack)
#   CLUSTER_STACK     Cluster stack name (default: scs2)
#   IMAGE_BASE_URL    Base URL for images (default: https://nbg1.your-objectstorage.com/osism/openstack-k8s-capi-images)
#   CLOUD_NAME        CloudCredentialsRef cloud name (default: openstack)
#   SECRET_NAME       CloudCredentialsRef secret name (default: openstack)

set -euo pipefail

# Defaults
BASE_URL="${IMAGE_BASE_URL:-https://nbg1.your-objectstorage.com/osism/openstack-k8s-capi-images}"
CLOUD_NAME="${CLOUD_NAME:-openstack}"
SECRET_NAME="${SECRET_NAME:-openstack}"

# ============================================
# Argument parsing
# ============================================

STACK_DIR=""
TARGET_VERSION=""
OUTPUT_DIR=""
SKIP_CHECKSUM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)        TARGET_VERSION="$2"; shift 2 ;;
        --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
        --skip-checksum)  SKIP_CHECKSUM=true; shift ;;
        -*)               echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -z "$STACK_DIR" ]]; then
                STACK_DIR="$1"; shift
            else
                echo "Unexpected argument: $1" >&2; exit 1
            fi
            ;;
    esac
done

if [[ -z "$STACK_DIR" ]]; then
    STACK_DIR="providers/${PROVIDER:-openstack}/${CLUSTER_STACK:-scs2}"
fi

if [[ ! -f "$STACK_DIR/versions.yaml" ]]; then
    echo "versions.yaml not found in: $STACK_DIR" >&2
    exit 1
fi

# ============================================
# Check for ubuntu field
# ============================================

HAS_UBUNTU=$(yq -r '.[0] | has("ubuntu")' "$STACK_DIR/versions.yaml" 2>/dev/null || echo "false")
if [[ "$HAS_UBUNTU" != "true" ]]; then
    echo "No 'ubuntu' field in versions.yaml — this stack has no node images to generate." >&2
    echo "Image manifests are only relevant for OpenStack-based stacks." >&2
    exit 0
fi

# ============================================
# Collect entries
# ============================================

ENTRY_COUNT=$(yq '. | length' "$STACK_DIR/versions.yaml")

[[ -n "$OUTPUT_DIR" ]] && mkdir -p "$OUTPUT_DIR"

# ============================================
# Generate manifests
# ============================================

GENERATED=0
FAIL_COUNT=0

for ((i=0; i<ENTRY_COUNT; i++)); do
    K8S_VERSION=$(yq -r ".[$i].kubernetes" "$STACK_DIR/versions.yaml")
    UBUNTU=$(yq -r ".[$i].ubuntu // \"\"" "$STACK_DIR/versions.yaml")

    # Skip entries without ubuntu field
    if [[ -z "$UBUNTU" ]]; then
        continue
    fi

    # Filter by --version if specified (match major.minor prefix)
    if [[ -n "$TARGET_VERSION" ]]; then
        K8S_SHORT=$(echo "$K8S_VERSION" | grep -oP '^\d+\.\d+')
        TARGET_SHORT=$(echo "$TARGET_VERSION" | grep -oP '^\d+\.\d+')
        if [[ "$K8S_SHORT" != "$TARGET_SHORT" ]]; then
            continue
        fi
    fi

    K8S_SHORT=$(echo "$K8S_VERSION" | grep -oP '^\d+\.\d+')
    IMAGE_NAME="ubuntu-${UBUNTU}-kube-v${K8S_VERSION}"
    IMAGE_DIR="ubuntu-${UBUNTU}-kube-v${K8S_SHORT}"
    IMAGE_URL="${BASE_URL}/${IMAGE_DIR}/${IMAGE_NAME}.qcow2"

    # Fetch checksum
    HASH_BLOCK=""
    if [[ "$SKIP_CHECKSUM" != "true" ]]; then
        CHECKSUM=$(curl -sf "${IMAGE_URL}.CHECKSUM" | awk '{print $1}' || echo "")
        if [[ -z "$CHECKSUM" ]]; then
            echo "Failed to fetch checksum for ${K8S_VERSION}: ${IMAGE_URL}.CHECKSUM" >&2
            echo "Use --skip-checksum to generate without hash validation" >&2
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        fi
        HASH_BLOCK="
        hash:
          algorithm: sha256
          value: ${CHECKSUM}"
    fi

    MANIFEST="---
apiVersion: openstack.k-orc.cloud/v1alpha1
kind: Image
metadata:
  name: ubuntu-capi-image-v${K8S_VERSION}
spec:
  cloudCredentialsRef:
    cloudName: ${CLOUD_NAME}
    secretName: ${SECRET_NAME}
  managementPolicy: managed
  resource:
    visibility: private
    properties:
      hardware:
        diskBus: scsi
        scsiModel: virtio-scsi
        vifModel: virtio
        qemuGuestAgent: true
        rngModel: virtio
      architecture: x86_64
      minDiskGB: 20
      minMemoryMB: 2048
      operatingSystem:
        distro: ubuntu
        version: \"${UBUNTU:0:2}.${UBUNTU:2:2}\"
    content:
      diskFormat: qcow2
      download:
        url: ${IMAGE_URL}${HASH_BLOCK}"

    if [[ -n "$OUTPUT_DIR" ]]; then
        OUTFILE="${OUTPUT_DIR}/${IMAGE_NAME}.yaml"
        echo "$MANIFEST" > "$OUTFILE"
        echo "Written: $OUTFILE" >&2
    else
        echo "$MANIFEST"
    fi

    GENERATED=$((GENERATED + 1))
done

# ============================================
# Summary
# ============================================

if [[ $GENERATED -eq 0 && $FAIL_COUNT -eq 0 ]]; then
    echo "No matching versions found" >&2
    exit 1
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "Generated $GENERATED manifest(s), failed $FAIL_COUNT" >&2
    exit 1
fi

echo "Generated $GENERATED manifest(s)" >&2
