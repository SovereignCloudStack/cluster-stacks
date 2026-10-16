# Cluster Stacks build system
# Usage: just <recipe> [args...]
# Config: set PROVIDER and CLUSTER_STACK env vars or in .env (default: openstack/scs2)
#
# All hack/ scripts derive the stack directory from $PROVIDER and $CLUSTER_STACK
# automatically. You can also pass a stack-dir as first argument to override.

set dotenv-load
set positional-arguments

export PROVIDER := env("PROVIDER", "openstack")
export CLUSTER_STACK := env("CLUSTER_STACK", "scs2")
CONTAINER_IMAGE := "cluster-stack-tools"

# Show available recipes
default:
    @just --list

# ============================================
# Build & Publish
# ============================================

# Build cluster-stack for a K8s version (e.g., just build 1.34)
build version:
    ./hack/build.sh --version {{version}}

# Build cluster-stack for all K8s versions
build-all:
    ./hack/build.sh --all

# Build and publish for a K8s version (e.g., just publish 1.34)
publish version:
    ./hack/build.sh --version {{version}} --publish

# Build and publish all K8s versions
publish-all:
    ./hack/build.sh --all --publish

# Clean build artifacts
clean:
    rm -rf .release providers/*/out
    @echo "Cleaned .release and provider output directories"

# ============================================
# Addon Management
# ============================================

# Check upstream Helm repos for newer addon versions (pass --yes to auto-approve)
update-addons *FLAGS:
    ./hack/update-addons.sh {{FLAGS}}

# Check upstream addon versions for ALL stacks (pass --yes to auto-approve)
update-addons-all *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    for stack_dir in providers/*/*/; do
        [[ -d "$stack_dir/cluster-addon" ]] || continue
        echo "========== $stack_dir =========="
        ./hack/update-addons.sh "$stack_dir" {{FLAGS}}
        echo ""
    done

# Check for K8s patch updates, new minors, and addon version bumps
update-versions *FLAGS:
    ./hack/update-versions.sh {{FLAGS}}

# Check for version updates across ALL stacks
update-versions-all *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    for stack_dir in providers/*/*/; do
        [[ -f "$stack_dir/versions.yaml" ]] || continue
        echo "========== $stack_dir =========="
        ./hack/update-versions.sh "$stack_dir" {{FLAGS}}
        echo ""
    done

# ============================================
# Resource Generation
# ============================================

# Generate both ClusterStack + Cluster YAML (e.g., just generate-resources 1.34)
generate-resources version *FLAGS:
    ./hack/generate-resources.sh --version {{version}} {{FLAGS}}

# Generate only the ClusterStack resource (e.g., just generate-clusterstack 1.34)
generate-clusterstack version *FLAGS:
    ./hack/generate-resources.sh --version {{version}} --clusterstack-only {{FLAGS}}

# Generate only the Cluster resource (e.g., just generate-cluster 1.34)
generate-cluster version *FLAGS:
    ./hack/generate-resources.sh --version {{version}} --cluster-only {{FLAGS}}

# Generate OpenStack Image CRD manifests
generate-image-manifests:
    ./hack/generate-image-manifests.sh

# ============================================
# Info
# ============================================

# Show version matrix for all K8s versions and addons
matrix:
    ./hack/show-matrix.sh

# Generate configuration docs from ClusterClass variables
generate-docs:
    ./hack/docugen.py --template hack/config-template.md

# ============================================
# Container
# ============================================

# Detect container runtime (podman preferred, fallback to docker)
[private]
container-runtime:
    #!/usr/bin/env bash
    if command -v podman &>/dev/null; then echo "podman"
    elif command -v docker &>/dev/null; then echo "docker"
    else echo "ERROR: neither podman nor docker found" >&2; exit 1
    fi

# Build the tools container image
container-build:
    #!/usr/bin/env bash
    set -euo pipefail
    runtime=$(just container-runtime)
    echo "Building {{CONTAINER_IMAGE}} with $runtime..."
    $runtime build -t {{CONTAINER_IMAGE}} -f Containerfile .

# Run any just recipe inside the container (e.g., just container-run build-all)
container-run *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    runtime=$(just container-runtime)
    # Build image if it doesn't exist
    if ! $runtime image exists {{CONTAINER_IMAGE}} 2>/dev/null && \
       ! $runtime images --format '{{{{.Repository}}' | grep -qx '{{CONTAINER_IMAGE}}'; then
        echo "Image {{CONTAINER_IMAGE}} not found, building..."
        just container-build
    fi
    $runtime run --rm -it \
        -v "$(pwd):/workspace" \
        -w /workspace \
        -e PROVIDER="$PROVIDER" \
        -e CLUSTER_STACK="$CLUSTER_STACK" \
        {{CONTAINER_IMAGE}} \
        just {{ARGS}}
