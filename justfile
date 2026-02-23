# Cluster Stacks build system
# Usage: just <recipe> [args...]
# Config: set PROVIDER and CLUSTER_STACK env vars or in .env (default: openstack/scs)
#
# All hack/ scripts derive the stack base directory from $PROVIDER and $CLUSTER_STACK
# automatically (e.g., providers/openstack/scs). Each base directory contains
# per-minor-version subdirs (1-32, 1-33, etc.) with self-contained stack.yaml.
#
# Container mode: set RUN_IN_CONTAINER=true to transparently run recipes inside
# the tools container. Build the image first with: just container-build

set dotenv-load
set positional-arguments

export PROVIDER := env("PROVIDER", "openstack")
export CLUSTER_STACK := env("CLUSTER_STACK", "scs")
RUN_IN_CONTAINER := env("RUN_IN_CONTAINER", "false")
CONTAINER_IMAGE := "cluster-stack-tools"

# Show available recipes
default:
    @just --list

# ============================================
# Build & Publish
# ============================================

# Build cluster-stack (e.g., just build --version 1.34 or just build --all)
build *FLAGS:
    {{ if RUN_IN_CONTAINER == "true" { "just _container-exec build " + FLAGS } else { "./hack/build.sh " + FLAGS } }}

# Build and publish (e.g., just publish --version 1.34 or just publish --all)
publish *FLAGS:
    {{ if RUN_IN_CONTAINER == "true" { "just _container-exec publish " + FLAGS } else { "./hack/build.sh --publish " + FLAGS } }}

# Build, publish, and generate the ClusterStack resource (e.g., just dev --version 1.35)
dev *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    ./hack/build.sh --publish {{FLAGS}}
    # Extract --version from flags for generate-resources
    version=""
    prev=""
    for arg in {{FLAGS}}; do
        if [[ "$prev" == "--version" ]]; then version="$arg"; fi
        prev="$arg"
    done
    if [[ -n "$version" ]]; then
        echo ""
        echo "================================================================"
        echo "ClusterStack resource (pipe to kubectl apply -f -)"
        echo "================================================================"
        ./hack/generate-resources.sh --version "$version" --clusterstack-only
    fi

# Install/upgrade the CSO with OCI config matching current environment
install-cso:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "${OCI_REGISTRY:-}" ]]; then
        export OCI_REGISTRY="ttl.sh"
        export OCI_REPOSITORY="clusterstacks-$(date +%Y%m%d)"
        echo "Auto-configured ttl.sh: $OCI_REGISTRY/$OCI_REPOSITORY (expires in 24h)"
    fi
    CSO_CHART="${CSO_CHART:-oci://registry.scs.community/cluster-stacks/cso}"
    echo "Installing/upgrading CSO..."
    echo "  Chart:      $CSO_CHART"
    echo "  OCI config: $OCI_REGISTRY/${OCI_REPOSITORY:-}"
    echo ""
    helm upgrade -i cso "$CSO_CHART" \
        --namespace cso-system --create-namespace \
        --set controllerManager.manager.source=oci \
        --set "clusterStackVariables.ociRegistry=${OCI_REGISTRY}" \
        --set "clusterStackVariables.ociRepository=${OCI_REPOSITORY}"

# Clean build artifacts
clean:
    rm -rf .release
    @echo "Cleaned .release"

# ============================================
# Update
# ============================================

# Update K8s versions and/or addon charts (subcommands: versions, addons)
update *FLAGS:
    {{ if RUN_IN_CONTAINER == "true" { "just _container-exec update " + FLAGS } else { "./hack/update.sh " + FLAGS } }}

# ============================================
# Resource Generation
# ============================================

# Generate ClusterStack + Cluster YAML (e.g., just generate-resources --version 1.34)
generate-resources *FLAGS:
    {{ if RUN_IN_CONTAINER == "true" { "just _container-exec generate-resources " + FLAGS } else { "./hack/generate-resources.sh " + FLAGS } }}

# Generate only the ClusterStack resource
generate-clusterstack *FLAGS:
    {{ if RUN_IN_CONTAINER == "true" { "just _container-exec generate-clusterstack " + FLAGS } else { "./hack/generate-resources.sh --clusterstack-only " + FLAGS } }}

# Generate only the Cluster resource
generate-cluster *FLAGS:
    {{ if RUN_IN_CONTAINER == "true" { "just _container-exec generate-cluster " + FLAGS } else { "./hack/generate-resources.sh --cluster-only " + FLAGS } }}

# Generate OpenStack Image CRD manifests
generate-image-manifests *FLAGS:
    {{ if RUN_IN_CONTAINER == "true" { "just _container-exec generate-image-manifests " + FLAGS } else { "./hack/generate-image-manifests.sh " + FLAGS } }}

# ============================================
# Info
# ============================================

# Show version matrix for all K8s versions and addons
matrix:
    {{ if RUN_IN_CONTAINER == "true" { "just _container-exec matrix" } else { "./hack/show-matrix.sh" } }}

# Generate configuration docs for all stacks
generate-docs:
    #!/usr/bin/env bash
    set -euo pipefail
    template="hack/config-template.md"
    # For each provider/stack, pick the latest version directory and generate docs
    for stack_base in providers/*/*; do
        [[ -d "$stack_base" ]] || continue
        provider=$(basename "$(dirname "$stack_base")")
        stack=$(basename "$stack_base")
        # Find the latest version dir (highest 1-XX)
        latest=$(ls -d "$stack_base"/1-*/ 2>/dev/null | sort -V | tail -1)
        [[ -n "$latest" ]] || continue
        outdir="docs/providers/${provider}"
        outfile="${outdir}/${stack}-configuration.md"
        mkdir -p "$outdir"
        echo "Generating ${outfile} from ${latest} ..."
        python3 ./hack/docugen.py "$latest" \
            --template "$template" \
            --matrix \
            --output "$outfile"
    done
    echo "Done."

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

# Run a just recipe inside the container (used internally when RUN_IN_CONTAINER=true)
[private]
_container-exec +ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    runtime=$(just container-runtime)
    # Build image if it doesn't exist
    if ! $runtime image exists {{CONTAINER_IMAGE}} 2>/dev/null && \
       ! $runtime images --format '{{"{{.Repository}}"}}' | grep -qx '{{CONTAINER_IMAGE}}'; then
        echo "Image {{CONTAINER_IMAGE}} not found, building..."
        just container-build
    fi
    $runtime run --rm -it \
        -v "$(pwd):/workspace" \
        -w /workspace \
        -e PROVIDER="$PROVIDER" \
        -e CLUSTER_STACK="$CLUSTER_STACK" \
        -e RUN_IN_CONTAINER=false \
        {{CONTAINER_IMAGE}} \
        just {{ARGS}}
