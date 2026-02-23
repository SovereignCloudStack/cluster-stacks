#!/usr/bin/env bash
set -euo pipefail

# update.sh — Unified version and addon updater for Cluster Stacks
#
# Updates Kubernetes patch versions in stack.yaml and Helm chart dependencies
# in cluster-addon/*/Chart.yaml. Each per-minor-version directory (1-XX/) is
# self-contained with its own stack.yaml.
#
# For OpenStack stacks, the `versions` subcommand also maintains
# image-manager.yaml in the stack base directory (e.g., providers/openstack/scs/).
# This file uses merge semantics: new versions are added, existing ones updated,
# but versions for removed minors are never deleted — protecting images still
# used by running clusters.
#
# Usage:
#   ./hack/update.sh [versions|addons] [stack-dir] [options]
#
# Subcommands:
#   versions    Update K8s patch versions in stack.yaml + image-manager.yaml
#   addons      Update Helm chart dependencies in cluster-addon/*/Chart.yaml
#   (none)      Run both: versions first, then addons
#
# The <stack-dir> is the base directory containing per-minor-version subdirs
# (e.g., providers/openstack/scs). If omitted, it is derived from $PROVIDER
# and $CLUSTER_STACK (default: providers/openstack/scs).
#
# Options:
#   --dry-run   Preview changes without modifying files
#   --all       Run against all stacks in providers/*/*/
#   -h, --help  Show this help
#
# Environment:
#   PROVIDER          Provider name (default: openstack)
#   CLUSTER_STACK     Cluster stack name (default: scs)
#   GITHUB_TOKEN      Optional. GitHub personal access token for higher API rate limits.
#   IMAGE_BASE_URL    Base URL for CAPI images (default: https://nbg1.your-objectstorage.com/...)
#   IMAGE_VISIBILITY  Image visibility in image-manager.yaml (default: private)

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ============================================
# Defaults
# ============================================

SUBCOMMAND=""       # versions, addons, or "" (both)
BASE_DIR=""
DRY_RUN=false
RUN_ALL=false

# Image-manager defaults (for OpenStack image manifest generation)
IMAGE_BASE_URL="${IMAGE_BASE_URL:-https://nbg1.your-objectstorage.com/osism/openstack-k8s-capi-images}"
IMAGE_VISIBILITY="${IMAGE_VISIBILITY:-private}"

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
# Output helpers
# ============================================

info()   { echo "  $*"; }
ok()     { echo "  ✓ $*"; }
warn()   { echo "  ! $*"; }
change() { echo "  → $*"; }

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
            versions|addons)
                if [[ -n "$SUBCOMMAND" ]]; then
                    echo "Error: multiple subcommands given" >&2; usage
                fi
                SUBCOMMAND="$1"; shift
                ;;
            --dry-run)         DRY_RUN=true; shift ;;
            --all)             RUN_ALL=true; shift ;;
            -h|--help)         usage 0 ;;
            -*)                echo "Unknown option: $1" >&2; usage ;;
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

    # Resolve relative path
    if [[ ! "$dir" = /* ]]; then
        dir="$REPO_ROOT/$dir"
    fi

    echo "$dir"
}

# Detect provider from stack dir path
detect_provider() {
    local dir="$1"
    local rel="${dir#"$REPO_ROOT"/}"
    echo "$rel" | cut -d/ -f2
}

# ============================================
# K8s version fetchers (provider-aware)
# ============================================

github_curl() {
    local url="$1"
    local -a headers=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        headers=(-H "Authorization: token $GITHUB_TOKEN")
    fi
    curl -sfL "${headers[@]+"${headers[@]}"}" "$url"
}

fetch_k8s_versions_github() {
    local page=1
    local all_tags=""

    while true; do
        local tags
        tags=$(github_curl "https://api.github.com/repos/kubernetes/kubernetes/tags?per_page=100&page=$page" \
            | jq -r '.[].name // empty') || { echo "Error fetching K8s tags from GitHub" >&2; return 1; }

        [[ -z "$tags" ]] && break
        all_tags+="$tags"$'\n'
        page=$((page + 1))

        if echo "$tags" | grep -qE '^v1\.2[0-9]\.'; then
            break
        fi
    done

    echo "$all_tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -V
}

fetch_k8s_versions_dockerhub() {
    local page=1
    local all_tags=""

    while true; do
        local response
        response=$(curl -sfL "https://registry.hub.docker.com/v2/repositories/kindest/node/tags?page_size=100&page=$page") \
            || { echo "Error fetching kindest/node tags from Docker Hub" >&2; return 1; }

        local tags
        tags=$(echo "$response" | jq -r '.results[].name // empty')
        [[ -z "$tags" ]] && break

        all_tags+="$tags"$'\n'

        local next
        next=$(echo "$response" | jq -r '.next // empty')
        [[ -z "$next" ]] && break

        page=$((page + 1))

        if echo "$tags" | grep -qE '^v1\.2[0-9]\.'; then
            break
        fi
    done

    echo "$all_tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -V
}

fetch_k8s_versions() {
    local provider="$1"
    case "$provider" in
        docker) fetch_k8s_versions_dockerhub ;;
        *)      fetch_k8s_versions_github ;;
    esac
}

# Get the highest patch version for a given minor from a list of versions.
highest_patch() {
    local minor="$1"
    grep -E "^1\.${minor}\.[0-9]+$" | sort -V | tail -1
}

# ============================================
# Helm repo URL maps for K8s-tied addons
# ============================================

declare -A ADDON_HELM_REPOS=(
    ["openstack-cloud-controller-manager"]="https://kubernetes.github.io/cloud-provider-openstack"
    ["openstack-cinder-csi"]="https://kubernetes.github.io/cloud-provider-openstack"
)

declare -A ADDON_SHORT_TO_CHART=(
    ["ccm"]="openstack-cloud-controller-manager"
    ["csi"]="openstack-cinder-csi"
)

# ============================================
# Image-manager update (OpenStack only)
# ============================================

# Update providers/<provider>/<stack>/image-manager.yaml with merge semantics:
# - New minor versions are added
# - Existing minor versions are updated (new patch replaces old)
# - Minor versions no longer in 1-*/ dirs are preserved (never removed)
#
# Args: $1 = base_dir, $2 = name of associative array with resolved patches
update_image_manager() {
    local base_dir="${1%/}"   # strip trailing slash
    local -n patches_ref=$2  # nameref to associative array

    local image_file="$base_dir/image-manager.yaml"
    echo "Updating image-manager manifest: $image_file"

    # Build map of existing versions from file (if present), keyed by minor
    # Each entry: "version|url|checksum"
    declare -A existing_versions=()
    if [[ -f "$image_file" ]]; then
        local num_versions
        num_versions=$(yq '.images[0].versions | length' "$image_file" 2>/dev/null || echo "0")
        for ((i=0; i<num_versions; i++)); do
            local ver url chk
            ver=$(yq -r ".images[0].versions[$i].version" "$image_file")
            url=$(yq -r ".images[0].versions[$i].url" "$image_file")
            chk=$(yq -r ".images[0].versions[$i].checksum // \"\"" "$image_file")

            # Extract minor from version string (e.g., "v1.34.4" → "34")
            local minor
            minor=$(echo "$ver" | grep -oP '\d+\.\K\d+(?=\.\d+)')
            if [[ -n "$minor" ]]; then
                existing_versions["$minor"]="${ver}|${url}|${chk}"
            fi
        done
        info "Read ${num_versions} existing version(s) from $image_file"
    else
        info "No existing $image_file — creating from scratch"
    fi

    # Overlay new versions (resolved patches win for matching minors)
    local image_changes=0
    for minor in "${!patches_ref[@]}"; do
        local k8s_version="${patches_ref[$minor]}"
        local ubuntu
        ubuntu=$(ubuntu_for_minor "$minor")
        local image_dir="ubuntu-${ubuntu}-kube-v1.${minor}"
        local image_name="ubuntu-${ubuntu}-kube-v${k8s_version}"
        local image_url="${IMAGE_BASE_URL}/${image_dir}/${image_name}.qcow2"

        # Fetch checksum
        local checksum=""
        checksum=$(curl -sf "${image_url}.CHECKSUM" | awk '{print $1}' || echo "")
        if [[ -z "$checksum" ]]; then
            warn "1.$minor: checksum fetch failed (${image_url}.CHECKSUM) — continuing without"
        fi

        local new_entry="v${k8s_version}|${image_url}|${checksum:+sha256:${checksum}}"

        if [[ -n "${existing_versions[$minor]+_}" ]]; then
            if [[ "${existing_versions[$minor]}" != "$new_entry" ]]; then
                local old_ver
                old_ver=$(echo "${existing_versions[$minor]}" | cut -d'|' -f1)
                change "1.$minor: $old_ver → v${k8s_version}"
                image_changes=$((image_changes + 1))
            else
                ok "1.$minor: v${k8s_version} (up to date)"
            fi
        else
            change "1.$minor: added v${k8s_version}"
            image_changes=$((image_changes + 1))
        fi
        existing_versions["$minor"]="$new_entry"
    done

    if [[ "$image_changes" -eq 0 ]]; then
        echo "Image manifest is up to date."
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "$image_changes image-manager update(s) available (dry-run: no changes written)."
        return
    fi

    # Sort minors numerically and build versions block
    local sorted_minors
    sorted_minors=$(printf '%s\n' "${!existing_versions[@]}" | sort -n)

    local versions_block=""
    for minor in $sorted_minors; do
        local entry="${existing_versions[$minor]}"
        local ver url chk
        ver=$(echo "$entry" | cut -d'|' -f1)
        url=$(echo "$entry" | cut -d'|' -f2)
        chk=$(echo "$entry" | cut -d'|' -f3)

        local checksum_line=""
        if [[ -n "$chk" ]]; then
            checksum_line="
        checksum: \"${chk}\""
        fi

        versions_block+="
      - version: '${ver}'
        url: ${url}${checksum_line}"
    done

    # Write the file
    cat > "$image_file" <<EOF
---
images:
  - name: ubuntu-capi-image
    enable: true
    format: raw
    login: ubuntu
    min_disk: 20
    min_ram: 1024
    status: active
    visibility: ${IMAGE_VISIBILITY}
    multi: false
    separator: "-"
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
    versions:${versions_block}
EOF

    ok "Written $image_file ($image_changes update(s))"
}

# ============================================
# Subcommand: versions
# ============================================

cmd_versions() {
    local base_dir="$1"

    local provider
    provider=$(detect_provider "$base_dir")

    echo "Updating K8s versions: $base_dir"
    echo ""

    # Fetch all available K8s versions
    if [[ "$provider" == "docker" ]]; then
        echo "Fetching kindest/node tags from Docker Hub..."
    else
        echo "Fetching Kubernetes releases from GitHub..."
    fi
    local all_k8s_versions
    all_k8s_versions=$(fetch_k8s_versions "$provider")
    echo ""

    local changes=0

    # Track resolved patch versions per minor (for image-manager update)
    # Key: minor number, Value: full patch version (e.g., "1.34.4")
    declare -A resolved_patches=()

    for version_dir in "$base_dir"/1-*/; do
        [[ -d "$version_dir" ]] || continue
        local stack_yaml="$version_dir/stack.yaml"
        [[ -f "$stack_yaml" ]] || continue

        local dir_name
        dir_name=$(basename "$version_dir")
        local k8s_version_raw
        k8s_version_raw=$(yq -r '.kubernetesVersion' "$stack_yaml")
        local k8s_short
        k8s_short=$(echo "$k8s_version_raw" | grep -oP '^\d+\.\d+')
        local k8s_minor
        k8s_minor=$(echo "$k8s_short" | cut -d. -f2)

        # Find latest patch for this minor
        local latest_patch
        latest_patch=$(echo "$all_k8s_versions" | highest_patch "$k8s_minor")

        if [[ -z "$latest_patch" ]]; then
            warn "$dir_name (1.$k8s_minor): no stable release found"
            continue
        fi

        # Track resolved patch for image-manager update
        resolved_patches["$k8s_minor"]="$latest_patch"

        # Check if already has a specific patch
        if [[ "$k8s_version_raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            # Already pinned to a patch version
            if [[ "$k8s_version_raw" == "$latest_patch" ]]; then
                ok "$dir_name: K8s $latest_patch (up to date)"
            else
                change "$dir_name: K8s $k8s_version_raw → $latest_patch"
                changes=$((changes + 1))
                if [[ "$DRY_RUN" != "true" ]]; then
                    yq -i ".kubernetesVersion = \"$latest_patch\"" "$stack_yaml"
                    info "Updated $stack_yaml"
                fi
            fi
        else
            # Minor-only (e.g., "1.34") — report latest available patch
            ok "$dir_name: K8s $k8s_version_raw (minor-only, latest patch: $latest_patch)"
        fi
    done

    echo ""
    if [[ "$changes" -eq 0 ]]; then
        echo "All K8s versions are up to date."
    elif [[ "$DRY_RUN" == "true" ]]; then
        echo "$changes update(s) available (dry-run: no changes written)."
    else
        echo "Applied $changes K8s version update(s)."
    fi

    # Update image-manager.yaml for OpenStack stacks
    if [[ "$provider" == "openstack" && ${#resolved_patches[@]} -gt 0 ]]; then
        echo ""
        update_image_manager "$base_dir" resolved_patches
    fi
}

# ============================================
# Subcommand: addons
# ============================================

cmd_addons() {
    local base_dir="$1"

    echo "Updating addons: $base_dir"
    echo ""

    # Collect all Helm repo URLs and add them
    declare -A repos_added=()

    for version_dir in "$base_dir"/1-*/; do
        [[ -d "$version_dir" ]] || continue
        for chart_file in "$version_dir"/cluster-addon/*/Chart.yaml; do
            [[ -f "$chart_file" ]] || continue
            local num_deps
            num_deps=$(yq '.dependencies | length' "$chart_file" 2>/dev/null || echo "0")
            for ((i=0; i<num_deps; i++)); do
                local dep_name dep_repo
                dep_name=$(yq -r ".dependencies[$i].name" "$chart_file")
                dep_repo=$(yq -r ".dependencies[$i].repository // \"\"" "$chart_file")
                [[ -z "$dep_repo" ]] && continue
                if [[ -z "${repos_added[$dep_name]+_}" ]]; then
                    helm repo add "$dep_name" "$dep_repo" >/dev/null 2>&1 || true
                    repos_added["$dep_name"]="$dep_repo"
                fi
            done
        done
    done

    if [[ ${#repos_added[@]} -gt 0 ]]; then
        info "Updating Helm repos..."
        helm repo update > /dev/null 2>&1
    fi
    echo ""

    local total_updates=0

    for version_dir in "$base_dir"/1-*/; do
        [[ -d "$version_dir" ]] || continue
        local dir_name
        dir_name=$(basename "$version_dir")

        echo "=== $dir_name ==="

        for addon_dir in "$version_dir"/cluster-addon/*/; do
            [[ -f "$addon_dir/Chart.yaml" ]] || continue
            local addon_name chart_file
            addon_name=$(basename "$addon_dir")
            chart_file="$addon_dir/Chart.yaml"

            local num_deps
            num_deps=$(yq '.dependencies | length' "$chart_file" 2>/dev/null || echo "0")
            [[ "$num_deps" == "0" || "$num_deps" == "null" ]] && continue

            for ((i=0; i<num_deps; i++)); do
                local dep_name current_version
                dep_name=$(yq -r ".dependencies[$i].name" "$chart_file")
                current_version=$(yq -r ".dependencies[$i].version" "$chart_file")

                # Determine if this is a K8s-tied addon (check stack.yaml addons)
                local is_tied=false
                local stack_yaml="$version_dir/stack.yaml"
                if [[ -f "$stack_yaml" ]]; then
                    for short_name in "${!ADDON_SHORT_TO_CHART[@]}"; do
                        if [[ "${ADDON_SHORT_TO_CHART[$short_name]}" == "$dep_name" ]]; then
                            local range
                            range=$(yq -r ".addons.\"${short_name}\" // \"\"" "$stack_yaml" 2>/dev/null)
                            if [[ -n "$range" && "$range" != "null" ]]; then
                                is_tied=true
                            fi
                        fi
                    done
                fi

                # Get latest version
                local latest_version=""
                if [[ "$is_tied" == "true" ]]; then
                    # For K8s-tied addons, match by prefix from stack.yaml range
                    local k8s_minor
                    k8s_minor=$(yq -r '.kubernetesVersion' "$stack_yaml" | grep -oP '\.\K\d+')
                    latest_version=$(helm search repo "$dep_name/$dep_name" --versions -o json 2>/dev/null | \
                        jq -r --arg minor "$k8s_minor" \
                            '[.[] | select(.version | startswith("2." + $minor + "."))] | .[0].version // empty' 2>/dev/null) || true
                else
                    latest_version=$(helm search repo "$dep_name/$dep_name" -o json 2>/dev/null | \
                        jq -r '.[0].version // empty' 2>/dev/null) || true
                fi

                if [[ -z "$latest_version" ]]; then
                    info "$dep_name: could not query upstream"
                    continue
                fi

                if [[ "$current_version" == "$latest_version" ]]; then
                    ok "$dep_name: $current_version (up to date)"
                    continue
                fi

                change "$dep_name: $current_version → $latest_version"
                total_updates=$((total_updates + 1))

                if [[ "$DRY_RUN" != "true" ]]; then
                    yq -i ".dependencies[$i].version = \"$latest_version\"" "$chart_file"
                    info "Updated $chart_file"
                fi
            done
        done
        echo ""
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$total_updates" -gt 0 ]]; then
            echo "$total_updates addon update(s) available (dry-run: no changes written)."
        else
            echo "All addons are up to date."
        fi
    elif [[ "$total_updates" -gt 0 ]]; then
        echo "Applied $total_updates addon update(s)."
    else
        echo "All addons are up to date."
    fi
}

# ============================================
# --all mode: iterate all stacks
# ============================================

run_all() {
    local subcommand="$1"
    local found=false

    # Find base dirs: providers/<provider>/<stack>/ that contain 1-*/ subdirs
    for base_dir in "$REPO_ROOT"/providers/*/*/; do
        # Must have at least one 1-*/ subdir
        ls "$base_dir"/1-*/stack.yaml >/dev/null 2>&1 || continue

        found=true
        echo "=========================================="
        echo "$base_dir"
        echo "=========================================="

        if [[ -z "$subcommand" ]]; then
            cmd_versions "$base_dir"
            echo ""
            cmd_addons "$base_dir"
        elif [[ "$subcommand" == "versions" ]]; then
            cmd_versions "$base_dir"
        elif [[ "$subcommand" == "addons" ]]; then
            cmd_addons "$base_dir"
        fi

        echo ""
    done

    if [[ "$found" == false ]]; then
        echo "No stacks found in providers/*/*/" >&2
        exit 1
    fi
}

# ============================================
# Main
# ============================================

main() {
    parse_args "$@"

    if [[ "$RUN_ALL" == true ]]; then
        run_all "$SUBCOMMAND"
        return
    fi

    BASE_DIR=$(resolve_base_dir "$BASE_DIR")

    if [[ ! -d "$BASE_DIR" ]]; then
        echo "Stack base directory not found: $BASE_DIR" >&2
        exit 1
    fi

    if [[ -z "$SUBCOMMAND" ]]; then
        cmd_versions "$BASE_DIR"
        echo ""
        cmd_addons "$BASE_DIR"
    elif [[ "$SUBCOMMAND" == "versions" ]]; then
        cmd_versions "$BASE_DIR"
    elif [[ "$SUBCOMMAND" == "addons" ]]; then
        cmd_addons "$BASE_DIR"
    fi
}

main "$@"
