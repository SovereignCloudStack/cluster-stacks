#!/usr/bin/env bash
set -euo pipefail

# update-versions.sh — Update Kubernetes and addon versions in versions.yaml
#
# Fetches the latest stable Kubernetes patch versions from GitHub tags,
# updates K8s-tied addon versions from Helm repo indexes, manages Ubuntu
# image mappings, adds new minor versions and removes EOL ones.
#
# Usage:
#   ./hack/update-versions.sh [stack-dir] [--check|--apply] [--supported-minors N]
#
# If <stack-dir> is omitted, it is derived from $PROVIDER and $CLUSTER_STACK
# (default: providers/openstack/scs2).
#
# Options:
#   --check              Show available updates without modifying files (default)
#   --apply              Apply updates to versions.yaml
#   --supported-minors N Keep the N most recent K8s minor versions (default: 4)
#
# Environment:
#   PROVIDER        Provider name (default: openstack)
#   CLUSTER_STACK   Cluster stack name (default: scs2)
#   GITHUB_TOKEN    Optional. GitHub personal access token for higher API rate limits.
#                   Without token: 60 requests/hour. With token: 5000 requests/hour.
#
# Examples:
#   ./hack/update-versions.sh --check
#   ./hack/update-versions.sh providers/openstack/scs2 --apply
#   PROVIDER=docker CLUSTER_STACK=scs ./hack/update-versions.sh --apply

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
MODE="check"
SUPPORTED_MINORS=4

# --- Ubuntu version mapping ---
# Update this function when new Ubuntu LTS versions become available for CAPI images.
# Currently:
#   K8s 1.32 and earlier → Ubuntu 22.04 (2204)
#   K8s 1.33 and later   → Ubuntu 24.04 (2404)
ubuntu_for_minor() {
    local minor="$1"
    if [[ "$minor" -le 32 ]]; then
        echo "2204"
    else
        echo "2404"
    fi
}

# --- Helm repo URLs for K8s-tied addons ---
# Maps addon chart names to their Helm repo index URL.
# Only addons whose version tracks the K8s minor version belong here.
declare -A ADDON_HELM_REPOS=(
    ["openstack-cloud-controller-manager"]="https://kubernetes.github.io/cloud-provider-openstack"
    ["openstack-cinder-csi"]="https://kubernetes.github.io/cloud-provider-openstack"
)

# Maps legacy addon key names (from versions.yaml) to their actual Helm chart name.
# This allows the script to work with both old and new key naming conventions.
declare -A ADDON_KEY_TO_CHART=(
    ["occm"]="openstack-cloud-controller-manager"
    ["cinder_csi"]="openstack-cinder-csi"
    ["openstack-cloud-controller-manager"]="openstack-cloud-controller-manager"
    ["openstack-cinder-csi"]="openstack-cinder-csi"
)

# --- Helper functions ---

usage() {
    sed -n '3,/^$/s/^# \?//p' "$0"
    exit 1
}

info()  { echo "  $*"; }
ok()    { echo "  ✓ $*"; }
warn()  { echo "  ! $*"; }
update(){ echo "  → $*"; }

github_curl() {
    local url="$1"
    local -a headers=()
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        headers=(-H "Authorization: token $GITHUB_TOKEN")
    fi
    curl -sfL "${headers[@]+"${headers[@]}"}" "$url"
}

# Fetch all stable K8s release tags from GitHub.
# Returns lines like: 1.34.4
fetch_k8s_versions() {
    local page=1
    local all_tags=""

    while true; do
        local tags
        tags=$(github_curl "https://api.github.com/repos/kubernetes/kubernetes/tags?per_page=100&page=$page" \
            | jq -r '.[].name // empty') || { echo "Error fetching K8s tags from GitHub" >&2; return 1; }

        [[ -z "$tags" ]] && break
        all_tags+="$tags"$'\n'
        page=$((page + 1))

        # Stop once we've gone past the versions we care about
        if echo "$tags" | grep -qE '^v1\.2[0-9]\.'; then
            break
        fi
    done

    # Filter to stable releases only (no alpha/beta/rc), strip 'v' prefix
    echo "$all_tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' | sort -V
}

# Get the highest patch version for a given minor from a list of versions.
# Usage: echo "$versions" | highest_patch 34
highest_patch() {
    local minor="$1"
    grep -E "^1\.${minor}\.[0-9]+$" | sort -V | tail -1
}

# Get the N most recent K8s minor version numbers from a list of versions.
# Usage: echo "$versions" | recent_minors 4
# Returns: lines like 32, 33, 34, 35
recent_minors() {
    local count="$1"
    grep -oE '^1\.[0-9]+' | sort -t. -k2 -n -u | tail -"$count" | sed 's/^1\.//'
}

# Fetch the Helm repo index and find the highest stable version matching a pattern.
# Usage: helm_latest_version "https://repo-url" "chart-name" "2.34"
helm_latest_version() {
    local repo_url="$1"
    local chart_name="$2"
    local version_prefix="$3"

    curl -sfL "${repo_url}/index.yaml" \
        | yq ".entries.\"${chart_name}\"[].version" \
        | grep -E "^${version_prefix}\.[0-9]+$" \
        | sort -V \
        | tail -1
}

# Read the current versions.yaml as a list of K8s versions.
# Returns: lines like 1.32.8, 1.33.7, etc.
current_k8s_versions() {
    local versions_file="$1"
    yq -r '.[].kubernetes' "$versions_file" 2>/dev/null
}

# Get a field from a versions.yaml entry by K8s version.
# Usage: get_version_field versions.yaml 1.34.3 openstack-cinder-csi
get_version_field() {
    local versions_file="$1"
    local k8s_version="$2"
    local field="$3"
    yq -r ".[] | select(.kubernetes == \"$k8s_version\") | .\"$field\" // \"\"" "$versions_file"
}

# Detect which addon keys exist in versions.yaml (excluding kubernetes and ubuntu).
detect_addons() {
    local versions_file="$1"
    yq -r '.[0] | keys[] | select(test("^(kubernetes|ubuntu)$") | not)' "$versions_file" 2>/dev/null
}

# --- Main logic ---

parse_args() {
    STACK_DIR=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)  MODE="check"; shift ;;
            --apply)  MODE="apply"; shift ;;
            --supported-minors)
                SUPPORTED_MINORS="$2"; shift 2
                ;;
            -h|--help) usage ;;
            -*)  echo "Unknown option: $1" >&2; usage ;;
            *)
                if [[ -z "$STACK_DIR" ]]; then
                    STACK_DIR="$1"; shift
                else
                    echo "Unexpected argument: $1" >&2; usage
                fi
                ;;
        esac
    done

    if [[ -z "$STACK_DIR" ]]; then
        STACK_DIR="providers/${PROVIDER:-openstack}/${CLUSTER_STACK:-scs2}"
    fi

    # Resolve relative path
    if [[ ! "$STACK_DIR" = /* ]]; then
        STACK_DIR="$REPO_ROOT/$STACK_DIR"
    fi
}

main() {
    parse_args "$@"

    local versions_file="$STACK_DIR/versions.yaml"
    if [[ ! -f "$versions_file" ]]; then
        echo "Error: versions.yaml not found in $STACK_DIR" >&2
        exit 1
    fi

    echo "Checking $STACK_DIR..."
    echo ""

    # --- Step 1: Fetch all available K8s versions ---
    echo "Fetching Kubernetes releases from GitHub..."
    local all_k8s_versions
    all_k8s_versions=$(fetch_k8s_versions)

    # Determine which minors to support
    local supported
    supported=$(echo "$all_k8s_versions" | recent_minors "$SUPPORTED_MINORS")

    echo "Supported minor versions: $(echo $supported | tr '\n' ' ' | sed 's/1\.//g; s/ $//; s/ /, 1./g; s/^/1./')"
    echo ""

    # --- Step 2: Detect addons in versions.yaml ---
    local addon_keys
    addon_keys=$(detect_addons "$versions_file") || true
    local has_addons=false
    if [[ -n "$addon_keys" ]]; then
        has_addons=true
    fi

    # Check if stack has ubuntu mapping
    local has_ubuntu=false
    if [[ "$(yq '.[0].ubuntu' "$versions_file")" != "null" ]]; then
        has_ubuntu=true
    fi

    # --- Step 3: Fetch Helm repo indexes for K8s-tied addons ---
    # Cache the index files to avoid redundant downloads
    declare -A helm_index_cache
    if [[ "$has_addons" == true ]]; then
        echo "Fetching Helm repo indexes for addons..."
        for addon_key in $addon_keys; do
            local chart_name="${ADDON_KEY_TO_CHART[$addon_key]:-}"
            if [[ -z "$chart_name" ]]; then
                warn "Unknown addon key: $addon_key (not in ADDON_KEY_TO_CHART mapping)"
                continue
            fi
            local repo_url="${ADDON_HELM_REPOS[$chart_name]:-}"
            if [[ -z "$repo_url" ]]; then
                warn "No Helm repo URL configured for chart: $chart_name"
                continue
            fi
            if [[ -z "${helm_index_cache[$repo_url]:-}" ]]; then
                helm_index_cache[$repo_url]=$(curl -sfL "${repo_url}/index.yaml") || {
                    warn "Failed to fetch Helm repo index: $repo_url"
                    continue
                }
            fi
        done
        echo ""
    fi

    # --- Step 4: Build the new versions list ---
    local current_versions
    current_versions=$(current_k8s_versions "$versions_file")
    local current_minors
    current_minors=$(echo "$current_versions" | grep -oE '^1\.[0-9]+' | sed 's/^1\.//' | sort -n -u)

    # Track changes for reporting
    local changes=0
    local new_entries=""

    echo "Kubernetes versions:"
    for minor in $supported; do
        local latest_patch
        latest_patch=$(echo "$all_k8s_versions" | highest_patch "$minor")

        if [[ -z "$latest_patch" ]]; then
            warn "1.$minor: no stable release found"
            continue
        fi

        # Check if this minor exists in current versions.yaml
        local current_patch
        current_patch=$(echo "$current_versions" | highest_patch "$minor") || true

        if [[ -z "$current_patch" ]]; then
            update "1.$minor: NEW → $latest_patch"
            changes=$((changes + 1))
        elif [[ "$current_patch" != "$latest_patch" ]]; then
            update "1.$minor: $current_patch → $latest_patch"
            changes=$((changes + 1))
        else
            ok "1.$minor: $latest_patch (up to date)"
        fi
    done

    # Check for versions to remove (not in supported minors)
    for current_minor in $current_minors; do
        if ! echo "$supported" | grep -qx "$current_minor"; then
            update "1.$current_minor: REMOVE (no longer supported)"
            changes=$((changes + 1))
        fi
    done
    echo ""

    # --- Step 5: Check addon versions ---
    if [[ "$has_addons" == true ]]; then
        echo "K8s-tied addon versions:"
        for addon_key in $addon_keys; do
            local chart_name="${ADDON_KEY_TO_CHART[$addon_key]:-}"
            [[ -z "$chart_name" ]] && continue
            local repo_url="${ADDON_HELM_REPOS[$chart_name]:-}"
            [[ -z "$repo_url" ]] && continue

            for minor in $supported; do
                local addon_prefix="2.$minor"
                local latest_addon
                latest_addon=$(echo "${helm_index_cache[$repo_url]}" \
                    | yq ".entries.\"${chart_name}\"[].version" \
                    | grep -E "^${addon_prefix}\.[0-9]+$" \
                    | sort -V \
                    | tail -1) || true

                if [[ -z "$latest_addon" ]]; then
                    warn "$addon_key 1.$minor: no version found matching $addon_prefix.*"
                    continue
                fi

                # Get current version from versions.yaml for this minor
                local current_k8s
                current_k8s=$(echo "$current_versions" | highest_patch "$minor") || true
                local current_addon=""
                if [[ -n "$current_k8s" ]]; then
                    current_addon=$(get_version_field "$versions_file" "$current_k8s" "$addon_key")
                fi

                if [[ -z "$current_addon" ]]; then
                    update "$addon_key 1.$minor: NEW → $latest_addon"
                    changes=$((changes + 1))
                elif [[ "$current_addon" != "$latest_addon" ]]; then
                    update "$addon_key 1.$minor: $current_addon → $latest_addon"
                    changes=$((changes + 1))
                else
                    ok "$addon_key 1.$minor: $latest_addon (up to date)"
                fi
            done
        done
        echo ""
    fi

    # --- Step 6: Apply changes ---
    if [[ "$changes" -eq 0 ]]; then
        echo "Everything is up to date."
        return 0
    fi

    echo "$changes update(s) available."

    if [[ "$MODE" == "check" ]]; then
        echo ""
        echo "Run with --apply to update versions.yaml"
        return 0
    fi

    echo ""
    echo "Applying updates to $versions_file..."

    # Build new versions.yaml using a temp file to accumulate entries
    local tmpfile
    tmpfile=$(mktemp)
    echo "[]" > "$tmpfile"

    for minor in $supported; do
        local latest_patch
        latest_patch=$(echo "$all_k8s_versions" | highest_patch "$minor")
        [[ -z "$latest_patch" ]] && continue

        # Build the entry as a temp YAML file
        local entry_file
        entry_file=$(mktemp)
        echo "kubernetes: \"$latest_patch\"" > "$entry_file"

        # Add ubuntu mapping if the stack uses it
        if [[ "$has_ubuntu" == true ]]; then
            local ubuntu_ver
            ubuntu_ver=$(ubuntu_for_minor "$minor")
            echo "ubuntu: \"$ubuntu_ver\"" >> "$entry_file"
        fi

        # Add addon versions
        if [[ "$has_addons" == true ]]; then
            for addon_key in $addon_keys; do
                local chart_name="${ADDON_KEY_TO_CHART[$addon_key]:-}"
                local repo_url=""
                local addon_prefix="2.$minor"
                local latest_addon=""

                if [[ -n "$chart_name" ]]; then
                    repo_url="${ADDON_HELM_REPOS[$chart_name]:-}"
                fi

                if [[ -n "$repo_url" ]] && [[ -n "${helm_index_cache[$repo_url]:-}" ]]; then
                    latest_addon=$(echo "${helm_index_cache[$repo_url]}" \
                        | yq ".entries.\"${chart_name}\"[].version" \
                        | grep -E "^${addon_prefix}\.[0-9]+$" \
                        | sort -V \
                        | tail -1) || true
                fi

                if [[ -n "$latest_addon" ]]; then
                    echo "$addon_key: \"$latest_addon\"" >> "$entry_file"
                else
                    # Keep the current version if we can't find a newer one
                    local current_k8s
                    current_k8s=$(echo "$current_versions" | highest_patch "$minor") || true
                    if [[ -n "$current_k8s" ]]; then
                        local current_addon
                        current_addon=$(get_version_field "$versions_file" "$current_k8s" "$addon_key")
                        if [[ -n "$current_addon" ]]; then
                            echo "$addon_key: \"$current_addon\"" >> "$entry_file"
                        fi
                    fi
                fi
            done
        fi

        # Append entry to the array
        yq -i ". += [load(\"$entry_file\")]" "$tmpfile"
        rm -f "$entry_file"
    done

    # Write the final versions.yaml
    yq -P '.' "$tmpfile" > "$versions_file"
    rm -f "$tmpfile"

    echo "Updated: $versions_file"
    echo ""
    echo "New content:"
    cat "$versions_file"
}

main "$@"
