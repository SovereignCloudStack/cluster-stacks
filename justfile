# Cluster Stacks build system, see docs/build-system.md
#
# The stack is selected with PROVIDER and CLUSTER_STACK (default: openstack/scs), either from the
# environment, from a .env file or on the command line: `just CLUSTER_STACK=scs2 matrix`.
#
# Wherever a Kubernetes version is expected, a bare minor version as first argument is
# shorthand for `--version`: `just build 1.35` == `just build --version 1.35`.

set dotenv-load
set positional-arguments
set shell := ["bash", "-euo", "pipefail", "-c"]

export PROVIDER := env("PROVIDER", "openstack")
export CLUSTER_STACK := env("CLUSTER_STACK", "scs")

container_image := "cluster-stack-tools"

# Show available recipes
default:
    @just --list --unsorted

# ============================================
# Build & publish
# ============================================

# Build release artifacts (e.g. `just build 1.35`, `just build --all`)
build *args:
    @if [[ "${1:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then set -- --version "$@"; fi; ./hack/build.sh "$@"

# Build and publish to the OCI registry (e.g. `just publish 1.35`, `just publish --all`)
publish *args:
    @if [[ "${1:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then set -- --version "$@"; fi; ./hack/build.sh --publish "$@"

# Build, publish and print the ClusterStack resource (e.g. `just dev 1.35 | kubectl apply -f -`)
dev version *args:
    #!/usr/bin/env bash
    set -euo pipefail
    version="$1"; shift
    ./hack/build.sh --publish --version "$version" "$@" >&2
    echo "" >&2
    echo "================================================================" >&2
    echo "ClusterStack resource (pipe to kubectl apply -f -)" >&2
    echo "================================================================" >&2
    ./hack/generate-resources.sh --version "$version" --clusterstack-only

# Install or upgrade the Cluster Stack Operator (CSO_CHART, CSO_IMAGE_REPOSITORY, CSO_IMAGE_TAG to override)
install-cso:
    ./hack/build.sh --install-cso

# Remove build artifacts
clean:
    rm -rf .release
    @echo "Cleaned .release"

# ============================================
# Maintenance
# ============================================

# Update Kubernetes patch versions and/or addons (e.g. `just update versions --all --dry-run`)
update *args:
    ./hack/update.sh "$@"

# Scaffold a new Kubernetes minor version for all stacks that are not deprecated (e.g. `just add-version 1.37`)
add-version version *args:
    ./hack/add-version.sh "$@"

# ============================================
# Resources & docs
# ============================================

# Generate ClusterStack and Cluster manifests (e.g. `just generate-resources 1.35`)
generate-resources *args:
    @if [[ "${1:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then set -- --version "$@"; fi; ./hack/generate-resources.sh "$@"

# Generate only the ClusterStack manifest
generate-clusterstack *args:
    @if [[ "${1:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then set -- --version "$@"; fi; ./hack/generate-resources.sh --clusterstack-only "$@"

# Generate only the Cluster manifest
generate-cluster *args:
    @if [[ "${1:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then set -- --version "$@"; fi; ./hack/generate-resources.sh --cluster-only "$@"

# Generate ORC Image (default) or image-manager manifests (e.g. `just generate-image-manifests 1.35`)
generate-image-manifests *args:
    @if [[ "${1:-}" =~ ^[0-9]+\.[0-9]+$ ]]; then set -- --version "$@"; fi; ./hack/generate-image-manifests.sh "$@"

# Convert the variables of a Cluster manifest from scs2 to scs (e.g. `just migrate-cluster cluster.yaml`)
migrate-cluster *args:
    ./hack/migrate-cluster.sh "$@"

# Show the version matrix (`--markdown` for a table)
matrix *args:
    ./hack/show-matrix.sh "$@"

# Update the generated sections (version matrix, variables) of docs/providers/<provider>/<stack>-configuration.md
generate-docs:
    #!/usr/bin/env bash
    set -euo pipefail
    for stack_base in providers/*/*/; do
        stack_base="${stack_base%/}"
        provider=$(basename "$(dirname "$stack_base")")
        stack=$(basename "$stack_base")
        latest=$(find "$stack_base" -mindepth 1 -maxdepth 1 -type d -name '1-*' | sort -V | tail -1)
        [[ -n "$latest" ]] || continue
        doc="docs/providers/${provider}/${stack}-configuration.md"
        if [[ ! -f "$doc" ]] || ! grep -q '<!-- BEGIN GENERATED:' "$doc"; then
            echo "Skipping ${provider}/${stack}: ${doc} has no generated sections"
            continue
        fi
        echo "Updating ${doc} from ${latest} ..."
        python3 ./hack/docugen.py "$latest" --matrix --update "$doc"
    done

# ============================================
# Tooling container
# ============================================

# Build the tools container image (podman preferred, docker as fallback)
container-build:
    #!/usr/bin/env bash
    set -euo pipefail
    runtime=$(command -v podman || command -v docker || { echo "neither podman nor docker found" >&2; exit 1; })
    "$runtime" build -t {{ container_image }} -f Containerfile .

# Run a recipe inside the tools container (e.g. `just container-run build --all`)
container-run *args:
    #!/usr/bin/env bash
    set -euo pipefail
    runtime=$(command -v podman || command -v docker || { echo "neither podman nor docker found" >&2; exit 1; })
    if ! "$runtime" image inspect {{ container_image }} >/dev/null 2>&1; then
        just container-build
    fi
    tty_args=()
    if [[ -t 0 && -t 1 ]]; then tty_args=(-it); fi
    "$runtime" run --rm "${tty_args[@]}" \
        -v "$PWD:/workspace" -w /workspace \
        -e PROVIDER -e CLUSTER_STACK \
        -e OCI_REGISTRY -e OCI_REPOSITORY -e OCI_USERNAME -e OCI_PASSWORD -e OCI_ACCESS_TOKEN \
        -e GITHUB_TOKEN \
        {{ container_image }} just "$@"
