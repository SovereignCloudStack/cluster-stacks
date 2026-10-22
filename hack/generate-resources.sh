#!/usr/bin/env bash
# Generate ClusterStack and Cluster YAML resources for testing.
#
# Usage:
#   ./hack/generate-resources.sh [stack-dir] --version 1.34 [options]
#
# The <stack-dir> is the base directory containing per-minor-version subdirs
# (e.g., providers/openstack/scs). If omitted, it is derived from $PROVIDER
# and $CLUSTER_STACK (default: providers/openstack/scs). Relative paths are
# resolved from the repository root.
#
# Options:
#   --version <X.Y>        K8s minor version (required)
#   --cs-version <vN>      Cluster stack version (default: auto-detect, see below)
#   --namespace <ns>       Namespace (default: cluster)
#   --cluster-name <name>  Workload cluster name (default: cs-cluster)
#   --cluster-only         Only generate the Cluster resource
#   --clusterstack-only    Only generate the ClusterStack resource
#   -h, --help             Show this help
#
# Auto-detection of --cs-version (in priority order):
#   1. Local .release/ directory — reads metadata.yaml from the latest matching build
#   2. OCI registry — queries tags via oras (requires OCI_REGISTRY + OCI_REPOSITORY)
#   3. Falls back to v1
#
# Output goes to stdout. Pipe to kubectl apply -f - or redirect to a file.
#
# Examples:
#   ./hack/generate-resources.sh --version 1.34
#   ./hack/generate-resources.sh --version 1.34 --cs-version v2
#   ./hack/generate-resources.sh --version 1.34 | kubectl apply -f -
#   PROVIDER=docker ./hack/generate-resources.sh --version 1.35

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require_command() {
    local name="$1"

    if ! command -v "$name" >/dev/null 2>&1; then
        echo "$name not found. Please install $name and try again." >&2
        exit 1
    fi
}

extract_latest_release_number() {
    local prefix="$1"

    awk -v prefix="${prefix}-v" 'index($0, prefix) == 1 {
        suffix = substr($0, length(prefix) + 1)
        if (suffix ~ /^[0-9]+$/) {
            print suffix
        }
    }' | sort -n | tail -1
}

resolve_k8s_version() {
    local version="$1"
    local provider="$2"

    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
        return
    fi

    local latest
    if [[ "$provider" == "docker" ]]; then
        require_command jq
        if ! latest=$(curl -sfL "https://registry.hub.docker.com/v2/repositories/kindest/node/tags?page_size=100&name=v${version}." 2>/dev/null \
            | jq -r '.results[].name' 2>/dev/null \
            | grep -E "^v${version}\.[0-9]+$" \
            | sed 's/^v//' \
            | sort -V \
            | tail -1); then
            echo "Failed to resolve the latest kindest/node patch version for Kubernetes ${version}." >&2
            exit 1
        fi
    elif ! latest=$(curl -sfL "https://dl.k8s.io/release/stable-${version}.txt" 2>/dev/null | sed 's/^v//'); then
        echo "Failed to resolve the latest patch version for Kubernetes ${version}." >&2
        exit 1
    fi

    if [[ -n "$latest" && "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$latest"
        return
    fi

    echo "Could not resolve a stable patch version for Kubernetes ${version}." >&2
    exit 1
}

# ============================================
# Argument parsing
# ============================================

usage() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit "${1:-1}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)            [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; usage; }; K8S_VERSION="$2"; shift 2 ;;
            --cs-version)         [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; usage; }; CS_VERSION="$2"; shift 2 ;;
            --namespace)          [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; usage; }; NAMESPACE="$2"; shift 2 ;;
            --cluster-name)       [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; usage; }; CLUSTER_NAME="$2"; shift 2 ;;
            --cluster-only)       CLUSTER_ONLY=true; shift ;;
            --clusterstack-only)  CLUSTERSTACK_ONLY=true; shift ;;
            -h|--help)            usage 0 ;;
            -*)                   echo "Unknown option: $1" >&2; usage ;;
            *)
                if [[ -z "$BASE_DIR" ]]; then
                    BASE_DIR="$1"; shift
                else
                    echo "Unexpected argument: $1" >&2; usage
                fi
                ;;
        esac
    done
}

resolve_base_dir() {
    local dir="$1"

    if [[ -z "$dir" ]]; then
        dir="providers/${PROVIDER:-openstack}/${CLUSTER_STACK:-scs}"
    fi

    if [[ ! "$dir" = /* ]]; then
        dir="$REPO_ROOT/$dir"
    fi

    echo "$dir"
}

BASE_DIR=""
K8S_VERSION=""
CS_VERSION=""
NAMESPACE="cluster"
CLUSTER_NAME="cs-cluster"
CLUSTER_ONLY=false
CLUSTERSTACK_ONLY=false

parse_args "$@"

if [[ "$CLUSTER_ONLY" == "true" && "$CLUSTERSTACK_ONLY" == "true" ]]; then
    echo "Error: --cluster-only and --clusterstack-only are mutually exclusive" >&2
    usage
fi

require_command yq
require_command curl

BASE_DIR="$(resolve_base_dir "$BASE_DIR")"

if [[ -z "$K8S_VERSION" ]]; then
    echo "Error: --version is required" >&2
    usage
fi

# Resolve version directory
K8S_DASH="${K8S_VERSION//./-}"
VERSION_DIR="$BASE_DIR/$K8S_DASH"

if [[ ! -d "$VERSION_DIR" ]]; then
    echo "Version directory not found: $VERSION_DIR" >&2
    echo "Available:" >&2
    ls -d "$BASE_DIR"/1-*/ 2>/dev/null | sed 's|.*/||; s|/$||; s/^/  /' >&2
    exit 1
fi

CSCTL_YAML="$VERSION_DIR/csctl.yaml"
if [[ ! -f "$CSCTL_YAML" ]]; then
    echo "csctl.yaml not found in: $VERSION_DIR" >&2
    exit 1
fi

# ============================================
# Read stack configuration
# ============================================

PROVIDER=$(yq -r '.config.provider.type' "$CSCTL_YAML")
CLUSTER_STACK=$(yq -r '.config.clusterStackName' "$CSCTL_YAML")
K8S_VERSION_RAW=$(yq -r '.config.kubernetesVersion | sub("^v","")' "$CSCTL_YAML")

K8S_FULL=$(resolve_k8s_version "$K8S_VERSION_RAW" "$PROVIDER")

# Auto-detect CS version (if not specified)
# Priority: 1. local .release/ build output  2. OCI registry  3. fall back to v1
if [[ -z "$CS_VERSION" ]]; then
    RELEASE_DIR="${OUTPUT_DIR:-$REPO_ROOT/.release}"
    TAG_PREFIX="${PROVIDER}-${CLUSTER_STACK}-${K8S_DASH}"

    # 1. Check .release/ for a matching build (newest first by mtime)
    LATEST_BUILD=""
    if [[ -d "$RELEASE_DIR" ]]; then
        LATEST_BUILD=$(ls -dt "$RELEASE_DIR/${TAG_PREFIX}"-*/metadata.yaml 2>/dev/null | head -1 || true)
    fi

    if [[ -n "$LATEST_BUILD" ]]; then
        CS_VERSION=$(yq -r '.versions.clusterStack' "$LATEST_BUILD")
        echo "# Auto-detected CS version: ${CS_VERSION} (from $(dirname "$LATEST_BUILD"))" >&2
    # 2. Try OCI registry
    elif [[ -n "${OCI_REGISTRY:-}" && -n "${OCI_REPOSITORY:-}" ]] && command -v oras >/dev/null 2>&1; then
        LATEST=$(oras repo tags "${OCI_REGISTRY}/${OCI_REPOSITORY}" 2>/dev/null | \
            extract_latest_release_number "$TAG_PREFIX" || echo "")
        if [[ -n "$LATEST" ]]; then
            CS_VERSION="v${LATEST}"
            echo "# Auto-detected CS version: ${CS_VERSION} (from ${OCI_REGISTRY}/${OCI_REPOSITORY})" >&2
        else
            CS_VERSION="v1"
            echo "# No published versions found, using default: ${CS_VERSION}" >&2
        fi
    else
        CS_VERSION="v1"
        echo "# No .release/ build or OCI registry available, using default: ${CS_VERSION}" >&2
    fi
fi

# ============================================
# Generate ClusterStack resource
# ============================================

if [[ "$CLUSTER_ONLY" != "true" ]]; then
    cat <<EOF
---
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: ${PROVIDER}-${CLUSTER_STACK}-${K8S_DASH}
  namespace: ${NAMESPACE}
spec:
  provider: ${PROVIDER}
  name: ${CLUSTER_STACK}
  kubernetesVersion: "${K8S_DASH//-/.}"
  channel: custom
  autoSubscribe: false
  noProvider: true
  versions:
    - ${CS_VERSION}
EOF
fi

# ============================================
# Generate Cluster resource
# ============================================

if [[ "$CLUSTERSTACK_ONLY" != "true" ]]; then
    CLUSTER_API_VERSION="cluster.x-k8s.io/v1beta2"
    if [[ "$CLUSTER_STACK" == "hcp" ]]; then
        CLUSTER_API_VERSION="cluster.x-k8s.io/v1beta1"
    fi

    CLUSTER_CLASS="${PROVIDER}-${CLUSTER_STACK}-${K8S_DASH}-${CS_VERSION}"

    cat <<EOF
---
apiVersion: ${CLUSTER_API_VERSION}
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NAMESPACE}
  labels:
    managed-secret: cloud-config
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
        - 192.168.0.0/16
    serviceDomain: cluster.local
    services:
      cidrBlocks:
        - 10.96.0.0/12
  topology:
    class: ${CLUSTER_CLASS}
    controlPlane:
      replicas: 1
    version: v${K8S_FULL}
    workers:
      machineDeployments:
        - class: default-worker
          name: default-worker
          replicas: 2
EOF
fi
