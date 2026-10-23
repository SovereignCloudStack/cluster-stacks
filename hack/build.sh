#!/usr/bin/env bash
# Build and optionally publish cluster-stack release artifacts.
#
# Usage:
#   ./hack/build.sh [stack-dir] [options]
#
# The <stack-dir> is the base directory containing per-minor-version subdirs
# (e.g., providers/openstack/scs). If omitted, it is derived from $PROVIDER
# and $CLUSTER_STACK (default: providers/openstack/scs). Relative paths are
# resolved from the repository root.
#
# Options:
#   --version <X.Y>   Build for a specific K8s minor version (e.g., 1.34)
#   --release-version <vN>  Use a specific cluster-stack release version with a single --version build (e.g., v1)
#   --all             Build for all K8s versions (all 1-* subdirs); mutually exclusive with --version
#   --publish         Push to OCI registry after building (skipped if unchanged)
#   --install-cso     Install/upgrade the Cluster Stack Operator with matching OCI config
#   --validate        Validate addon bundle structure against clusteraddon.yaml
#   -h, --help        Show this help
#
# Without --version or --all, builds the highest 1-* subdirectory.
#
# Each 1-XX/ subdir must contain a csctl.yaml with at minimum:
#   config:
#     provider:
#       type: openstack
#     clusterStackName: scs
#     kubernetesVersion: v1.34.3   # minor-only (v1.34) or with patch (v1.34.3)
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
#   CSO_CHART         CSO Helm chart reference (default: oci://registry.scs.community/cluster-stacks/cso),
#                     can also be a local path, e.g. ../cluster-stack-operator/charts
#   CSO_IMAGE_REPOSITORY, CSO_IMAGE_TAG
#                     Override the CSO image (e.g. to test a locally built operator)

set -euo pipefail
shopt -s inherit_errexit

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly YQ_VERSION="$(yq --version 2>/dev/null || true)"

require_command() {
    local name="$1"

    if ! command -v "$name" >/dev/null 2>&1; then
        echo "$name not found. Please install $name and try again." >&2
        exit 1
    fi
}

log() {
    echo "$@" >&2
}

warn() {
    echo "Warning: $*" >&2
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

normalize_release_version() {
    local version="$1"

    if [[ "$version" =~ ^[0-9] ]]; then
        version="v${version}"
    fi

    if [[ ! "$version" =~ ^v[0-9]+(-[A-Za-z0-9_]+\.[A-Za-z0-9_]+)?$ ]]; then
        echo "Invalid release version: ${version}. Expected v<N> or v<N>-<channel>.<patch>, e.g. v1 or v0-sha.abc1234." >&2
        exit 1
    fi

    echo "$version"
}

oras_auth_opts() {
    if [[ -n "${OCI_USERNAME:-}" && -n "${OCI_PASSWORD:-}" ]]; then
        printf '%s\n' --username "$OCI_USERNAME" --password "$OCI_PASSWORD"
    elif [[ -n "${OCI_ACCESS_TOKEN:-}" ]]; then
        printf '%s\n' --password "$OCI_ACCESS_TOKEN"
    fi
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
            --version)      [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; usage; }; TARGET_VERSION="$2"; shift 2 ;;
            --release-version) [[ $# -ge 2 ]] || { echo "Error: $1 requires a value" >&2; usage; }; RELEASE_VERSION=$(normalize_release_version "$2"); shift 2 ;;
            --all)          BUILD_ALL=true; shift ;;
            --publish)      PUBLISH=true; shift ;;
            --install-cso)  INSTALL_CSO=true; shift ;;
            --validate)     VALIDATE=true; shift ;;
            -h|--help)      usage 0 ;;
            -*)             echo "Unknown option: $1" >&2; usage ;;
            *)
                if [[ -z "$BASE_DIR" ]]; then
                    BASE_DIR="$1"; shift
                else
                    echo "Unexpected argument: $1" >&2; usage
                fi
                ;;
        esac
    done

    if [[ "$BUILD_ALL" == "true" && -n "$TARGET_VERSION" ]]; then
        echo "Error: --all and --version <X.Y> cannot be used together." >&2
        usage
    fi

    if [[ -n "$RELEASE_VERSION" && -z "$TARGET_VERSION" ]]; then
        echo "Error: --release-version can only be used together with --version <X.Y>." >&2
        usage
    fi

    if [[ -n "$RELEASE_VERSION" && "$BUILD_ALL" == "true" ]]; then
        echo "Error: --release-version cannot be used with --all." >&2
        usage
    fi
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
TARGET_VERSION=""
RELEASE_VERSION=""
BUILD_ALL=false
PUBLISH=false
INSTALL_CSO=false
VALIDATE=false

parse_args "$@"

require_command yq
require_command curl
require_command helm

BASE_DIR="$(resolve_base_dir "$BASE_DIR")"

if [[ ! -d "$BASE_DIR" ]]; then
    echo "Stack base directory not found: $BASE_DIR" >&2
    exit 1
fi

OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/.release}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

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
            ls -d "$BASE_DIR"/1-*/ 2>/dev/null | sed 's|/$||; s|.*/||; s/^/  /' >&2
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
    echo "No version directories to build" >&2
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
        echo "Auto-configured ttl.sh: $OCI_REGISTRY/$OCI_REPOSITORY (expires in 24h)" >&2
    fi

    if [[ -z "${OCI_REPOSITORY:-}" ]]; then
        echo "Error: OCI_REPOSITORY must be set when OCI_REGISTRY is set." >&2
        exit 1
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
        echo "helm not found — install from https://helm.sh/docs/intro/install/" >&2
        exit 1
    fi

    echo "Installing/upgrading CSO..." >&2
    echo "  Chart:      $CSO_CHART" >&2
    # The CSO expects the repository including the registry host (e.g. registry.example.com/kaas/cluster-stacks)
    echo "  OCI config: registry=$OCI_REGISTRY repository=$OCI_REGISTRY/$OCI_REPOSITORY" >&2

    local image_args=()
    if [[ -n "${CSO_IMAGE_REPOSITORY:-}" ]]; then
        echo "  Image:      ${CSO_IMAGE_REPOSITORY}:${CSO_IMAGE_TAG:-<chart default>}" >&2
        image_args+=(--set "controllerManager.manager.image.repository=${CSO_IMAGE_REPOSITORY}")
    fi
    if [[ -n "${CSO_IMAGE_TAG:-}" ]]; then
        image_args+=(--set "controllerManager.manager.image.tag=${CSO_IMAGE_TAG}")
    fi
    echo "" >&2

    helm upgrade -i cso "$CSO_CHART" \
        --namespace cso-system --create-namespace \
        --set controllerManager.manager.source=oci \
        --set "clusterStackVariables.ociRegistry=${OCI_REGISTRY}" \
        --set "clusterStackVariables.ociRepository=${OCI_REGISTRY}/${OCI_REPOSITORY}" \
        "${image_args[@]+"${image_args[@]}"}" >&2

    echo "" >&2
}

is_dev_registry() {
    [[ "${OCI_REGISTRY:-}" == "ttl.sh" || -z "${OCI_REPOSITORY:-}" ]]
}

list_oci_tags() {
    require_command oras

    local oras_opts=()
    mapfile -t oras_opts < <(oras_auth_opts)

    local tags oras_err
    oras_err=$(mktemp)
    if ! tags=$(oras repo tags "${OCI_REGISTRY}/${OCI_REPOSITORY}" "${oras_opts[@]+"${oras_opts[@]}"}" 2>"$oras_err"); then
        # A repository without any pushed artifact does not exist yet: start with v1
        if grep -qiE 'name unknown|NAME_UNKNOWN|repository name not known|not found' "$oras_err"; then
            tags=""
        else
            echo "Failed to query OCI tags from ${OCI_REGISTRY}/${OCI_REPOSITORY}:" >&2
            cat "$oras_err" >&2
            rm -f "$oras_err"
            exit 1
        fi
    fi
    rm -f "$oras_err"
    echo "$tags"
}

latest_published_release_number() {
    local tag_prefix="$1"
    local tags latest

    tags=$(list_oci_tags) || exit 1
    latest=$(echo "$tags" | extract_latest_release_number "$tag_prefix" || true)
    echo "${latest:-0}"
}

# Determine release version for a given K8s minor version.
# Stable: highest published vN + 1. Dev: v0-ttl.<timestamp>.
get_release_version() {
    local provider="$1"
    local stack_name="$2"
    local k8s_dash="$3"
    local tag_prefix="${provider}-${stack_name}-${k8s_dash}"

    if [[ -n "$RELEASE_VERSION" ]]; then
        echo "$RELEASE_VERSION"
        return
    fi

    if is_dev_registry; then
        echo "v0-ttl.$(date +%s)"
        return
    fi

    local latest
    latest=$(latest_published_release_number "$tag_prefix") || exit 1
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
    else
        if ! latest=$(curl -sfL "https://dl.k8s.io/release/stable-${version}.txt" 2>/dev/null | sed 's/^v//'); then
            echo "Failed to resolve the latest patch version for Kubernetes ${version}." >&2
            exit 1
        fi
    fi

    if [[ -n "$latest" && "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$latest"
        return
    fi

    echo "Could not resolve a stable patch version for Kubernetes ${version}." >&2
    exit 1
}

finalize_release_dir() {
    local staged_dir="$1"
    local output_dir="$2"

    mkdir -p "$(dirname "$output_dir")"

    if [[ -e "$output_dir" ]]; then
        if ! rm -rf "$output_dir" 2>/dev/null; then
            if [[ "$PUBLISH" == "true" ]]; then
                warn "Could not replace existing output directory: $output_dir"
                warn "Keeping staged artifacts in: $staged_dir"
                echo "$staged_dir"
                return
            fi

            echo "Output directory is not writable: $output_dir" >&2
            echo "Remove it or fix permissions and retry." >&2
            exit 1
        fi
    fi

    if mv "$staged_dir" "$output_dir" 2>/dev/null; then
        echo "$output_dir"
        return
    fi

    if [[ "$PUBLISH" == "true" ]]; then
        warn "Could not move release artifacts to: $output_dir"
        warn "Keeping staged artifacts in: $staged_dir"
        echo "$staged_dir"
        return
    fi

    echo "Failed to move release artifacts to: $output_dir" >&2
    exit 1
}

# ============================================
# Build one version directory
# ============================================

build_version_dir() {
    local version_dir="$1"
    # Remove trailing slash
    version_dir="${version_dir%/}"

    local csctl_yaml="$version_dir/csctl.yaml"
    if [[ ! -f "$csctl_yaml" ]]; then
        echo "csctl.yaml not found in: $version_dir" >&2
        exit 1
    fi

    # Read stack configuration
    local provider stack_name k8s_version_raw
    provider=$(yq -r '.config.provider.type' "$csctl_yaml")
    stack_name=$(yq -r '.config.clusterStackName' "$csctl_yaml")
    k8s_version_raw=$(yq -r '.config.kubernetesVersion | sub("^v","")' "$csctl_yaml")

    # Resolve K8s patch version
    local k8s_version
    k8s_version=$(resolve_k8s_version "$k8s_version_raw" "$provider")
    local k8s_short
    k8s_short=$(extract_k8s_minor_version "$k8s_version")
    local k8s_dash="${k8s_short//./-}"

    echo "" >&2
    echo "Building ${provider}-${stack_name} for K8s ${k8s_version} (from ${version_dir})" >&2
    echo "---" >&2

    # Get release version
    local release_version
    release_version=$(get_release_version "$provider" "$stack_name" "$k8s_dash")
    mkdir -p "$OUTPUT_DIR"
    local output_release_dir="${OUTPUT_DIR}/${provider}-${stack_name}-${k8s_dash}-${release_version//./-}"
    local release_dir
    release_dir=$(mktemp -d "${OUTPUT_DIR}/.${provider}-${stack_name}-${k8s_dash}-${release_version}.XXXXXX")

    # ---- Prepare working copy ----
    local work_dir
    work_dir=$(mktemp -d)
    trap "rm -rf '$work_dir'" RETURN

    cp -r "$version_dir/cluster-class" "$work_dir/"
    cp -r "$version_dir/cluster-addon" "$work_dir/"

    # Patch cluster-class Chart.yaml: set name and version
    local class_chart="$work_dir/cluster-class/Chart.yaml"
    yq_edit_in_place ".name = \"${provider}-${stack_name}-${k8s_dash}-cluster-class\"" "$class_chart"
    yq_edit_in_place ".version = \"${release_version}\"" "$class_chart"

    # Update kubernetesVersion in csctl.yaml to the resolved patch version
    cp "$csctl_yaml" "$work_dir/csctl.yaml"
    yq_edit_in_place ".config.kubernetesVersion = \"v${k8s_version}\"" "$work_dir/csctl.yaml"

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
    echo "  Packaging cluster-class..." >&2
    rm -rf "$work_dir/cluster-class/charts"
    helm package "$work_dir/cluster-class" -d "$release_dir/" > /dev/null
    echo "  cluster-class packaged" >&2

    # ---- Package cluster-addon bundle ----
    echo "  Packaging cluster-addon..." >&2
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
        echo "  No addon subdirectories found" >&2
        rm -rf "$addon_temp"
        exit 1
    fi

    local addon_tgz="${provider}-${stack_name}-${k8s_dash}-cluster-addon-${release_version}.tgz"
    (cd "$addon_temp" && tar -czf "$release_dir/$addon_tgz" */)
    rm -rf "$addon_temp"
    echo "  cluster-addon packaged ($addon_count addons)" >&2

    # ---- Validate addon bundle ----
    if [[ "$VALIDATE" == "true" && -f "$version_dir/clusteraddon.yaml" ]]; then
        echo "  Validating addon bundle..." >&2
        local validate_dir
        validate_dir=$(mktemp -d)
        tar -xzf "$release_dir/$addon_tgz" -C "$validate_dir"

        local expected_addons
        expected_addons=$(yq '.addonStages | to_entries | .[].value[].name' "$version_dir/clusteraddon.yaml" 2>/dev/null | sort -u)

        local failed=false
        for addon in $expected_addons; do
            if [[ ! -d "$validate_dir/$addon" ]]; then
                echo "    Missing addon: $addon (referenced in clusteraddon.yaml)" >&2
                failed=true
            fi
        done
        rm -rf "$validate_dir"

        if [[ "$failed" == "true" ]]; then
            exit 1
        fi
        echo "  Validation passed" >&2
    fi

    # ---- Copy clusteraddon.yaml ----
    if [[ -f "$version_dir/clusteraddon.yaml" ]]; then
        cp "$version_dir/clusteraddon.yaml" "$release_dir/"
    fi

    # ---- Copy csctl.yaml (with resolved patch version) ----
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

    # ---- Publish ----
    if [[ "$PUBLISH" == "true" ]]; then
        local unchanged_version="" published_dir=""
        if ! is_dev_registry && [[ -z "$RELEASE_VERSION" ]]; then
            published_dir=$(mktemp -d "${OUTPUT_DIR}/.published.XXXXXX")
            unchanged_version=$(find_unchanged_published_release "$release_dir" "$provider-$stack_name-$k8s_dash" "$published_dir")
        fi

        if [[ -n "$unchanged_version" ]]; then
            log "  No changes compared to published release ${unchanged_version} - skipping publish"
            rm -rf "$release_dir"
            release_dir="$published_dir"
            release_version="$unchanged_version"
            output_release_dir="${OUTPUT_DIR}/${provider}-${stack_name}-${k8s_dash}-${release_version//./-}"
        else
            [[ -n "$published_dir" ]] && rm -rf "$published_dir"
            publish_version "$release_dir" "$provider" "$stack_name" "$k8s_dash" "$release_version"
        fi
    fi

    # Track for "next steps" output
    BUILT_K8S_SHORTS+=("$k8s_short")
    BUILT_CS_VERSIONS+=("$release_version")
    BUILT_PROVIDERS+=("$provider")
    BUILT_STACK_NAMES+=("$stack_name")

    local final_release_dir
    final_release_dir=$(finalize_release_dir "$release_dir" "$output_release_dir")

    log "  Output: $final_release_dir"
    log ""
    log "  Contents:"
    ls -1 "$final_release_dir/" | sed 's/^/    /' >&2
}

# ============================================
# Compare with the latest published release
# ============================================

normalize_release_for_compare() {
    local src="$1" dest="$2"

    mkdir -p "$dest"
    local f
    for f in "$src"/*.tgz; do
        [[ -f "$f" ]] && tar -xzf "$f" -C "$dest"
    done
    for f in clusteraddon.yaml csctl.yaml; do
        [[ -f "$src/$f" ]] && cp "$src/$f" "$dest/"
    done
    if [[ -f "$src/metadata.yaml" ]]; then
        grep -vE '^[[:space:]]*(clusterStack|clusterAddon|nodeImage):' "$src/metadata.yaml" > "$dest/metadata.yaml"
    fi
    find "$dest" -name Chart.yaml -exec sed -i '/^version:/d' {} +
}

find_unchanged_published_release() {
    local release_dir="$1" tag_prefix="$2" published_dir="$3"

    local latest
    latest=$(latest_published_release_number "$tag_prefix") || exit 1
    if [[ "$latest" -eq 0 ]]; then
        log "  No published release of ${tag_prefix} yet"
        return 0
    fi

    local oras_opts=()
    mapfile -t oras_opts < <(oras_auth_opts)

    log "  Comparing with published release ${tag_prefix}-v${latest}"
    if ! (cd "$published_dir" && oras pull "${OCI_REGISTRY}/${OCI_REPOSITORY}:${tag_prefix}-v${latest}" "${oras_opts[@]+"${oras_opts[@]}"}" >/dev/null 2>&1); then
        warn "Could not pull ${tag_prefix}-v${latest}, publishing a new release"
        return 0
    fi

    local compare_dir
    compare_dir=$(mktemp -d)
    normalize_release_for_compare "$release_dir" "$compare_dir/new"
    normalize_release_for_compare "$published_dir" "$compare_dir/published"

    local identical=false
    if diff -qr "$compare_dir/new" "$compare_dir/published" >/dev/null 2>&1; then
        identical=true
    fi
    rm -rf "$compare_dir"

    if [[ "$identical" == "true" ]]; then
        echo "v${latest}"
    else
        log "  Changes detected, publishing a new release"
    fi
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
    # The CSO requests the release tag in the dash notation (e.g. v0-ttl-123, not v0-ttl.123)
    local oci_tag="${provider}-${stack_name}-${k8s_dash}-${release_version//./-}"

    if [[ -z "${OCI_REGISTRY:-}" || -z "${OCI_REPOSITORY:-}" ]]; then
        echo "  OCI_REGISTRY or OCI_REPOSITORY not set" >&2
        exit 1
    fi

    if ! command -v oras >/dev/null 2>&1; then
        echo "  oras not found — install from https://oras.land/docs/installation" >&2
        exit 1
    fi

    local oras_opts=()
    mapfile -t oras_opts < <(oras_auth_opts)

    if ! is_dev_registry && oras manifest fetch --descriptor "$OCI_REGISTRY/$OCI_REPOSITORY:$oci_tag" "${oras_opts[@]+"${oras_opts[@]}"}" >/dev/null 2>&1; then
        echo "  Refusing to overwrite existing release $OCI_REGISTRY/$OCI_REPOSITORY:$oci_tag" >&2
        exit 1
    fi

    log ""
    log "  Publishing to $OCI_REGISTRY/$OCI_REPOSITORY:$oci_tag"

    local files=()
    for f in "$release_dir"/*; do
        [[ -f "$f" ]] && files+=("$(basename "$f")")
    done

    (cd "$release_dir" && oras push \
        "$OCI_REGISTRY/$OCI_REPOSITORY:$oci_tag" \
        --artifact-type application/vnd.clusterstack.release \
        "${oras_opts[@]+"${oras_opts[@]}"}" \
        "${files[@]}") >&2

    echo "  Published: $OCI_REGISTRY/$OCI_REPOSITORY:$oci_tag" >&2
    echo "  Pull:      oras pull $OCI_REGISTRY/$OCI_REPOSITORY:$oci_tag" >&2
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

    # --install-cso alone only installs the operator, it does not build anything
    if [[ -z "$TARGET_VERSION" && "$BUILD_ALL" != "true" && "$PUBLISH" != "true" ]]; then
        exit 0
    fi
fi

echo "Stack base: $BASE_DIR" >&2
echo "Version dirs: $(echo "$VERSION_DIRS" | tr '\n' ' ')" >&2
echo "" >&2

# Track built versions for "next steps" output
declare -a BUILT_K8S_SHORTS=()
declare -a BUILT_CS_VERSIONS=()
declare -a BUILT_PROVIDERS=()
declare -a BUILT_STACK_NAMES=()

for version_dir in $VERSION_DIRS; do
    build_version_dir "$version_dir"
done

echo "" >&2
echo "Done." >&2

# ============================================
# Next steps (after publish)
# ============================================

if [[ "$PUBLISH" == "true" && ${#BUILT_K8S_SHORTS[@]} -gt 0 ]]; then
    echo "" >&2
    echo "================================================================" >&2
    echo "Next steps" >&2
    echo "================================================================" >&2

    if [[ "$INSTALL_CSO" != "true" ]]; then
        echo "" >&2
        echo "1. Install the Cluster Stack Operator (or re-run with --install-cso):" >&2
        echo "" >&2
        echo "   helm upgrade -i cso ${CSO_CHART} \\" >&2
        echo "     --namespace cso-system --create-namespace \\" >&2
        echo "     --set controllerManager.manager.source=oci \\" >&2
        echo "     --set clusterStackVariables.ociRegistry=\"${OCI_REGISTRY}\" \\" >&2
        echo "     --set clusterStackVariables.ociRepository=\"${OCI_REGISTRY}/${OCI_REPOSITORY}\"" >&2
        echo "" >&2
        echo "2. Apply the ClusterStack resource(s):" >&2
    else
        echo "" >&2
        echo "Apply the ClusterStack resource(s):" >&2
    fi
    echo "" >&2
    for ((i=0; i<${#BUILT_K8S_SHORTS[@]}; i++)); do
        local_provider="${BUILT_PROVIDERS[$i]}"
        local_stack="${BUILT_STACK_NAMES[$i]}"
        local_k8s="${BUILT_K8S_SHORTS[$i]}"
        local_version="${BUILT_CS_VERSIONS[$i]}"
        echo "   ./hack/generate-resources.sh providers/${local_provider}/${local_stack} --version ${local_k8s} --cs-version ${local_version} | kubectl apply -f -" >&2
    done
    echo "" >&2
fi
