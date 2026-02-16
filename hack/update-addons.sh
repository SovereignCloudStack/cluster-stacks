#!/usr/bin/env bash
# Helm chart dependency updater.
# Queries upstream repos for latest versions and asks before updating.
# Updates both Chart.yaml files and versions.yaml (for K8s-tied addons).
#
# Fully generic: reads repository URLs from Chart.yaml dependencies and derives
# K8s-tied addon list from versions.yaml keys. Works for any provider/stack.
#
# Usage:
#   ./hack/update-addons.sh [stack-dir] [options]
#
# If <stack-dir> is omitted, it is derived from $PROVIDER and $CLUSTER_STACK
# (default: providers/openstack/scs2).
#
# Options:
#   --k8s-version X.Y   Target K8s minor for version-tied chart filtering
#   --yes / -y           Auto-approve all updates
#
# Examples:
#   ./hack/update-addons.sh providers/openstack/scs2
#   ./hack/update-addons.sh --yes
#   PROVIDER=docker CLUSTER_STACK=scs ./hack/update-addons.sh

set -euo pipefail

# ============================================
# Argument parsing
# ============================================

STACK_DIR=""
K8S_VERSION=""
AUTO_APPROVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --k8s-version) K8S_VERSION="$2"; shift 2 ;;
        --yes|-y)      AUTO_APPROVE=true; shift ;;
        -*)            echo "Unknown option: $1"; exit 1 ;;
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

if [[ ! -d "$STACK_DIR/cluster-addon" ]]; then
    echo "cluster-addon directory not found in: $STACK_DIR"
    exit 1
fi

# Auto-detect K8s version from versions.yaml (use highest)
if [[ -z "$K8S_VERSION" && -f "$STACK_DIR/versions.yaml" ]]; then
    K8S_VERSION=$(yq -r '.[-1].kubernetes' "$STACK_DIR/versions.yaml" | grep -oP '^\d+\.\d+' || echo "")
fi

echo "Checking addon updates for $STACK_DIR"
if [[ -n "$K8S_VERSION" ]]; then
    echo "K8s version: $K8S_VERSION (used for version-tied chart filtering)"
fi
echo ""

# ============================================
# Derive K8s-tied chart names from versions.yaml
# ============================================
# Any key in versions.yaml that is not a metadata field is a K8s-version-tied addon.
# Metadata fields (kubernetes, ubuntu) are excluded.
# This makes the script fully generic — no hardcoded chart names needed.

METADATA_KEYS="kubernetes|ubuntu"
declare -A K8S_TIED_CHARTS=()

if [[ -f "$STACK_DIR/versions.yaml" ]]; then
    while IFS= read -r key; do
        K8S_TIED_CHARTS["$key"]=1
    done < <(yq -r '.[0] | keys | .[] | select(test("^('"$METADATA_KEYS"')$") | not)' "$STACK_DIR/versions.yaml" 2>/dev/null)

    if [[ ${#K8S_TIED_CHARTS[@]} -gt 0 ]]; then
        echo "K8s-tied addons (from versions.yaml): ${!K8S_TIED_CHARTS[*]}"
    fi
fi

# ============================================
# Helm repository setup (from Chart.yaml)
# ============================================
# Scan all addon Chart.yaml files and collect unique repository URLs.
# Each chart name gets its repo added dynamically — no hardcoded map needed.

declare -A ADDED_REPOS=()

echo "Adding Helm repositories..."
for addon_dir in "$STACK_DIR/cluster-addon"/*/; do
    [[ -f "$addon_dir/Chart.yaml" ]] || continue

    num_deps=$(yq '.dependencies | length' "$addon_dir/Chart.yaml")
    [[ "$num_deps" == "0" || "$num_deps" == "null" ]] && continue

    for ((i=0; i<num_deps; i++)); do
        dep_name=$(yq -r ".dependencies[$i].name" "$addon_dir/Chart.yaml")
        dep_repo=$(yq -r ".dependencies[$i].repository // \"\"" "$addon_dir/Chart.yaml")

        [[ -z "$dep_repo" ]] && continue

        # Use chart name as helm repo name (unique per chart)
        if [[ -z "${ADDED_REPOS[$dep_name]+_}" ]]; then
            helm repo add "$dep_name" "$dep_repo" 2>/dev/null || true
            ADDED_REPOS["$dep_name"]="$dep_repo"
        fi
    done
done

if [[ ${#ADDED_REPOS[@]} -gt 0 ]]; then
    helm repo update > /dev/null 2>&1
fi
echo ""

# ============================================
# Helper functions
# ============================================

is_k8s_tied() {
    [[ -n "${K8S_TIED_CHARTS[$1]+_}" ]]
}

get_latest_version() {
    local chart="$1"

    # Repo must have been added in the setup phase
    [[ -z "${ADDED_REPOS[$chart]+_}" ]] && return

    if is_k8s_tied "$chart" && [[ -n "$K8S_VERSION" ]]; then
        local k8s_minor="${K8S_VERSION#*.}"
        helm search repo "$chart/$chart" --versions -o json 2>/dev/null | \
            jq -r --arg minor "$k8s_minor" \
                '[.[] | select(.version | startswith("2." + $minor + "."))] | .[0].version // empty' 2>/dev/null || echo ""
    else
        helm search repo "$chart/$chart" -o json 2>/dev/null | \
            jq -r '.[0].version // empty' 2>/dev/null || echo ""
    fi
}

# Update versions.yaml when a K8s-tied addon is updated
update_versions_yaml() {
    local chart_name="$1"
    local new_version="$2"

    [[ ! -f "$STACK_DIR/versions.yaml" ]] && return

    # Check if this chart has entries in versions.yaml
    local has_key
    has_key=$(yq -r ".[0] | has(\"${chart_name}\")" "$STACK_DIR/versions.yaml" 2>/dev/null || echo "false")
    [[ "$has_key" != "true" ]] && return

    # Update all entries in versions.yaml for this chart, matching by K8s minor version
    local entry_count
    entry_count=$(yq '. | length' "$STACK_DIR/versions.yaml")

    for ((j=0; j<entry_count; j++)); do
        local entry_k8s
        entry_k8s=$(yq -r ".[$j].kubernetes" "$STACK_DIR/versions.yaml" | grep -oP '^\d+\.\d+')
        local entry_minor="${entry_k8s#*.}"

        if is_k8s_tied "$chart_name" && [[ -n "$entry_minor" ]]; then
            # For K8s-tied: find the matching version for this K8s minor
            local tied_version
            tied_version=$(helm search repo "$chart_name/$chart_name" --versions -o json 2>/dev/null | \
                jq -r --arg minor "$entry_minor" \
                    '[.[] | select(.version | startswith("2." + $minor + "."))] | .[0].version // empty' 2>/dev/null || echo "")
            if [[ -n "$tied_version" ]]; then
                yq -i ".[${j}].\"${chart_name}\" = \"${tied_version}\"" "$STACK_DIR/versions.yaml"
                echo "      Updated versions.yaml: K8s ${entry_k8s} -> ${chart_name} ${tied_version}"
            fi
        else
            yq -i ".[${j}].\"${chart_name}\" = \"${new_version}\"" "$STACK_DIR/versions.yaml"
            echo "      Updated versions.yaml: ${chart_name} ${new_version}"
        fi
    done
}

# ============================================
# Process each addon
# ============================================

UPDATES_COUNT=0

for addon_dir in "$STACK_DIR/cluster-addon"/*/; do
    [[ -f "$addon_dir/Chart.yaml" ]] || continue

    addon_name=$(basename "$addon_dir")
    chart_file="$addon_dir/Chart.yaml"

    echo "--- $addon_name ---"

    num_deps=$(yq '.dependencies | length' "$chart_file")
    if [[ "$num_deps" == "0" || "$num_deps" == "null" ]]; then
        echo "  No dependencies"
        continue
    fi

    for ((i=0; i<num_deps; i++)); do
        dep_name=$(yq -r ".dependencies[$i].name" "$chart_file")
        current_version=$(yq -r ".dependencies[$i].version" "$chart_file")

        latest_version=$(get_latest_version "$dep_name")

        if [[ -z "$latest_version" ]]; then
            echo "  $dep_name: could not query upstream"
            continue
        fi

        if [[ "$current_version" == "$latest_version" ]]; then
            echo "  $dep_name: $current_version (up to date)"
            continue
        fi

        echo ""
        echo "  Update available: $dep_name"
        echo "    Current: $current_version"
        echo "    Latest:  $latest_version"

        if [[ "$AUTO_APPROVE" == true ]]; then
            REPLY=y
            echo "    Auto-approved (--yes)"
        else
            read -p "    Apply? [y/N] " -n 1 -r
            echo ""
        fi

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            yq -i ".dependencies[$i].version = \"$latest_version\"" "$chart_file"
            echo "    Updated Chart.yaml"

            # Also update versions.yaml for K8s-tied addons
            if is_k8s_tied "$dep_name"; then
                update_versions_yaml "$dep_name" "$latest_version"
            fi

            UPDATES_COUNT=$((UPDATES_COUNT + 1))
        else
            echo "    Skipped"
        fi
    done
    echo ""
done

# ============================================
# Summary
# ============================================

if [[ $UPDATES_COUNT -gt 0 ]]; then
    echo "Applied $UPDATES_COUNT update(s)."
    echo ""
    echo "Next steps:"
    echo "  git diff $STACK_DIR/"
    echo "  ./hack/build.sh $STACK_DIR --all"
    echo "  git add $STACK_DIR && git commit -m 'chore: update addon versions'"
else
    echo "All addons are up to date."
fi
