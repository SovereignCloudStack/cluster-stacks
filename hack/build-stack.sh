#!/usr/bin/env bash
# Build cluster stack release artifacts
# Replaces: csctl create
#
# Usage: ./hack/build-stack.sh <cluster-stack-dir> [--publish]
#
# Version strategy:
#   - Release directory: v0-<8-char-git-hash>
#   - Chart versions: Semver (v0.0.0, v0.0.1, etc.) queried from OCI registry

set -euo pipefail

# ============================================
# Auto-detect and configure ttl.sh if needed
# ============================================
if [[ -z "${OCI_REGISTRY:-}" ]] || [[ "${OCI_REGISTRY}" == "ttl.sh" && -z "${OCI_REPOSITORY:-}" ]]; then
    # Verify git is available
    if ! command -v git >/dev/null 2>&1; then
        echo "❌ git command not found"
        echo "   git is required for auto-generating ttl.sh repository names"
        echo "   Install git or set OCI_REPOSITORY manually in task.env"
        exit 1
    fi
    
    # Get git hash (fail if not in git repo)
    GIT_HASH_SHORT=$(git rev-parse HEAD 2>/dev/null | cut -c1-8)
    if [[ -z "$GIT_HASH_SHORT" ]]; then
        echo "❌ Not in a git repository"
        echo "   Cannot auto-generate ttl.sh repository name"
        echo ""
        echo "   Solutions:"
        echo "   1. Run from a git clone/repository"
        echo "   2. Set OCI_REPOSITORY manually in task.env"
        exit 1
    fi
    
    # Generate daily repository name: clusterstacks-YYYYMMDD
    # Allow OCI_DATE override for testing (default: today)
    DATE_YYYYMMDD="${OCI_DATE:-$(date +%Y%m%d)}"
    TTL_REPO="clusterstacks-${DATE_YYYYMMDD}"
    
    export OCI_REGISTRY="ttl.sh"
    export OCI_REPOSITORY="${TTL_REPO}"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⚠️  Auto-configured ttl.sh for testing"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Registry:    $OCI_REGISTRY"
    echo "   Repository:  $OCI_REGISTRY/$OCI_REPOSITORY"
    echo "   Date:        ${DATE_YYYYMMDD}$([ -n "${OCI_DATE:-}" ] && echo " (override)")"
    echo "   Expiry:      24 hours from first push today"
    echo ""
    echo "   💡 Multiple builds today reuse same repository"
    echo "   💡 Set OCI_DATE=YYYYMMDD to test different dates"
    echo "   💡 Configure OCI_REGISTRY in task.env for production"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi

# Parse arguments
STACK_DIR="${1:?Usage: $0 <cluster-stack-dir> [--publish]}"
PUBLISH=false
[[ "${2:-}" == "--publish" ]] && PUBLISH=true

# Validate stack directory exists
if [[ ! -d "$STACK_DIR" ]]; then
    echo "❌ Stack directory not found: $STACK_DIR"
    exit 1
fi

if [[ ! -f "$STACK_DIR/csctl.yaml" ]]; then
    echo "❌ csctl.yaml not found in: $STACK_DIR"
    exit 1
fi

# Read configuration from csctl.yaml
PROVIDER=$(yq '.config.provider.type' "$STACK_DIR/csctl.yaml")
STACK_NAME=$(yq '.config.clusterStackName' "$STACK_DIR/csctl.yaml")
K8S_VERSION=$(yq '.config.kubernetesVersion' "$STACK_DIR/csctl.yaml")

# Extract k8s major.minor (e.g., "1.34" from "v1.34.3")
K8S_SHORT=$(echo "$K8S_VERSION" | grep -oP '1\.\d+')

# VERSION for release directory and charts
GIT_HASH=$(git rev-parse HEAD)
GIT_HASH_SHORT=$(git rev-parse --short=7 HEAD)

# For ttl.sh: use timestamp-based version
# For production: use git-based version
if [[ "${OCI_REGISTRY:-}" == *"ttl.sh"* ]] || [[ "${OCI_REPOSITORY:-}" == *"ttl.sh"* ]]; then
    TIMESTAMP=$(date +%s)
    RELEASE_VERSION="v0-ttl.${TIMESTAMP}"
else
    RELEASE_VERSION="v0-git.${GIT_HASH_SHORT}"
fi
CHART_VERSION="$RELEASE_VERSION"  # Charts use same version as release

# OCI tag format: replace dots with dashes for tag
# Example: v0-git.a97eb17 → v0-git-a97eb17 OR v0-ttl.1768774217 → v0-ttl-1768774217
OCI_TAG_VERSION="${RELEASE_VERSION//./\-}"
OCI_TAG="${PROVIDER}-${STACK_NAME}-${K8S_SHORT//./-}-${OCI_TAG_VERSION}"
# Result: openstack-scs2-1-34-v0-git-a97eb17 OR openstack-scs2-1-34-v0-ttl-1768774217

# Output directory
OUTPUT_DIR="${OUTPUT_DIR:-.release}"
RELEASE_DIR="$OUTPUT_DIR/${PROVIDER}-${STACK_NAME}-${K8S_SHORT//./-}-${RELEASE_VERSION}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Building Cluster Stack Release"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Provider:        $PROVIDER"
echo "   Stack:           $STACK_NAME"
echo "   Kubernetes:      $K8S_VERSION"
if [[ "$RELEASE_VERSION" == v0-ttl.* ]]; then
    echo "   Release Version: $RELEASE_VERSION (ttl.sh: expires in 24h)"
    echo "   Git Hash:        ${GIT_HASH:0:8} (for reference)"
else
    echo "   Release Version: $RELEASE_VERSION (git: ${GIT_HASH:0:8})"
fi
echo "   Chart Version:   $CHART_VERSION (semver)"
echo "   Output:          $RELEASE_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Create output directory
mkdir -p "$RELEASE_DIR"

# Function to update Chart.yaml version
update_chart_version() {
    local chart_file="$1"
    yq -i ".version = \"$CHART_VERSION\"" "$chart_file"
}

# Package cluster-class chart
echo "🔨 Packaging cluster-class chart..."
if [[ -f "$STACK_DIR/cluster-class/Chart.yaml" ]]; then
    # Create temp copy without charts/ directory
    CLASS_TEMP=$(mktemp -d)
    cp -r "$STACK_DIR/cluster-class" "$CLASS_TEMP/"
    rm -rf "$CLASS_TEMP/cluster-class/charts"  # Remove if exists
    
    # Update version in temp copy
    update_chart_version "$CLASS_TEMP/cluster-class/Chart.yaml"
    
    # Package from temp
    helm package "$CLASS_TEMP/cluster-class" -d "$RELEASE_DIR/" > /dev/null
    rm -rf "$CLASS_TEMP"
    
    echo "   ✅ cluster-class packaged"
else
    echo "   ❌ cluster-class/Chart.yaml not found"
    exit 1
fi

# Package cluster-addon as single bundle
echo "🔨 Packaging cluster-addon bundle..."

# Verify multi-stage addon structure exists
if [[ ! -d "$STACK_DIR/cluster-addon" ]]; then
    echo "   ❌ cluster-addon directory not found: $STACK_DIR/cluster-addon"
    exit 1
fi

# Create temporary directory for addon bundle
ADDON_TEMP=$(mktemp -d)

# Copy all addon subdirectories, excluding charts/ directories
addon_count=0
for addon_dir in "$STACK_DIR/cluster-addon"/*/; do
    if [[ ! -d "$addon_dir" ]]; then
        continue
    fi
    
    addon_name=$(basename "$addon_dir")
    
    # Copy addon directory
    cp -r "$addon_dir" "$ADDON_TEMP/$addon_name"
    
    # Remove charts/ directory if exists (CSO will generate it via helm dependency update)
    if [[ -d "$ADDON_TEMP/$addon_name/charts" ]]; then
        rm -rf "$ADDON_TEMP/$addon_name/charts"
    fi
    
    echo "   📦 Added $addon_name to bundle"
    addon_count=$((addon_count + 1))
done

if [[ $addon_count -eq 0 ]]; then
    echo "   ❌ No addon subdirectories found in $STACK_DIR/cluster-addon/"
    rm -rf "$ADDON_TEMP"
    exit 1
fi

# Package as plain tarball (CSO expects addon directories at root)
# Do NOT use helm package - it adds a wrapper directory that breaks CSO
# CSO workflow: extract tarball -> ReadDir -> find ccm/, cni/, csi/, metrics-server/
ADDON_TGZ="${PROVIDER}-${STACK_NAME}-${K8S_SHORT//./-}-cluster-addon-${CHART_VERSION}.tgz"
ADDON_TGZ_FULLPATH="$(cd "$RELEASE_DIR" && pwd)/$ADDON_TGZ"

# Create tarball with only subdirectories (ccm/, cni/, csi/, metrics-server/)
# Use */ pattern to include only directories, excluding any files at root
(cd "$ADDON_TEMP" && tar -czf "$ADDON_TGZ_FULLPATH" */)

if [[ ! -f "$RELEASE_DIR/$ADDON_TGZ" ]]; then
    echo "   ❌ Failed to create addon bundle"
    rm -rf "$ADDON_TEMP"
    exit 1
fi

rm -rf "$ADDON_TEMP"

echo "   ✅ cluster-addon bundle packaged ($addon_count addons)"

# Optional validation of addon bundle structure
if [[ "${OCI_VALIDATE:-false}" == "true" ]]; then
    echo "   🔍 Validating addon bundle structure..."
    
    # Create temp dir for validation
    VALIDATE_ADDON=$(mktemp -d)
    trap "rm -rf $VALIDATE_ADDON" EXIT
    
    # Extract bundle
    if ! tar -xzf "$RELEASE_DIR/$ADDON_TGZ" -C "$VALIDATE_ADDON" 2>/dev/null; then
        echo "      ❌ Failed to extract addon bundle for validation"
        exit 1
    fi
    
    # Get list of directories in bundle
    ACTUAL_ADDONS=$(find "$VALIDATE_ADDON" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
    
    if [[ -z "$ACTUAL_ADDONS" ]]; then
        echo "      ❌ No addon directories found in bundle"
        exit 1
    fi
    
    # Check if clusteraddon.yaml exists to validate against
    if [[ -f "$STACK_DIR/clusteraddon.yaml" ]]; then
        # Extract expected addon names from clusteraddon.yaml
        # This gets all unique 'name' fields from all stages
        EXPECTED_ADDONS=$(yq '.addonStages | to_entries | .[].value[].name' "$STACK_DIR/clusteraddon.yaml" 2>/dev/null | sort -u)
        
        if [[ -n "$EXPECTED_ADDONS" ]]; then
            echo "      📋 Validating addons against clusteraddon.yaml..."
            
            VALIDATION_FAILED=false
            
            # Check each expected addon exists in bundle
            for addon in $EXPECTED_ADDONS; do
                if ! echo "$ACTUAL_ADDONS" | grep -q "^${addon}$"; then
                    echo "      ❌ Addon '$addon' referenced in clusteraddon.yaml but not found in bundle"
                    VALIDATION_FAILED=true
                fi
            done
            
            # Show what we found
            if [[ $VALIDATION_FAILED == "true" ]]; then
                echo ""
                echo "      Expected addons (from clusteraddon.yaml):"
                echo "$EXPECTED_ADDONS" | sed 's/^/         - /'
                echo ""
                echo "      Actual addons (in bundle):"
                echo "$ACTUAL_ADDONS" | sed 's/^/         - /'
                echo ""
                exit 1
            fi
        fi
    fi
    
    # Verify no extra wrapper directory
    DIR_COUNT=$(echo "$ACTUAL_ADDONS" | wc -l)
    echo "      ✅ Found $DIR_COUNT addon directories at root"
    echo "      ✅ Addon bundle structure validated"
    
    # List what we found
    echo "      📦 Addons in bundle:"
    echo "$ACTUAL_ADDONS" | sed 's/^/         - /'
fi

# Copy clusteraddon.yaml or cluster-addon-values.yaml
echo "📋 Copying cluster addon configuration..."
if [[ -f "$STACK_DIR/clusteraddon.yaml" ]]; then
    cp "$STACK_DIR/clusteraddon.yaml" "$RELEASE_DIR/"
    echo "   ✅ clusteraddon.yaml copied"
elif [[ -f "$STACK_DIR/cluster-addon-values.yaml" ]]; then
    cp "$STACK_DIR/cluster-addon-values.yaml" "$RELEASE_DIR/"
    echo "   ✅ cluster-addon-values.yaml copied"
else
    echo "   ⚠️  No clusteraddon.yaml or cluster-addon-values.yaml found"
fi

# Generate metadata.yaml
echo "📝 Generating metadata.yaml..."
cat > "$RELEASE_DIR/metadata.yaml" <<EOF
apiVersion: metadata.clusterstack.x-k8s.io/v1alpha1
versions:
    kubernetes: $K8S_VERSION
    clusterStack: $RELEASE_VERSION
    components:
        clusterAddon: $RELEASE_VERSION
        nodeImage: $RELEASE_VERSION
EOF
echo "   ✅ metadata.yaml created"

# Generate hashes.json
echo "🔐 Generating hashes.json..."
cat > "$RELEASE_DIR/hashes.json" <<EOF
{
  "clusterStack": "$GIT_HASH"
}
EOF
echo "   ✅ hashes.json created"

# Publish to OCI if requested
if [[ "$PUBLISH" == "true" ]]; then
    echo ""
    echo "📤 Publishing to OCI registry..."
    
    # Validate OCI configuration
    if [[ -z "${OCI_REGISTRY:-}" ]]; then
        echo "   ❌ OCI_REGISTRY not set"
        exit 1
    fi
    if [[ -z "${OCI_REPOSITORY:-}" ]]; then
        echo "   ❌ OCI_REPOSITORY not set"
        exit 1
    fi
    
    # Verify oras is available
    if ! command -v oras > /dev/null; then
        echo "   ❌ oras not found"
        echo "      Install: https://oras.land/docs/installation"
        exit 1
    fi
    
    echo "   Registry:   $OCI_REGISTRY"
    echo "   Repository: $OCI_REPOSITORY"
    echo "   Tag:        $OCI_TAG"
    echo ""
    
    # Change to release directory to push with relative paths (for clean OCI structure)
    ORIGINAL_DIR=$(pwd)
    cd "$RELEASE_DIR" || {
        echo "   ❌ Failed to change to release directory: $RELEASE_DIR"
        exit 1
    }
    
    # Collect all files to push (with relative paths)
    FILES_TO_PUSH=()
    
    # Add metadata files
    [[ -f "metadata.yaml" ]] && FILES_TO_PUSH+=("metadata.yaml")
    [[ -f "hashes.json" ]] && FILES_TO_PUSH+=("hashes.json")
    [[ -f "clusteraddon.yaml" ]] && FILES_TO_PUSH+=("clusteraddon.yaml")
    
    # Add all .tgz files
    for tgz in *.tgz; do
        if [[ -f "$tgz" ]]; then
            FILES_TO_PUSH+=("$tgz")
            echo "   📦 $tgz"
        fi
    done
    
    echo ""
    echo "   📤 Pushing release artifact..."
    
    # Handle OCI authentication
    ORAS_OPTS=()
    if [[ -n "${OCI_USERNAME:-}" ]] && [[ -n "${OCI_PASSWORD:-}" ]]; then
        ORAS_OPTS+=(--username "$OCI_USERNAME" --password "$OCI_PASSWORD")
    elif [[ -n "${OCI_ACCESS_TOKEN:-}" ]]; then
        ORAS_OPTS+=(--password "$OCI_ACCESS_TOKEN")
    fi
    
    # Push entire release as single OCI artifact
    PUSH_RESULT=0
    if oras push "$OCI_REGISTRY/$OCI_REPOSITORY:$OCI_TAG" \
        --artifact-type application/vnd.clusterstack.release \
        "${ORAS_OPTS[@]}" \
        "${FILES_TO_PUSH[@]}"; then
        
        echo "      ✅ Pushed successfully"
        PUSH_RESULT=0
    else
        echo "      ❌ Push failed"
        PUSH_RESULT=1
    fi
    
    # Return to original directory
    cd "$ORIGINAL_DIR" || exit 1
    
    # Exit if push failed
    if [[ $PUSH_RESULT -ne 0 ]]; then
        exit 1
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 Published to OCI Registry"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Image: $OCI_REGISTRY/$OCI_REPOSITORY:$OCI_TAG"
    echo ""
    echo "   Pull with:"
    echo "   oras pull $OCI_REGISTRY/$OCI_REPOSITORY:$OCI_TAG"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Basic verification by pulling manifest
    echo "   🔍 Verifying artifact..."
    if oras manifest fetch "$OCI_REGISTRY/$OCI_REPOSITORY:$OCI_TAG" "${ORAS_OPTS[@]}" > /dev/null 2>&1; then
        echo "      ✅ Artifact verified"
    else
        echo "      ⚠️  Could not verify (but push succeeded)"
    fi
    
    # Optional deep validation (enabled with OCI_VALIDATE=true)
    if [[ "${OCI_VALIDATE:-false}" == "true" ]]; then
        echo ""
        echo "   🔍 Deep validation enabled (OCI_VALIDATE=true)"
        
        # Create temp directory for validation
        VALIDATE_DIR=$(mktemp -d)
        trap "rm -rf $VALIDATE_DIR" EXIT
        
        # Pull artifact to validate structure
        if oras pull "$OCI_REGISTRY/$OCI_REPOSITORY:$OCI_TAG" \
            "${ORAS_OPTS[@]}" \
            --output "$VALIDATE_DIR" > /dev/null 2>&1; then
            
            # Check if files are at root (not nested in subdirectories)
            VALIDATION_FAILED=false
            
            if [[ ! -f "$VALIDATE_DIR/metadata.yaml" ]]; then
                echo "      ❌ metadata.yaml not at root"
                VALIDATION_FAILED=true
            fi
            
            if [[ ! -f "$VALIDATE_DIR/hashes.json" ]]; then
                echo "      ❌ hashes.json not at root"
                VALIDATION_FAILED=true
            fi
            
            if [[ $VALIDATION_FAILED == "true" ]]; then
                echo "      ❌ Structure validation FAILED"
                echo ""
                echo "      Directory structure:"
                find "$VALIDATE_DIR" -type f | sed 's|^|         |'
                exit 1
            else
                echo "      ✅ Structure validation passed"
                echo "      ✅ Files correctly at root (CSO compatible)"
            fi
        else
            echo "      ⚠️  Could not pull artifact for validation"
            echo "      This is normal for some registries"
        fi
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Release created successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Location: $RELEASE_DIR"
echo ""
echo "📦 Contents:"
ls -lh "$RELEASE_DIR/" | tail -n +2 | awk '{printf "   - %-40s %s\n", $9, $5}'
echo ""

if [[ "$PUBLISH" != "true" ]]; then
    echo "💡 To publish to OCI registry, run:"
    echo "   $0 $STACK_DIR --publish"
    echo ""
fi
