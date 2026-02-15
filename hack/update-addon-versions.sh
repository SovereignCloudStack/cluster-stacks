#!/usr/bin/env bash
# Interactive Helm chart dependency updater
# Queries upstream repos for latest versions and asks before updating
#
# Usage: ./hack/update-addon-versions.sh <provider> <stack> [k8s-version]
# Example: ./hack/update-addon-versions.sh openstack scs2
# Example: ./hack/update-addon-versions.sh openstack scs2 1.34

set -euo pipefail

PROVIDER="${1:?Usage: $0 <provider> <stack> [k8s-version]}"
STACK="${2:?Usage: $0 <provider> <stack> [k8s-version]}"
K8S_VERSION="${3:-}"  # Optional K8s version for OpenStack charts
STACK_DIR="providers/$PROVIDER/$STACK"

if [[ ! -d "$STACK_DIR" ]]; then
    echo "❌ Stack directory not found: $STACK_DIR"
    exit 1
fi

# Detect K8s version if not provided
if [[ -z "$K8S_VERSION" ]]; then
    # Try to get the latest K8s version from versions.yaml
    if [[ -f "$STACK_DIR/versions.yaml" ]]; then
        K8S_VERSION=$(yq -r '.[0].kubernetes' "$STACK_DIR/versions.yaml" | grep -oP '1\.\d+' || echo "")
    fi
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Checking Helm Chart Updates"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Stack: $PROVIDER/$STACK"
echo "   Path:  $STACK_DIR/cluster-addon/"
if [[ -n "$K8S_VERSION" ]]; then
    echo "   K8s:   $K8S_VERSION (for OpenStack chart filtering)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Helm repository configuration
declare -A REPOS=(
    ["cilium"]="https://helm.cilium.io/"
    ["openstack-cloud-controller-manager"]="https://kubernetes.github.io/cloud-provider-openstack"
    ["openstack-cinder-csi"]="https://kubernetes.github.io/cloud-provider-openstack"
    ["metrics-server"]="https://kubernetes-sigs.github.io/metrics-server/"
)

# Add all Helm repositories
echo "📦 Adding Helm repositories..."
for repo_name in "${!REPOS[@]}"; do
    helm repo add "$repo_name" "${REPOS[$repo_name]}" 2>/dev/null || true
done

echo "🔄 Updating Helm repository cache..."
helm repo update > /dev/null 2>&1
echo "   ✅ Repository cache updated"
echo ""

# Function: Get latest version from Helm repo
# For OpenStack charts (CCM/CSI), filters by K8s version if available
get_latest_version() {
    local repo="$1"
    local chart="$2"
    
    # Check if this is an OpenStack chart that needs K8s version filtering
    local needs_k8s_filter=false
    if [[ "$chart" == "openstack-cloud-controller-manager" ]] || \
       [[ "$chart" == "openstack-cinder-csi" ]]; then
        needs_k8s_filter=true
    fi
    
    # If K8s version filtering is needed and available
    if [[ "$needs_k8s_filter" == "true" ]] && [[ -n "$K8S_VERSION" ]]; then
        # Extract minor version (1.34 -> 34)
        local k8s_minor="${K8S_VERSION#*.}"
        
        # Get latest chart version matching K8s minor version (2.34.x for K8s 1.34)
        helm search repo "$repo/$chart" --versions -o json 2>/dev/null | \
            jq -r --arg minor "$k8s_minor" \
                '[.[] | select(.version | startswith("2." + $minor + "."))] | .[0].version // empty' 2>/dev/null || echo ""
    else
        # For other charts (cilium, metrics-server), just get the latest
        helm search repo "$repo/$chart" -o json 2>/dev/null | \
            jq -r '.[0].version // empty' 2>/dev/null || echo ""
    fi
}

# Function: Ask user for confirmation
ask_update() {
    local addon="$1"
    local dep_name="$2"
    local current="$3"
    local latest="$4"
    
    echo ""
    echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo "┃ 🆙 Update Available                              ┃"
    echo "┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫"
    printf "┃ %-48s ┃\n" "  Addon:   $addon"
    printf "┃ %-48s ┃\n" "  Chart:   $dep_name"
    printf "┃ %-48s ┃\n" "  Current: $current"
    printf "┃ %-48s ┃\n" "  Latest:  $latest"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
    echo ""
    read -p "   Apply update? [y/N] " -n 1 -r
    echo ""
    
    [[ $REPLY =~ ^[Yy]$ ]]
}

# Track if any updates were made
UPDATES_MADE=false
UPDATES_COUNT=0

# Process each addon directory
for addon_dir in "$STACK_DIR/cluster-addon"/*/; do
    if [[ ! -f "$addon_dir/Chart.yaml" ]]; then
        continue
    fi
    
    addon_name=$(basename "$addon_dir")
    chart_file="$addon_dir/Chart.yaml"
    
    echo "═══════════════════════════════════════════════════"
    echo "🔧 Checking: $addon_name"
    echo "═══════════════════════════════════════════════════"
    
    # Read number of dependencies
    num_deps=$(yq '.dependencies | length' "$chart_file")
    
    if [[ "$num_deps" == "0" ]] || [[ "$num_deps" == "null" ]]; then
        echo "   ℹ️  No dependencies found"
        continue
    fi
    
    # Process each dependency
    for ((i=0; i<num_deps; i++)); do
        dep_name=$(yq ".dependencies[$i].name" "$chart_file")
        dep_repo=$(yq ".dependencies[$i].repository" "$chart_file")
        current_version=$(yq ".dependencies[$i].version" "$chart_file")
        
        # Find matching repo name
        repo_name=""
        for name in "${!REPOS[@]}"; do
            if [[ "${REPOS[$name]}" == "$dep_repo" ]]; then
                repo_name="$name"
                break
            fi
        done
        
        if [[ -z "$repo_name" ]]; then
            echo "   ⚠️  Unknown repository for $dep_name"
            echo "       Repository: $dep_repo"
            continue
        fi
        
        # Get latest version from Helm repo
        latest_version=$(get_latest_version "$repo_name" "$dep_name")
        
        if [[ -z "$latest_version" ]]; then
            echo "   ⚠️  Could not find $dep_name in $repo_name"
            continue
        fi
        
        # Compare versions
        if [[ "$current_version" == "$latest_version" ]]; then
            echo "   ✅ $dep_name: $current_version (up to date)"
        else
            # Ask user before updating
            if ask_update "$addon_name" "$dep_name" "$current_version" "$latest_version"; then
                yq -i ".dependencies[$i].version = \"$latest_version\"" "$chart_file"
                echo "   ✅ Updated to $latest_version"
                UPDATES_MADE=true
                ((UPDATES_COUNT++))
            else
                echo "   ⏭️  Skipped"
            fi
        fi
    done
    
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$UPDATES_MADE" == "true" ]]; then
    echo "✅ Updates Applied: $UPDATES_COUNT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📝 Next Steps:"
    echo ""
    echo "   1. Review changes:"
    echo "      git diff $STACK_DIR/cluster-addon/"
    echo ""
    echo "   2. Update versions.yaml with new component versions:"
    echo "      vim $STACK_DIR/versions.yaml"
    echo ""
    echo "   3. Test the changes:"
    echo "      task build-version -- <k8s-version>"
    echo ""
    echo "   4. Commit changes:"
    echo "      git add $STACK_DIR"
    echo "      git commit -m 'chore($PROVIDER/$STACK): update addon versions'"
    echo ""
else
    echo "ℹ️  No Updates Applied"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "All addon charts are up to date! 🎉"
    echo ""
fi
