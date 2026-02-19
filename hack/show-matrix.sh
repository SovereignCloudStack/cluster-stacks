#!/usr/bin/env bash
# Display the version matrix for a cluster stack.
#
# Shows K8s versions, cluster-stack versions (from OCI), and all addon versions.
#
# Usage:
#   ./hack/show-matrix.sh [stack-dir]
#
# If <stack-dir> is omitted, it is derived from $PROVIDER and $CLUSTER_STACK
# (default: providers/openstack/scs2).
#
# Environment:
#   PROVIDER        Provider name (default: openstack)
#   CLUSTER_STACK   Cluster stack name (default: scs2)
#   OCI_REGISTRY    OCI registry to query for CS versions (optional)
#   OCI_REPOSITORY  OCI repository to query for CS versions (optional)

set -euo pipefail

STACK_DIR="${1:-providers/${PROVIDER:-openstack}/${CLUSTER_STACK:-scs2}}"

if [[ ! -f "$STACK_DIR/csctl.yaml" ]]; then
    echo "csctl.yaml not found in: $STACK_DIR" >&2
    exit 1
fi

PROVIDER=$(yq '.config.provider.type' "$STACK_DIR/csctl.yaml")
CLUSTER_STACK=$(yq '.config.clusterStackName' "$STACK_DIR/csctl.yaml")

# ============================================
# Collect universal addon versions (from Chart.yaml)
# ============================================

declare -A UNIVERSAL_ADDONS

for chart_file in "$STACK_DIR"/cluster-addon/*/Chart.yaml; do
    [[ -f "$chart_file" ]] || continue
    addon_name=$(basename "$(dirname "$chart_file")")
    num_deps=$(yq '.dependencies | length' "$chart_file" 2>/dev/null || echo "0")

    for ((i=0; i<num_deps; i++)); do
        dep_name=$(yq ".dependencies[$i].name" "$chart_file")
        dep_version=$(yq ".dependencies[$i].version" "$chart_file")
        UNIVERSAL_ADDONS["$dep_name"]="$dep_version"
    done
done

# ============================================
# Build the matrix
# ============================================

echo "Cluster Stack: ${PROVIDER}/${CLUSTER_STACK}"
echo ""

if [[ ! -f "$STACK_DIR/versions.yaml" ]]; then
    # No versions.yaml — single version from csctl.yaml
    K8S_VERSION=$(yq -r '.config.kubernetesVersion' "$STACK_DIR/csctl.yaml" | sed 's/^v//')
    echo "K8s Version: $K8S_VERSION"
    echo ""
    echo "Addons:"
    for dep_name in $(echo "${!UNIVERSAL_ADDONS[@]}" | tr ' ' '\n' | sort); do
        printf "  %-40s %s\n" "$dep_name" "${UNIVERSAL_ADDONS[$dep_name]}"
    done
    exit 0
fi

# Collect all addon keys from versions.yaml (excluding metadata fields)
VERSIONED_KEYS=$(yq -r '.[0] | keys | .[] | select(test("^(kubernetes|ubuntu)$") | not)' "$STACK_DIR/versions.yaml" 2>/dev/null || echo "")

# Collect all addon names for header
ALL_ADDONS=()
for dep_name in $(echo "${!UNIVERSAL_ADDONS[@]}" | tr ' ' '\n' | sort); do
    # Skip addons that are in versions.yaml (they'll be shown per-version)
    if echo "$VERSIONED_KEYS" | grep -qx "$dep_name" 2>/dev/null; then
        continue
    fi
    ALL_ADDONS+=("$dep_name")
done
for key in $VERSIONED_KEYS; do
    ALL_ADDONS+=("$key")
done

# Print header
HEADER="K8s Version     | CS Version"
SEPARATOR="--------------- | ----------"
for addon in "${ALL_ADDONS[@]}"; do
    # Truncate long names for display
    short=$(echo "$addon" | sed 's/openstack-/os-/')
    HEADER+=" | $short"
    SEPARATOR+=" | $(printf '%*s' ${#short} '' | tr ' ' '-')"
done
echo "$HEADER"
echo "$SEPARATOR"

# Print rows
ENTRY_COUNT=$(yq '. | length' "$STACK_DIR/versions.yaml")

for ((i=0; i<ENTRY_COUNT; i++)); do
    K8S_VERSION=$(yq -r ".[$i].kubernetes" "$STACK_DIR/versions.yaml")
    K8S_SHORT=$(echo "$K8S_VERSION" | grep -oP '^\d+\.\d+')
    K8S_DASH="${K8S_SHORT//./-}"

    # Query OCI for CS version
    CS_VERSION="-"
    if [[ -n "${OCI_REGISTRY:-}" && -n "${OCI_REPOSITORY:-}" ]] && command -v oras >/dev/null 2>&1; then
        TAG_PREFIX="${PROVIDER}-${CLUSTER_STACK}-${K8S_DASH}"
        LATEST=$(oras repo tags "${OCI_REGISTRY}/${OCI_REPOSITORY}" 2>/dev/null | \
            grep -oP "^${TAG_PREFIX}-v\K[0-9]+" | sort -n | tail -1 || echo "")
        [[ -n "$LATEST" ]] && CS_VERSION="v${LATEST}"
    fi

    ROW=$(printf "%-15s | %-10s" "$K8S_VERSION" "$CS_VERSION")

    for addon in "${ALL_ADDONS[@]}"; do
        # Check versions.yaml first (for K8s-tied addons)
        ver=$(yq -r ".[$i].\"${addon}\" // \"\"" "$STACK_DIR/versions.yaml" 2>/dev/null || echo "")
        if [[ -z "$ver" || "$ver" == "null" ]]; then
            # Fall back to universal version from Chart.yaml
            ver="${UNIVERSAL_ADDONS[$addon]:-?}"
        fi
        short=$(echo "$addon" | sed 's/openstack-/os-/')
        ROW+=" | $(printf "%-${#short}s" "$ver")"
    done

    echo "$ROW"
done
