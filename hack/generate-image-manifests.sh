#!/usr/bin/env bash
# Generate OpenStack image manifests for Kubernetes CAPI images.
#
# Supports two output formats:
#   orc            ORC Image CRD (default) — for k-orc.cloud Image resources
#   image-manager  openstack-image-manager YAML — for OSISM image-manager
#
# Usage:
#   ./hack/generate-image-manifests.sh [stack-dir] [options]
#
# Options:
#   --version <X.Y>       Generate for a specific K8s minor version
#   --format <format>     Output format: orc (default) or image-manager
#   --visibility <vis>    Image visibility: private (default), public, shared, community
#   --output-dir <dir>    Write to files instead of stdout
#   --skip-checksum       Skip fetching SHA256 checksums
#
# The <stack-dir> is the base directory containing per-minor-version subdirs
# (e.g., providers/openstack/scs). If omitted, it is derived from $PROVIDER
# and $CLUSTER_STACK (default: providers/openstack/scs).
#
# Only relevant for OpenStack-based stacks (Docker stacks have no node images).
#
# Examples:
#   ./hack/generate-image-manifests.sh --version 1.34
#   ./hack/generate-image-manifests.sh --format image-manager --visibility public
#   ./hack/generate-image-manifests.sh --version 1.34 --visibility shared --skip-checksum
#
# Environment:
#   PROVIDER          Provider name (default: openstack)
#   CLUSTER_STACK     Cluster stack name (default: scs)
#   IMAGE_BASE_URL    Base URL for images (default: https://nbg1.your-objectstorage.com/osism/openstack-k8s-capi-images)
#   CLOUD_NAME        CloudCredentialsRef cloud name (default: openstack, orc format only)
#   SECRET_NAME       CloudCredentialsRef secret name (default: openstack, orc format only)

set -euo pipefail

require_command() {
    local name="$1"

    if ! command -v "$name" >/dev/null 2>&1; then
        echo "$name not found. Please install $name and try again." >&2
        exit 1
    fi
}

extract_k8s_minor_version() {
    echo "$1" | sed -E -n 's/^([0-9]+\.[0-9]+)(\.[0-9]+)?$/\1/p'
}

require_command yq
require_command curl
require_command jq

# Defaults
BASE_URL="${IMAGE_BASE_URL:-https://nbg1.your-objectstorage.com/osism/openstack-k8s-capi-images}"
CLOUD_NAME="${CLOUD_NAME:-openstack}"
SECRET_NAME="${SECRET_NAME:-openstack}"

# ============================================
# Argument parsing
# ============================================

BASE_DIR=""
TARGET_VERSION=""
OUTPUT_DIR=""
OUTPUT_FORMAT="orc"
VISIBILITY="private"
SKIP_CHECKSUM=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)        TARGET_VERSION="$2"; shift 2 ;;
        --format)         OUTPUT_FORMAT="$2"; shift 2 ;;
        --visibility)     VISIBILITY="$2"; shift 2 ;;
        --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
        --skip-checksum)  SKIP_CHECKSUM=true; shift ;;
        -*)               echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -z "$BASE_DIR" ]]; then
                BASE_DIR="$1"; shift
            else
                echo "Unexpected argument: $1" >&2; exit 1
            fi
            ;;
    esac
done

if [[ -z "$BASE_DIR" ]]; then
    BASE_DIR="providers/${PROVIDER:-openstack}/${CLUSTER_STACK:-scs}"
fi

if [[ ! -d "$BASE_DIR" ]]; then
    echo "Stack base directory not found: $BASE_DIR" >&2
    exit 1
fi

case "$OUTPUT_FORMAT" in
    orc|image-manager) ;;
    *) echo "Unknown format: $OUTPUT_FORMAT (use 'orc' or 'image-manager')" >&2; exit 1 ;;
esac

case "$VISIBILITY" in
    private|public|shared|community) ;;
    *) echo "Unknown visibility: $VISIBILITY (use private, public, shared, or community)" >&2; exit 1 ;;
esac

# ============================================
# Ubuntu version mapping
# ============================================

# K8s 1.32 and earlier → Ubuntu 22.04 (2204)
# K8s 1.33 and later   → Ubuntu 24.04 (2404)
ubuntu_for_minor() {
    local minor="$1"
    if [[ "$minor" -le 32 ]]; then
        echo "2204"
    else
        echo "2404"
    fi
}

# ============================================
# Check provider
# ============================================

FIRST_STACK=""
for stack_file in "$BASE_DIR"/1-*/stack.yaml; do
    if [[ -f "$stack_file" ]]; then
        FIRST_STACK="$stack_file"
        break
    fi
done

if [[ -z "$FIRST_STACK" ]]; then
    echo "No stack.yaml found in $BASE_DIR/1-*/" >&2
    exit 1
fi

STACK_PROVIDER=$(yq -r '.provider' "$FIRST_STACK")
if [[ "$STACK_PROVIDER" != "openstack" ]]; then
    echo "Image manifests are only relevant for OpenStack-based stacks (provider: $STACK_PROVIDER)." >&2
    exit 0
fi

[[ -n "$OUTPUT_DIR" ]] && mkdir -p "$OUTPUT_DIR"

# ============================================
# Resolve K8s patch version
# ============================================

resolve_k8s_version() {
    local version="$1"

    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
        return
    fi

    local github_headers=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        github_headers=(-H "Authorization: token $GITHUB_TOKEN")
    fi
    local latest
    if ! latest=$(curl -sfL "${github_headers[@]+"${github_headers[@]}"}" \
        "https://api.github.com/repos/kubernetes/kubernetes/releases?per_page=100" 2>/dev/null \
        | jq -r '.[].tag_name' 2>/dev/null \
        | grep -E "^v${version}\.[0-9]+$" \
        | sed 's/^v//' \
        | sort -V \
        | tail -1); then
        echo "Failed to resolve the latest GitHub patch version for Kubernetes ${version}." >&2
        exit 1
    fi

    if [[ -n "$latest" ]]; then
        echo "$latest"
        return
    fi

    echo "Could not resolve a stable patch version for Kubernetes ${version}." >&2
    exit 1
}

# ============================================
# Collect image data
# ============================================

# Arrays to collect data for image-manager format (needs all versions grouped)
declare -a ALL_K8S_VERSIONS=()
declare -a ALL_IMAGE_URLS=()
declare -a ALL_CHECKSUMS=()
declare -a ALL_UBUNTU=()

GENERATED=0
FAIL_COUNT=0

for version_dir in "$BASE_DIR"/1-*/; do
    [[ -d "$version_dir" ]] || continue
    stack_yaml="$version_dir/stack.yaml"
    [[ -f "$stack_yaml" ]] || continue

    k8s_version_raw=$(yq -r '.kubernetesVersion' "$stack_yaml")
    k8s_short=$(extract_k8s_minor_version "$k8s_version_raw")
    k8s_minor=$(echo "$k8s_short" | cut -d. -f2)

    # Filter by --version if specified
    if [[ -n "$TARGET_VERSION" ]]; then
        target_short=$(extract_k8s_minor_version "$TARGET_VERSION")
        if [[ "$k8s_short" != "$target_short" ]]; then
            continue
        fi
    fi

    # Resolve full K8s patch version
    k8s_version=$(resolve_k8s_version "$k8s_version_raw")

    UBUNTU=$(ubuntu_for_minor "$k8s_minor")
    IMAGE_NAME="ubuntu-${UBUNTU}-kube-v${k8s_version}"
    IMAGE_DIR="ubuntu-${UBUNTU}-kube-v${k8s_short}"
    IMAGE_URL="${BASE_URL}/${IMAGE_DIR}/${IMAGE_NAME}.qcow2"

    # Fetch checksum
    CHECKSUM=""
    if [[ "$SKIP_CHECKSUM" != "true" ]]; then
        CHECKSUM=$(curl -sf "${IMAGE_URL}.CHECKSUM" | awk '{print $1}' || echo "")
        if [[ -z "$CHECKSUM" ]]; then
            echo "Failed to fetch checksum for ${k8s_version}: ${IMAGE_URL}.CHECKSUM" >&2
            echo "Use --skip-checksum to generate without hash validation" >&2
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        fi
    fi

    ALL_K8S_VERSIONS+=("$k8s_version")
    ALL_IMAGE_URLS+=("$IMAGE_URL")
    ALL_CHECKSUMS+=("$CHECKSUM")
    ALL_UBUNTU+=("$UBUNTU")
    GENERATED=$((GENERATED + 1))
done

# ============================================
# Output: ORC Image CRD format
# ============================================

generate_orc() {
    for ((i=0; i<${#ALL_K8S_VERSIONS[@]}; i++)); do
        local k8s_version="${ALL_K8S_VERSIONS[$i]}"
        local image_url="${ALL_IMAGE_URLS[$i]}"
        local checksum="${ALL_CHECKSUMS[$i]}"
        local ubuntu="${ALL_UBUNTU[$i]}"

        local hash_block=""
        if [[ -n "$checksum" ]]; then
            hash_block="
        hash:
          algorithm: sha256
          value: ${checksum}"
        fi

        local manifest="---
apiVersion: openstack.k-orc.cloud/v1alpha1
kind: Image
metadata:
  name: ubuntu-capi-image-v${k8s_version}
spec:
  cloudCredentialsRef:
    cloudName: ${CLOUD_NAME}
    secretName: ${SECRET_NAME}
  managementPolicy: managed
  resource:
    visibility: ${VISIBILITY}
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
        version: \"${ubuntu:0:2}.${ubuntu:2:2}\"
    content:
      diskFormat: qcow2
      download:
        url: ${image_url}${hash_block}"

        if [[ -n "$OUTPUT_DIR" ]]; then
            local outfile="${OUTPUT_DIR}/ubuntu-${ubuntu}-kube-v${k8s_version}.yaml"
            echo "$manifest" > "$outfile"
            echo "Written: $outfile" >&2
        else
            echo "$manifest"
        fi
    done
}

# ============================================
# Output: openstack-image-manager format
# ============================================

generate_image_manager() {
    # Build versions list
    local versions_block=""
    for ((i=0; i<${#ALL_K8S_VERSIONS[@]}; i++)); do
        local k8s_version="${ALL_K8S_VERSIONS[$i]}"
        local image_url="${ALL_IMAGE_URLS[$i]}"
        local checksum="${ALL_CHECKSUMS[$i]}"

        local checksum_line=""
        if [[ -n "$checksum" ]]; then
            checksum_line="
        checksum: \"sha256:${checksum}\""
        fi

        versions_block+="
      - version: 'v${k8s_version}'
        url: ${image_url}${checksum_line}"
    done

    local manifest="---
images:
  - name: ubuntu-capi-image
    enable: true
    format: raw
    login: ubuntu
    min_disk: 20
    min_ram: 1024
    status: active
    visibility: ${VISIBILITY}
    multi: false
    separator: \"-\"
    meta:
      architecture: x86_64
      hw_disk_bus: virtio
      hw_rng_model: virtio
      hw_scsi_model: virtio-scsi
      hw_watchdog_action: reset
      hypervisor_type: qemu
      os_distro: ubuntu
      os_purpose: k8snode
      replace_frequency: never
      uuid_validity: none
      provided_until: none
    tags:
      - clusterstacks
    versions:${versions_block}"

    if [[ -n "$OUTPUT_DIR" ]]; then
        local outfile="${OUTPUT_DIR}/kubernetes.yaml"
        echo "$manifest" > "$outfile"
        echo "Written: $outfile" >&2
    else
        echo "$manifest"
    fi
}

# ============================================
# Generate output
# ============================================

if [[ $GENERATED -eq 0 && $FAIL_COUNT -eq 0 ]]; then
    echo "No matching versions found" >&2
    exit 1
fi

if [[ $FAIL_COUNT -gt 0 && $GENERATED -eq 0 ]]; then
    echo "All $FAIL_COUNT version(s) failed checksum fetch" >&2
    exit 1
fi

case "$OUTPUT_FORMAT" in
    orc)           generate_orc ;;
    image-manager) generate_image_manager ;;
esac

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "Generated $GENERATED manifest(s), failed $FAIL_COUNT" >&2
else
    echo "Generated $GENERATED manifest(s)" >&2
fi
