#!/usr/bin/env bash
# Scaffold a new Kubernetes minor version for all cluster stacks.
#
# For every stack base directory (providers/<provider>/<stack>/) the highest existing
# 1-XX/ directory is copied to 1-<new>/ and the version references are adjusted:
#   - csctl.yaml: kubernetesVersion and the ccm/csi addon constraints (2.XX.x)
#   - cluster-class/Chart.yaml: chart name and description
#   - cluster-class/values.yaml: node image tags (Docker stacks, the final tag is set by build.sh)
#   - cluster-addon/{ccm,csi}/Chart.yaml: 2.<new>.0 (K8s-tied addons)
#
# Stacks with a DEPRECATED file in their base directory are skipped, as well as stacks
# that already have the new version.
#
# Afterwards `hack/update.sh versions --all` resolves the latest Kubernetes patch
# versions (needs network access). Run `hack/update.sh addons` to pick the latest
# matching ccm/csi chart versions.
#
# Usage:
#   ./hack/add-version.sh <X.Y> [--no-update]
#
# Example:
#   ./hack/add-version.sh 1.37

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    echo "Usage: $0 <X.Y> [--no-update]" >&2
    exit 1
}

NEW_SHORT=""
RUN_UPDATE=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-update) RUN_UPDATE=false; shift ;;
        -h|--help)   usage ;;
        -*)          echo "Unknown option: $1" >&2; usage ;;
        *)
            if [[ -n "$NEW_SHORT" ]]; then
                echo "Unexpected argument: $1" >&2
                usage
            fi
            NEW_SHORT="$1"; shift
            ;;
    esac
done

if [[ ! "$NEW_SHORT" =~ ^1\.[0-9]+$ ]]; then
    echo "Invalid or missing Kubernetes minor version: '${NEW_SHORT}' (expected e.g. 1.37)" >&2
    usage
fi

cd "$REPO_ROOT"

new_dash="${NEW_SHORT//./-}"
new_minor="${NEW_SHORT#1.}"
found=0

for stack_base in providers/*/*/; do
    stack_base="${stack_base%/}"
    [[ -d "$stack_base" ]] || continue

    if [[ -f "$stack_base/DEPRECATED" ]]; then
        echo "  SKIP $stack_base (deprecated)" >&2
        continue
    fi

    latest=$(find "$stack_base" -mindepth 1 -maxdepth 1 -type d -name '1-*' | sort -V | tail -1)
    [[ -n "$latest" ]] || continue

    dst="$stack_base/$new_dash"
    if [[ -d "$dst" ]]; then
        echo "  SKIP $dst (already exists)" >&2
        continue
    fi

    old_dash="$(basename "$latest")"
    old_minor="${old_dash#1-}"
    if (( new_minor <= old_minor )); then
        echo "  SKIP $stack_base (latest version $old_dash is not older than $new_dash)" >&2
        continue
    fi

    found=1
    echo "---" >&2
    echo "Creating $dst from $latest ..." >&2
    cp -r "$latest" "$dst"

    csctl="$dst/csctl.yaml"
    if [[ -f "$csctl" ]]; then
        yq -i ".config.kubernetesVersion = \"v${NEW_SHORT}\"" "$csctl"
        sed -i "s/2\.${old_minor}\.x/2.${new_minor}.x/g" "$csctl"
    fi

    chart="$dst/cluster-class/Chart.yaml"
    if [[ -f "$chart" ]]; then
        sed -i "s/${old_dash}/${new_dash}/g; s/1\.${old_minor}\b/1.${new_minor}/g" "$chart"
    fi

    values="$dst/cluster-class/values.yaml"
    if [[ -f "$values" ]] && yq -e '.images' "$values" >/dev/null 2>&1; then
        # build.sh sets the final tag from csctl.yaml, this only keeps the file consistent
        sed -i "s|:v1\.${old_minor}\.[0-9]*|:v1.${new_minor}.0|g" "$values"
    fi

    for addon in ccm csi; do
        addon_chart="$dst/cluster-addon/$addon/Chart.yaml"
        [[ -f "$addon_chart" ]] || continue
        sed -i -E "s/version: 2\.${old_minor}\.[0-9]+/version: 2.${new_minor}.0/" "$addon_chart"
    done

    echo "  Done: $dst" >&2
done

if [[ "$found" -eq 0 ]]; then
    echo "No stacks found to scaffold." >&2
    exit 1
fi

if [[ "$RUN_UPDATE" == "true" ]]; then
    echo "" >&2
    echo "=== Resolving latest patches ===" >&2
    ./hack/update.sh versions --all
fi

echo "" >&2
echo "New version ${NEW_SHORT} scaffolded for all maintained stacks." >&2
echo "Next: run 'hack/update.sh addons' (or 'just update addons') to pick the latest ccm/csi chart versions." >&2
