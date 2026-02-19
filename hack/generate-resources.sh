#!/usr/bin/env bash
# Generate ClusterStack and Cluster YAML resources for testing.
#
# Usage:
#   ./hack/generate-resources.sh [stack-dir] --version 1.34 [options]
#
# If <stack-dir> is omitted, it is derived from $PROVIDER and $CLUSTER_STACK
# (default: providers/openstack/scs2).
#
# Options:
#   --version <X.Y>        K8s minor version (required)
#   --namespace <ns>       Namespace (default: cluster)
#   --cluster-name <name>  Workload cluster name (default: cs-cluster)
#   --cluster-only         Only generate the Cluster resource
#   --clusterstack-only    Only generate the ClusterStack resource
#
# Output goes to stdout. Pipe to kubectl apply -f - or redirect to a file.

set -euo pipefail

# ============================================
# Argument parsing
# ============================================

STACK_DIR=""
K8S_VERSION=""
NAMESPACE="cluster"
CLUSTER_NAME="cs-cluster"
CLUSTER_ONLY=false
CLUSTERSTACK_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)            K8S_VERSION="$2"; shift 2 ;;
        --namespace)          NAMESPACE="$2"; shift 2 ;;
        --cluster-name)       CLUSTER_NAME="$2"; shift 2 ;;
        --cluster-only)       CLUSTER_ONLY=true; shift ;;
        --clusterstack-only)  CLUSTERSTACK_ONLY=true; shift ;;
        -*)                   echo "Unknown option: $1" >&2; exit 1 ;;
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

if [[ -z "$K8S_VERSION" ]]; then
    echo "Usage: $0 [stack-dir] --version X.Y [--namespace ns] [--cluster-name name]" >&2
    exit 1
fi

if [[ ! -f "$STACK_DIR/csctl.yaml" ]]; then
    echo "csctl.yaml not found in: $STACK_DIR" >&2
    exit 1
fi

# ============================================
# Read stack configuration
# ============================================

PROVIDER=$(yq '.config.provider.type' "$STACK_DIR/csctl.yaml")
CLUSTER_STACK=$(yq '.config.clusterStackName' "$STACK_DIR/csctl.yaml")
K8S_DASH="${K8S_VERSION//./-}"

# Resolve full K8s version from versions.yaml if available
K8S_FULL="$K8S_VERSION"
if [[ -f "$STACK_DIR/versions.yaml" ]]; then
    K8S_FULL=$(yq -r ".[] | select(.kubernetes | test(\"^${K8S_VERSION}\")) | .kubernetes" "$STACK_DIR/versions.yaml" | head -1)
    K8S_FULL="${K8S_FULL:-$K8S_VERSION}"
fi

# Try to find the latest CS version from OCI registry
CS_VERSION="v1"
if [[ -n "${OCI_REGISTRY:-}" && -n "${OCI_REPOSITORY:-}" ]] && command -v oras >/dev/null 2>&1; then
    TAG_PREFIX="${PROVIDER}-${CLUSTER_STACK}-${K8S_DASH}"
    LATEST=$(oras repo tags "${OCI_REGISTRY}/${OCI_REPOSITORY}" 2>/dev/null | \
        grep -oP "^${TAG_PREFIX}-v\K[0-9]+" | sort -n | tail -1 || echo "")
    [[ -n "$LATEST" ]] && CS_VERSION="v${LATEST}"
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
  name: ${PROVIDER}-${K8S_DASH}
  namespace: ${NAMESPACE}
spec:
  provider: ${PROVIDER}
  name: ${CLUSTER_STACK}
  kubernetesVersion: "${K8S_VERSION}"
  channel: custom
  autoSubscribe: false
  versions:
    - ${CS_VERSION}
EOF
fi

# ============================================
# Generate Cluster resource
# ============================================

if [[ "$CLUSTERSTACK_ONLY" != "true" ]]; then
    CLUSTER_CLASS="${PROVIDER}-${CLUSTER_STACK}-${K8S_DASH}-${CS_VERSION}"

    cat <<EOF
---
apiVersion: cluster.x-k8s.io/v1beta2
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
