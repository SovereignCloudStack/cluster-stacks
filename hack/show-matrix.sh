#!/usr/bin/env bash
# Display the version matrix for a cluster stack.
#
# Iterates over per-minor-version directories (1-XX/) and shows K8s versions,
# addon versions from Chart.yaml, and addon overrides from stack.yaml.
#
# Usage:
#   ./hack/show-matrix.sh [options] [stack-dir]
#
# Options:
#   --markdown    Output as a GitHub-flavored Markdown table
#
# If <stack-dir> is omitted, it is derived from $PROVIDER and $CLUSTER_STACK
# (default: providers/openstack/scs).
#
# Environment:
#   PROVIDER        Provider name (default: openstack)
#   CLUSTER_STACK   Cluster stack name (default: scs)
#   OCI_REGISTRY    OCI registry to query for CS versions (optional)
#   OCI_REPOSITORY  OCI repository to query for CS versions (optional)

set -euo pipefail

MARKDOWN=false
BASE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --markdown) MARKDOWN=true; shift ;;
        -*)         echo "Unknown option: $1" >&2; exit 1 ;;
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

# ============================================
# Collect data from all version directories
# ============================================

# First pass: discover all addon names across all versions
declare -A ALL_ADDON_NAMES
declare -A STACK_ADDONS  # key: "1-XX:addon_name" → version

PROVIDER_NAME=""
STACK_NAME=""

for version_dir in "$BASE_DIR"/1-*/; do
    [[ -d "$version_dir" ]] || continue
    local_dir=$(basename "$version_dir")

    stack_yaml="$version_dir/stack.yaml"
    [[ -f "$stack_yaml" ]] || continue

    if [[ -z "$PROVIDER_NAME" ]]; then
        PROVIDER_NAME=$(yq -r '.provider' "$stack_yaml")
        STACK_NAME=$(yq -r '.clusterStackName' "$stack_yaml")
    fi

    # Collect chart dependency versions
    for chart_file in "$version_dir"/cluster-addon/*/Chart.yaml; do
        [[ -f "$chart_file" ]] || continue
        num_deps=$(yq '.dependencies | length' "$chart_file" 2>/dev/null || echo "0")
        for ((i=0; i<num_deps; i++)); do
            dep_name=$(yq -r ".dependencies[$i].name" "$chart_file")
            dep_version=$(yq -r ".dependencies[$i].version" "$chart_file")
            ALL_ADDON_NAMES["$dep_name"]=1
            STACK_ADDONS["${local_dir}:${dep_name}"]="$dep_version"
        done
    done

    # Collect stack.yaml addon overrides (these take precedence at build time)
    has_addons=$(yq -e '.addons' "$stack_yaml" >/dev/null 2>&1 && echo "true" || echo "false")
    if [[ "$has_addons" == "true" ]]; then
        addon_keys=$(yq -r '.addons | keys | .[]' "$stack_yaml")
        for key in $addon_keys; do
            value=$(yq -r ".addons.\"${key}\"" "$stack_yaml")
            # Map short names to chart names for display
            case "$key" in
                ccm) chart_key="openstack-cloud-controller-manager" ;;
                csi) chart_key="openstack-cinder-csi" ;;
                *)   chart_key="$key" ;;
            esac
            ALL_ADDON_NAMES["$chart_key"]=1
            # Mark with range (overrides chart default)
            STACK_ADDONS["${local_dir}:${chart_key}"]="$value"
        done
    fi
done

if [[ -z "$PROVIDER_NAME" ]]; then
    echo "No valid version directories found in: $BASE_DIR" >&2
    exit 1
fi

# Sort addon names
SORTED_ADDONS=($(echo "${!ALL_ADDON_NAMES[@]}" | tr ' ' '\n' | sort))

# ============================================
# Collect row data
# ============================================

declare -a ROW_VERSIONS=()
declare -a ROW_K8S=()
declare -a ROW_CS=()
declare -A ROW_ADDON_VERSIONS  # key: "row_idx:addon_name" → version

ROW_IDX=0
for version_dir in "$BASE_DIR"/1-*/; do
    [[ -d "$version_dir" ]] || continue
    local_dir=$(basename "$version_dir")
    stack_yaml="$version_dir/stack.yaml"
    [[ -f "$stack_yaml" ]] || continue

    k8s_version=$(yq -r '.kubernetesVersion' "$stack_yaml")
    k8s_short=$(echo "$k8s_version" | grep -oP '^\d+\.\d+')
    k8s_dash="${k8s_short//./-}"

    # Query OCI for CS version
    CS_VERSION="-"
    if [[ -n "${OCI_REGISTRY:-}" && -n "${OCI_REPOSITORY:-}" ]] && command -v oras >/dev/null 2>&1; then
        TAG_PREFIX="${PROVIDER_NAME}-${STACK_NAME}-${k8s_dash}"
        LATEST=$(oras repo tags "${OCI_REGISTRY}/${OCI_REPOSITORY}" 2>/dev/null | \
            grep -oP "^${TAG_PREFIX}-v\K[0-9]+" | sort -n | tail -1 || echo "")
        [[ -n "$LATEST" ]] && CS_VERSION="v${LATEST}"
    fi

    ROW_VERSIONS+=("$local_dir")
    ROW_K8S+=("$k8s_version")
    ROW_CS+=("$CS_VERSION")

    for addon in "${SORTED_ADDONS[@]}"; do
        ver="${STACK_ADDONS["${local_dir}:${addon}"]:-"-"}"
        ROW_ADDON_VERSIONS["${ROW_IDX}:${addon}"]="$ver"
    done
    ((ROW_IDX++)) || true
done

# Short display name for an addon
addon_short() {
    echo "$1" | sed 's/openstack-cloud-controller-manager/os-ccm/; s/openstack-cinder-csi/os-csi/'
}

# ============================================
# Print the matrix
# ============================================

if [[ "$MARKDOWN" == true ]]; then
    # --- Markdown table output ---
    HEADER="| Version | K8s | CS Version"
    SEPARATOR="|---------|-----|----------"
    for addon in "${SORTED_ADDONS[@]}"; do
        HEADER+=" | $(addon_short "$addon")"
        SEPARATOR+="|---------"
    done
    HEADER+=" |"
    SEPARATOR+="|"
    echo "$HEADER"
    echo "$SEPARATOR"

    for ((i=0; i<ROW_IDX; i++)); do
        ROW="| ${ROW_VERSIONS[$i]} | ${ROW_K8S[$i]} | ${ROW_CS[$i]}"
        for addon in "${SORTED_ADDONS[@]}"; do
            ROW+=" | ${ROW_ADDON_VERSIONS["${i}:${addon}"]:-"-"}"
        done
        ROW+=" |"
        echo "$ROW"
    done
else
    # --- Terminal table output ---
    echo "Cluster Stack: ${PROVIDER_NAME}/${STACK_NAME}"
    echo ""

    HEADER=$(printf "%-8s | %-12s | %-10s" "Version" "K8s Version" "CS Version")
    SEP=$(printf -- "%-8s-+-%-12s-+-%-10s" "--------" "------------" "----------")
    for addon in "${SORTED_ADDONS[@]}"; do
        HEADER+=$(printf " | %-10s" "$(addon_short "$addon")")
        SEP+=$(printf -- "-+-%-10s" "----------")
    done
    echo "$HEADER"
    echo "$SEP"

    for ((i=0; i<ROW_IDX; i++)); do
        ROW=$(printf "%-8s | %-12s | %-10s" "${ROW_VERSIONS[$i]}" "${ROW_K8S[$i]}" "${ROW_CS[$i]}")
        for addon in "${SORTED_ADDONS[@]}"; do
            ROW+=$(printf " | %-10s" "${ROW_ADDON_VERSIONS["${i}:${addon}"]:-"-"}")
        done
        echo "$ROW"
    done
fi
