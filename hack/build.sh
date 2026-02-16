#!/usr/bin/env bash
# Build and optionally publish cluster-stack release artifacts.
#
# Usage:
#   ./hack/build.sh [stack-dir] [options]
#
# If <stack-dir> is omitted, it is derived from $PROVIDER and $CLUSTER_STACK
# (default: providers/openstack/scs2).
#
# Options:
#   --version <X.Y>   Build for a specific K8s minor version (e.g., 1.34)
#   --all             Build for all K8s versions in versions.yaml
#   --publish         Push to OCI registry after building
#   --validate        Validate addon bundle structure against clusteraddon.yaml
#
# Without --version or --all, builds for the version in csctl.yaml.
#
# Environment:
#   PROVIDER          Provider name (default: openstack)
#   CLUSTER_STACK     Cluster stack name (default: scs2)
#   OCI_REGISTRY      OCI registry (default: ttl.sh)
#   OCI_REPOSITORY    OCI repository (auto-generated for ttl.sh)
#   OCI_USERNAME      OCI auth username (optional)
#   OCI_PASSWORD      OCI auth password (optional)
#   OCI_ACCESS_TOKEN  OCI auth token (optional, alternative to user/pass)
#   OUTPUT_DIR        Output directory (default: .release)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ============================================
# Argument parsing
# ============================================

STACK_DIR=""
TARGET_VERSION=""
BUILD_ALL=false
PUBLISH=false
VALIDATE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  TARGET_VERSION="$2"; shift 2 ;;
        --all)      BUILD_ALL=true; shift ;;
        --publish)  PUBLISH=true; shift ;;
        --validate) VALIDATE=true; shift ;;
        -*)         echo "Unknown option: $1"; exit 1 ;;
        *)
            if [[ -z "$STACK_DIR" ]]; then
                STACK_DIR="$1"; shift
            else
                echo "Unexpected argument: $1"; exit 1
            fi
            ;;
    esac
done

if [[ -z "$STACK_DIR" ]]; then
    STACK_DIR="providers/${PROVIDER:-openstack}/${CLUSTER_STACK:-scs2}"
fi

if [[ ! -d "$STACK_DIR" ]]; then
    echo "Stack directory not found: $STACK_DIR"
    exit 1
fi

if [[ ! -f "$STACK_DIR/csctl.yaml" ]]; then
    echo "csctl.yaml not found in: $STACK_DIR"
    exit 1
fi

# ============================================
# Read stack configuration
# ============================================

PROVIDER=$(yq '.config.provider.type' "$STACK_DIR/csctl.yaml")
CLUSTER_STACK=$(yq '.config.clusterStackName' "$STACK_DIR/csctl.yaml")
OUTPUT_DIR="${OUTPUT_DIR:-.release}"

# ============================================
# Determine which K8s versions to build
# ============================================

collect_versions() {
    if [[ "$BUILD_ALL" == "true" && -f "$STACK_DIR/versions.yaml" ]]; then
        yq -r '.[].kubernetes' "$STACK_DIR/versions.yaml"
    elif [[ -n "$TARGET_VERSION" && -f "$STACK_DIR/versions.yaml" ]]; then
        yq -r ".[].kubernetes | select(test(\"^${TARGET_VERSION}\"))" "$STACK_DIR/versions.yaml"
    else
        # Fall back to csctl.yaml (strip leading 'v')
        yq -r '.config.kubernetesVersion' "$STACK_DIR/csctl.yaml" | sed 's/^v//'
    fi
}

VERSIONS=$(collect_versions)

if [[ -z "$VERSIONS" ]]; then
    echo "No matching K8s versions found"
    if [[ -f "$STACK_DIR/versions.yaml" ]]; then
        echo "Available versions:"
        yq -r '.[].kubernetes' "$STACK_DIR/versions.yaml" | sed 's/^/  - /'
    fi
    exit 1
fi

# ============================================
# OCI registry setup
# ============================================

setup_oci() {
    if [[ -z "${OCI_REGISTRY:-}" ]]; then
        if ! command -v git >/dev/null 2>&1; then
            echo "git not found — required for auto-generating ttl.sh repository names"
            exit 1
        fi
        DATE_YYYYMMDD="${OCI_DATE:-$(date +%Y%m%d)}"
        export OCI_REGISTRY="ttl.sh"
        export OCI_REPOSITORY="clusterstacks-${DATE_YYYYMMDD}"
        echo "Auto-configured ttl.sh: $OCI_REGISTRY/$OCI_REPOSITORY (expires in 24h)"
    fi
}

# Determine release version for a given K8s minor version.
# Stable: queries OCI for highest vN tag, returns v(N+1). Dev: returns v0-<suffix>.
get_release_version() {
    local k8s_short="$1"
    local k8s_dash="${k8s_short//./-}"
    local tag_prefix="${PROVIDER}-${CLUSTER_STACK}-${k8s_dash}"

    if [[ "${OCI_REGISTRY:-}" == "ttl.sh" ]] || [[ -z "${OCI_REPOSITORY:-}" ]]; then
        # Dev version
        local timestamp
        timestamp=$(date +%s)
        echo "v0-ttl.${timestamp}"
        return
    fi

    # Query OCI for existing stable versions
    local latest=0
    if command -v oras >/dev/null 2>&1; then
        local tags
        tags=$(oras repo tags "${OCI_REGISTRY}/${OCI_REPOSITORY}" 2>/dev/null || echo "")
        if [[ -n "$tags" ]]; then
            latest=$(echo "$tags" | grep -oP "^${tag_prefix}-v\K[0-9]+" | sort -n | tail -1 || echo "0")
            latest="${latest:-0}"
        fi
    fi

    echo "v$((latest + 1))"
}

# ============================================
# Build one K8s version
# ============================================

build_version() {
    local k8s_version="$1"
    local k8s_short
    k8s_short=$(echo "$k8s_version" | grep -oP '^\d+\.\d+')
    local k8s_dash="${k8s_short//./-}"

    echo ""
    echo "Building ${PROVIDER}-${CLUSTER_STACK} for K8s ${k8s_version}"
    echo "---"

    # Get release version
    if [[ "$PUBLISH" == "true" ]]; then
        setup_oci
    fi
    local release_version
    release_version=$(get_release_version "$k8s_short")
    local release_dir="${OUTPUT_DIR}/${PROVIDER}-${CLUSTER_STACK}-${k8s_dash}-${release_version}"

    mkdir -p "$release_dir"

    # ---- Prepare working copy ----
    local work_dir
    work_dir=$(mktemp -d)
    trap "rm -rf $work_dir" RETURN

    cp -r "$STACK_DIR/cluster-class" "$work_dir/"
    cp -r "$STACK_DIR/cluster-addon" "$work_dir/"

    # Patch cluster-class Chart.yaml: set name and version
    local class_chart="$work_dir/cluster-class/Chart.yaml"
    yq -i ".name = \"${PROVIDER}-${CLUSTER_STACK}-${k8s_dash}-cluster-class\"" "$class_chart"
    yq -i ".version = \"${release_version}\"" "$class_chart"

    # Patch csctl.yaml kubernetes version
    if [[ -f "$STACK_DIR/csctl.yaml" ]]; then
        cp "$STACK_DIR/csctl.yaml" "$work_dir/csctl.yaml"
        yq -i ".config.kubernetesVersion = \"v${k8s_version}\"" "$work_dir/csctl.yaml"
    fi

    # Patch cluster-class values.yaml image names (if the field exists)
    local class_values="$work_dir/cluster-class/values.yaml"
    if [[ -f "$class_values" ]] && yq -e '.images.controlPlane.name' "$class_values" >/dev/null 2>&1; then
        yq -i ".images.controlPlane.name = \"ubuntu-capi-image-v${k8s_version}\"" "$class_values"
        yq -i ".images.worker.name = \"ubuntu-capi-image-v${k8s_version}\"" "$class_values"
    fi

    # ---- Patch addon versions from versions.yaml ----
    if [[ -f "$STACK_DIR/versions.yaml" ]]; then
        # Get the entry matching this K8s version
        local version_entry
        version_entry=$(yq -r ".[] | select(.kubernetes | test(\"^${k8s_short}\"))" "$STACK_DIR/versions.yaml")

        if [[ -n "$version_entry" ]]; then
            # Get all keys except metadata fields — these are addon overrides
            local addon_keys
            addon_keys=$(echo "$version_entry" | yq -r 'keys | .[] | select(test("^(kubernetes|ubuntu)$") | not)')

            for addon_key in $addon_keys; do
                local addon_version
                addon_version=$(echo "$version_entry" | yq -r ".\"${addon_key}\"")

                # Find Chart.yaml files containing this dependency and patch
                for chart_file in "$work_dir"/cluster-addon/*/Chart.yaml; do
                    [[ -f "$chart_file" ]] || continue
                    local has_dep
                    has_dep=$(yq ".dependencies[] | select(.name == \"${addon_key}\") | .name" "$chart_file" 2>/dev/null || echo "")
                    if [[ -n "$has_dep" ]]; then
                        yq -i "(.dependencies[] | select(.name == \"${addon_key}\")).version = \"${addon_version}\"" "$chart_file"
                        echo "  Patched ${addon_key} -> ${addon_version}"
                    fi
                done
            done
        fi
    fi

    # ---- Package cluster-class ----
    echo "  Packaging cluster-class..."
    rm -rf "$work_dir/cluster-class/charts"
    helm package "$work_dir/cluster-class" -d "$release_dir/" > /dev/null
    echo "  cluster-class packaged"

    # ---- Package cluster-addon bundle ----
    echo "  Packaging cluster-addon..."
    local addon_temp
    addon_temp=$(mktemp -d)
    local addon_count=0

    for addon_dir in "$work_dir"/cluster-addon/*/; do
        [[ -d "$addon_dir" ]] || continue
        local addon_name
        addon_name=$(basename "$addon_dir")
        cp -r "$addon_dir" "$addon_temp/$addon_name"
        rm -rf "$addon_temp/$addon_name/charts"
        addon_count=$((addon_count + 1))
    done

    if [[ $addon_count -eq 0 ]]; then
        echo "  No addon subdirectories found"
        rm -rf "$addon_temp"
        exit 1
    fi

    local addon_tgz="${PROVIDER}-${CLUSTER_STACK}-${k8s_dash}-cluster-addon-${release_version}.tgz"
    (cd "$addon_temp" && tar -czf "$(cd "$REPO_ROOT" && pwd)/$release_dir/$addon_tgz" */)
    rm -rf "$addon_temp"
    echo "  cluster-addon packaged ($addon_count addons)"

    # ---- Validate addon bundle ----
    if [[ "$VALIDATE" == "true" && -f "$STACK_DIR/clusteraddon.yaml" ]]; then
        echo "  Validating addon bundle..."
        local validate_dir
        validate_dir=$(mktemp -d)
        tar -xzf "$release_dir/$addon_tgz" -C "$validate_dir"

        local expected_addons
        expected_addons=$(yq '.addonStages | to_entries | .[].value[].name' "$STACK_DIR/clusteraddon.yaml" 2>/dev/null | sort -u)

        local failed=false
        for addon in $expected_addons; do
            if [[ ! -d "$validate_dir/$addon" ]]; then
                echo "    Missing addon: $addon (referenced in clusteraddon.yaml)"
                failed=true
            fi
        done
        rm -rf "$validate_dir"

        if [[ "$failed" == "true" ]]; then
            exit 1
        fi
        echo "  Validation passed"
    fi

    # ---- Copy clusteraddon.yaml ----
    if [[ -f "$STACK_DIR/clusteraddon.yaml" ]]; then
        cp "$STACK_DIR/clusteraddon.yaml" "$release_dir/"
    elif [[ -f "$STACK_DIR/cluster-addon-values.yaml" ]]; then
        cp "$STACK_DIR/cluster-addon-values.yaml" "$release_dir/"
    fi

    # ---- Generate metadata.yaml ----
    local git_hash
    git_hash=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

    cat > "$release_dir/metadata.yaml" <<EOF
apiVersion: metadata.clusterstack.x-k8s.io/v1alpha1
versions:
    kubernetes: v${k8s_version}
    clusterStack: ${release_version}
    components:
        clusterAddon: ${release_version}
        nodeImage: ${release_version}
EOF

    cat > "$release_dir/hashes.json" <<EOF
{
  "clusterStack": "${git_hash}"
}
EOF

    echo "  Output: $release_dir"
    echo ""
    echo "  Contents:"
    ls -1 "$release_dir/" | sed 's/^/    /'

    # ---- Publish ----
    if [[ "$PUBLISH" == "true" ]]; then
        publish_version "$release_dir" "$k8s_dash" "$release_version"
    fi
}

# ============================================
# Publish to OCI
# ============================================

publish_version() {
    local release_dir="$1"
    local k8s_dash="$2"
    local release_version="$3"
    local oci_tag="${PROVIDER}-${CLUSTER_STACK}-${k8s_dash}-${release_version}"

    if [[ -z "${OCI_REGISTRY:-}" || -z "${OCI_REPOSITORY:-}" ]]; then
        echo "  OCI_REGISTRY or OCI_REPOSITORY not set"
        exit 1
    fi

    if ! command -v oras >/dev/null 2>&1; then
        echo "  oras not found — install from https://oras.land/docs/installation"
        exit 1
    fi

    echo ""
    echo "  Publishing to $OCI_REGISTRY/$OCI_REPOSITORY:$oci_tag"

    local oras_opts=()
    if [[ -n "${OCI_USERNAME:-}" && -n "${OCI_PASSWORD:-}" ]]; then
        oras_opts+=(--username "$OCI_USERNAME" --password "$OCI_PASSWORD")
    elif [[ -n "${OCI_ACCESS_TOKEN:-}" ]]; then
        oras_opts+=(--password "$OCI_ACCESS_TOKEN")
    fi

    local files=()
    for f in "$release_dir"/*; do
        [[ -f "$f" ]] && files+=("$(basename "$f")")
    done

    (cd "$release_dir" && oras push \
        "$OCI_REGISTRY/$OCI_REPOSITORY:$oci_tag" \
        --artifact-type application/vnd.clusterstack.release \
        "${oras_opts[@]}" \
        "${files[@]}")

    echo "  Published: $OCI_REGISTRY/$OCI_REPOSITORY:$oci_tag"
    echo "  Pull:      oras pull $OCI_REGISTRY/$OCI_REPOSITORY:$oci_tag"
}

# ============================================
# Main
# ============================================

echo "Cluster Stack: ${PROVIDER}/${CLUSTER_STACK}"
echo "K8s versions:  $(echo "$VERSIONS" | tr '\n' ' ')"
echo ""

for version in $VERSIONS; do
    build_version "$version"
done

echo ""
echo "Done."
