#!/usr/bin/env bash
# Build and optionally publish cluster-stack release artifacts.
#
# Usage:
#   ./hack/build.sh [stack-dir] [options]
#
# The <stack-dir> is the base directory containing per-minor-version subdirs
# (e.g., providers/openstack/scs). If omitted, it is derived from $PROVIDER
# and $CLUSTER_STACK (default: providers/openstack/scs).
#
# Options:
#   --version <X.Y>   Build for a specific K8s minor version (e.g., 1.34)
#   --all             Build for all K8s versions (all 1-* subdirs)
#   --publish         Push to OCI registry after building
#   --install-cso     Install/upgrade the Cluster Stack Operator with matching OCI config
#   --validate        Validate addon bundle structure against clusteraddon.yaml
#
# Without --version or --all, builds the highest 1-* subdirectory.
#
# Each 1-XX/ subdir must contain a stack.yaml with at minimum:
#   provider: openstack
#   clusterStackName: scs
#   kubernetesVersion: 1.34        # minor-only or with patch (1.34.3)
#
# Addon versions are read directly from cluster-addon/*/Chart.yaml as
# maintained by `just update addons`. The build does not resolve or
# modify addon versions.
#
# Environment:
#   PROVIDER          Provider name (default: openstack)
#   CLUSTER_STACK     Cluster stack name (default: scs)
#   OCI_REGISTRY      OCI registry (default: ttl.sh)
#   OCI_REPOSITORY    OCI repository (auto-generated for ttl.sh)
#   OCI_USERNAME      OCI auth username (optional)
#   OCI_PASSWORD      OCI auth password (optional)
#   OCI_ACCESS_TOKEN  OCI auth token (optional, alternative to user/pass)
#   OUTPUT_DIR        Output directory (default: .release)
#   CSO_CHART         CSO Helm chart reference (default: oci://registry.scs.community/cluster-stacks/cso)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
YQ_VERSION="$(yq --version 2>/dev/null || true)"

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

extract_latest_release_number() {
    local prefix="$1"

    awk -v prefix="${prefix}-v" 'index($0, prefix) == 1 {
        suffix = substr($0, length(prefix) + 1)
        if (suffix ~ /^[0-9]+$/) {
            print suffix
        }
    }' | sort -n | tail -1
}

yq_edit_in_place() {
    local expression="$1"
    local file="$2"

    if [[ "$YQ_VERSION" == *"https://github.com/mikefarah/yq/"* ]]; then
        yq -i "$expression" "$file"
    else
        yq -y -i "$expression" "$file"
    fi
}

yq_has_path() {
    local expression="$1"
    local file="$2"

    yq -e "$expression" "$file" >/dev/null 2>&1
}

require_command yq
require_command curl
require_command jq
require_command helm

# ============================================
# Argument parsing
# ============================================

BASE_DIR=""
TARGET_VERSION=""
BUILD_ALL=false
PUBLISH=false
INSTALL_CSO=false
VALIDATE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      TARGET_VERSION="$2"; shift 2 ;;
        --all)          BUILD_ALL=true; shift ;;
        --publish)      PUBLISH=true; shift ;;
        --install-cso)  INSTALL_CSO=true; shift ;;
        --validate)     VALIDATE=true; shift ;;
        -*)             echo "Unknown option: $1"; exit 1 ;;
        *)
            if [[ -z "$BASE_DIR" ]]; then
                BASE_DIR="$1"; shift
            else
                echo "Unexpected argument: $1"; exit 1
            fi
            ;;
    esac
done

if [[ -z "$BASE_DIR" ]]; then
    BASE_DIR="providers/${PROVIDER:-openstack}/${CLUSTER_STACK:-scs}"
fi

if [[ ! -d "$BASE_DIR" ]]; then
    echo "Stack base directory not found: $BASE_DIR"
    exit 1
fi

OUTPUT_DIR="${OUTPUT_DIR:-.release}"

# ============================================
# Resolve which minor-version directories to build
# ============================================

collect_version_dirs() {
    if [[ "$BUILD_ALL" == "true" ]]; then
        # All 1-* subdirectories, sorted
        for d in "$BASE_DIR"/1-*/; do
            [[ -d "$d" ]] && echo "$d"
        done | sort -t- -k2 -n
    elif [[ -n "$TARGET_VERSION" ]]; then
        # --version 1.34 → look for 1-34/
        local minor_dash="${TARGET_VERSION//./-}"
        local target_dir="$BASE_DIR/$minor_dash"
        if [[ ! -d "$target_dir" ]]; then
            echo "Version directory not found: $target_dir" >&2
            echo "Available:" >&2
            ls -d "$BASE_DIR"/1-*/ 2>/dev/null | sed 's|.*/||; s|/$||; s/^/  /' >&2
            return 1
        fi
        echo "$target_dir"
    else
        # Default: highest 1-* directory
        local highest
        highest=$(ls -d "$BASE_DIR"/1-*/ 2>/dev/null | sort -t- -k2 -n | tail -1)
        if [[ -z "$highest" ]]; then
            echo "No version directories found in: $BASE_DIR" >&2
            return 1
        fi
        echo "$highest"
    fi
}

VERSION_DIRS=$(collect_version_dirs)

if [[ -z "$VERSION_DIRS" ]]; then
    echo "No version directories to build"
    exit 1
fi

# ============================================
# OCI registry setup
# ============================================

setup_oci() {
    if [[ -z "${OCI_REGISTRY:-}" ]]; then
        DATE_YYYYMMDD="${OCI_DATE:-$(date +%Y%m%d)}"
        export OCI_REGISTRY="ttl.sh"
        export OCI_REPOSITORY="clusterstacks-${DATE_YYYYMMDD}"
        echo "Auto-configured ttl.sh: $OCI_REGISTRY/$OCI_REPOSITORY (expires in 24h)"
    fi
}

OCI_SETUP_DONE=false
ensure_oci() {
    if [[ "$OCI_SETUP_DONE" != "true" ]]; then
        setup_oci
        OCI_SETUP_DONE=true
    fi
}

# ============================================
# CSO installation
# ============================================

CSO_CHART="${CSO_CHART:-oci://registry.scs.community/cluster-stacks/cso}"

install_cso() {
    if ! command -v helm >/dev/null 2>&1; then
        echo "helm not found — install from https://helm.sh/docs/intro/install/"
        exit 1
    fi

    echo "Installing/upgrading CSO..."
    echo "  Chart:      $CSO_CHART"
    echo "  OCI config: $OCI_REGISTRY/$OCI_REPOSITORY"
    echo ""

    helm upgrade -i cso "$CSO_CHART" \
        --namespace cso-system --create-namespace \
        --set controllerManager.manager.source=oci \
        --set "clusterStackVariables.ociRegistry=${OCI_REGISTRY}" \
        --set "clusterStackVariables.ociRepository=${OCI_REPOSITORY}"

    echo ""
}

# Determine release version for a given K8s minor version.
# Stable: queries OCI for highest vN tag, returns v(N+1). Dev: returns v0-<suffix>.
get_release_version() {
    local provider="$1"
    local stack_name="$2"
    local k8s_dash="$3"
    local tag_prefix="${provider}-${stack_name}-${k8s_dash}"

    if [[ "${OCI_REGISTRY:-}" == "ttl.sh" ]] || [[ -z "${OCI_REPOSITORY:-}" ]]; then
        # Dev version
        local timestamp
        timestamp=$(date +%s)
        echo "v0-ttl.${timestamp}"
        return
    fi

    local oras_opts=()
    if [[ -n "${OCI_USERNAME:-}" && -n "${OCI_PASSWORD:-}" ]]; then
        oras_opts+=(--username "$OCI_USERNAME" --password "$OCI_PASSWORD")
    elif [[ -n "${OCI_ACCESS_TOKEN:-}" ]]; then
        oras_opts+=(--password "$OCI_ACCESS_TOKEN")
    fi

    # Query OCI for existing stable versions
    require_command oras

    local latest=0
    local tags
    if ! tags=$(oras repo tags "${OCI_REGISTRY}/${OCI_REPOSITORY}" "${oras_opts[@]}" 2>/dev/null); then
        echo "Failed to query OCI tags from ${OCI_REGISTRY}/${OCI_REPOSITORY}." >&2
        exit 1
    fi
    if [[ -n "$tags" ]]; then
        latest=$(echo "$tags" | extract_latest_release_number "$tag_prefix" || echo "0")
        latest="${latest:-0}"
    fi

    echo "v$((latest + 1))"
}

# ============================================
# Resolve K8s patch version
# ============================================

# Given a version like "1.34" (no patch), resolve to latest patch.
# If already has patch (1.34.3), return as-is.
resolve_k8s_version() {
    local version="$1"
    local provider="$2"

    # Already has patch version
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$version"
        return
    fi

    # Minor-only: resolve latest patch
    if [[ "$provider" == "docker" ]]; then
        # Query Docker Hub for kindest/node tags
        local latest
        if ! latest=$(curl -sfL "https://registry.hub.docker.com/v2/repositories/kindest/node/tags?page_size=100&name=v${version}." 2>/dev/null \
            | jq -r '.results[].name' 2>/dev/null \
            | grep -E "^v${version}\.[0-9]+$" \
            | sed 's/^v//' \
            | sort -V \
            | tail -1); then
            echo "Failed to resolve the latest Docker patch version for Kubernetes ${version}." >&2
            exit 1
        fi
        if [[ -n "$latest" ]]; then
            echo "$latest"
            return
        fi
    else
        # Query GitHub for K8s releases
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
    fi

    echo "Could not resolve a stable patch version for Kubernetes ${version}." >&2
    exit 1
}

# ============================================
# Generate csctl.yaml for release artifact
# ============================================

generate_csctl_yaml() {
    local provider="$1"
    local stack_name="$2"
    local k8s_version="$3"
    local output_file="$4"

    cat > "$output_file" <<EOF
apiVersion: csctl.clusterstack.x-k8s.io/v1alpha1
config:
  provider:
    type: ${provider}
  clusterStackName: ${stack_name}
  kubernetesVersion: v${k8s_version}
EOF
}

# ============================================
# Build one version directory
# ============================================

build_version_dir() {
    local version_dir="$1"
    # Remove trailing slash
    version_dir="${version_dir%/}"

    local stack_yaml="$version_dir/stack.yaml"
    if [[ ! -f "$stack_yaml" ]]; then
        echo "stack.yaml not found in: $version_dir"
        exit 1
    fi

    # Read stack configuration
    local provider stack_name k8s_version_raw
    provider=$(yq -r '.provider' "$stack_yaml")
    stack_name=$(yq -r '.clusterStackName' "$stack_yaml")
    k8s_version_raw=$(yq -r '.kubernetesVersion' "$stack_yaml")

    # Resolve K8s patch version
    local k8s_version
    k8s_version=$(resolve_k8s_version "$k8s_version_raw" "$provider")
    local k8s_short
    k8s_short=$(extract_k8s_minor_version "$k8s_version")
    local k8s_dash="${k8s_short//./-}"

    echo ""
    echo "Building ${provider}-${stack_name} for K8s ${k8s_version} (from ${version_dir})"
    echo "---"

    # Get release version
    local release_version
    release_version=$(get_release_version "$provider" "$stack_name" "$k8s_dash")
    local release_dir="${OUTPUT_DIR}/${provider}-${stack_name}-${k8s_dash}-${release_version}"

    mkdir -p "$release_dir"

    # ---- Prepare working copy ----
    local work_dir
    work_dir=$(mktemp -d)
    trap "rm -rf $work_dir" RETURN

    cp -r "$version_dir/cluster-class" "$work_dir/"
    cp -r "$version_dir/cluster-addon" "$work_dir/"

    # Patch cluster-class Chart.yaml: set name and version
    local class_chart="$work_dir/cluster-class/Chart.yaml"
    yq_edit_in_place ".name = \"${provider}-${stack_name}-${k8s_dash}-cluster-class\"" "$class_chart"
    yq_edit_in_place ".version = \"${release_version}\"" "$class_chart"

    # Generate csctl.yaml for release artifact (backwards compatibility)
    generate_csctl_yaml "$provider" "$stack_name" "$k8s_version" "$work_dir/csctl.yaml"

    # Patch cluster-class values.yaml image names (if the field exists)
    local class_values="$work_dir/cluster-class/values.yaml"
    if [[ -f "$class_values" ]]; then
        if yq_has_path '.images.controlPlane.name' "$class_values"; then
            yq_edit_in_place ".images.controlPlane.name = \"ubuntu-capi-image-v${k8s_version}\"" "$class_values"
            yq_edit_in_place ".images.worker.name = \"ubuntu-capi-image-v${k8s_version}\"" "$class_values"
        elif yq_has_path '.images.controlPlane[0].name' "$class_values"; then
            yq_edit_in_place ".images.controlPlane[0].name = \"registry.scs.community/docker.io/kindest/node:v${k8s_version}\"" "$class_values"
            yq_edit_in_place ".images.worker[0].name = \"registry.scs.community/docker.io/kindest/node:v${k8s_version}\"" "$class_values"
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

    local addon_tgz="${provider}-${stack_name}-${k8s_dash}-cluster-addon-${release_version}.tgz"
    (cd "$addon_temp" && tar -czf "$(cd "$REPO_ROOT" && pwd)/$release_dir/$addon_tgz" */)
    rm -rf "$addon_temp"
    echo "  cluster-addon packaged ($addon_count addons)"

    # ---- Validate addon bundle ----
    if [[ "$VALIDATE" == "true" && -f "$version_dir/clusteraddon.yaml" ]]; then
        echo "  Validating addon bundle..."
        local validate_dir
        validate_dir=$(mktemp -d)
        tar -xzf "$release_dir/$addon_tgz" -C "$validate_dir"

        local expected_addons
        expected_addons=$(yq '.addonStages | to_entries | .[].value[].name' "$version_dir/clusteraddon.yaml" 2>/dev/null | sort -u)

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
    if [[ -f "$version_dir/clusteraddon.yaml" ]]; then
        cp "$version_dir/clusteraddon.yaml" "$release_dir/"
    fi

    # ---- Copy generated csctl.yaml ----
    cp "$work_dir/csctl.yaml" "$release_dir/"

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
        publish_version "$release_dir" "$provider" "$stack_name" "$k8s_dash" "$release_version"
    fi

    # Track for "next steps" output
    BUILT_K8S_SHORTS+=("$k8s_short")
    BUILT_CS_VERSIONS+=("$release_version")
    BUILT_PROVIDERS+=("$provider")
    BUILT_STACK_NAMES+=("$stack_name")
}

# ============================================
# Publish to OCI
# ============================================

publish_version() {
    local release_dir="$1"
    local provider="$2"
    local stack_name="$3"
    local k8s_dash="$4"
    local release_version="$5"
    local oci_tag="${provider}-${stack_name}-${k8s_dash}-${release_version}"

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

# Resolve OCI config once (needed for --publish and/or --install-cso)
if [[ "$PUBLISH" == "true" || "$INSTALL_CSO" == "true" ]]; then
    ensure_oci
fi

# Install/upgrade CSO if requested
if [[ "$INSTALL_CSO" == "true" ]]; then
    install_cso
fi

echo "Stack base: $BASE_DIR"
echo "Version dirs: $(echo "$VERSION_DIRS" | tr '\n' ' ')"
echo ""

# Track built versions for "next steps" output
declare -a BUILT_K8S_SHORTS=()
declare -a BUILT_CS_VERSIONS=()
declare -a BUILT_PROVIDERS=()
declare -a BUILT_STACK_NAMES=()

for version_dir in $VERSION_DIRS; do
    build_version_dir "$version_dir"
done

echo ""
echo "Done."

# ============================================
# Next steps (after publish)
# ============================================

if [[ "$PUBLISH" == "true" && ${#BUILT_K8S_SHORTS[@]} -gt 0 ]]; then
    echo ""
    echo "================================================================"
    echo "Next steps"
    echo "================================================================"

    if [[ "$INSTALL_CSO" != "true" ]]; then
        echo ""
        echo "1. Install the Cluster Stack Operator (or re-run with --install-cso):"
        echo ""
        echo "   helm upgrade -i cso ${CSO_CHART} \\"
        echo "     --namespace cso-system --create-namespace \\"
        echo "     --set controllerManager.manager.source=oci \\"
        echo "     --set clusterStackVariables.ociRegistry=\"${OCI_REGISTRY}\" \\"
        echo "     --set clusterStackVariables.ociRepository=\"${OCI_REPOSITORY}\""
        echo ""
        echo "2. Apply the ClusterStack resource(s):"
    else
        echo ""
        echo "Apply the ClusterStack resource(s):"
    fi
    echo ""
    for ((i=0; i<${#BUILT_K8S_SHORTS[@]}; i++)); do
        local_provider="${BUILT_PROVIDERS[$i]}"
        local_stack="${BUILT_STACK_NAMES[$i]}"
        local_k8s="${BUILT_K8S_SHORTS[$i]}"
        local_version="${BUILT_CS_VERSIONS[$i]}"
        echo "   CLUSTER_STACK=${local_stack} ./hack/generate-resources.sh --version ${local_k8s} --cs-version ${local_version} | kubectl apply -f -"
    done
    echo ""
fi
