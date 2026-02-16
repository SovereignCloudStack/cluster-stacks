#!/usr/bin/env bash
# Migrate a Cluster YAML from old scs2 variable names to the new unified names.
#
# Transforms topology.variables entries:
#   controlPlaneFlavor/workerFlavor        -> flavor (+ worker override)
#   controlPlaneRootDisk/workerRootDisk    -> rootDisk (+ worker override)
#   controlPlaneServerGroupID/workerServerGroupID -> serverGroupID (+ worker override)
#   workerAdditionalBlockDevices           -> additionalBlockDevices
#   workerSecurityGroups                   -> securityGroups (merged)
#   workerSecurityGroupIDs                 -> securityGroupIDs (merged)
#   apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs -> apiServerAllowedCIDRs
#
# Usage:
#   ./hack/migrate-cluster.sh <cluster.yaml>
#   ./hack/migrate-cluster.sh <cluster.yaml> --in-place
#
# Without --in-place, the transformed YAML is written to stdout.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <cluster.yaml> [--in-place]" >&2
    exit 1
fi

INPUT="$1"
IN_PLACE=false
[[ "${2:-}" == "--in-place" ]] && IN_PLACE=true

if [[ ! -f "$INPUT" ]]; then
    echo "File not found: $INPUT" >&2
    exit 1
fi

if ! command -v yq &>/dev/null; then
    echo "yq is required but not found" >&2
    exit 1
fi

# Work on a temp copy
TEMP=$(mktemp)
cp "$INPUT" "$TEMP"

# Helper: get a variable value by name from topology.variables
get_var() {
    yq -r ".spec.topology.variables[] | select(.name == \"$1\") | .value" "$TEMP" 2>/dev/null
}

# Helper: check if a variable exists
has_var() {
    local val
    val=$(yq -r ".spec.topology.variables[] | select(.name == \"$1\") | .name" "$TEMP" 2>/dev/null)
    [[ -n "$val" ]]
}

# Helper: delete a variable by name
del_var() {
    yq -i "del(.spec.topology.variables[] | select(.name == \"$1\"))" "$TEMP"
}

# Helper: set a variable (add or update)
set_var() {
    local name="$1" value="$2"
    if has_var "$name"; then
        yq -i "(.spec.topology.variables[] | select(.name == \"$name\")).value = $value" "$TEMP"
    else
        yq -i ".spec.topology.variables += [{\"name\": \"$name\", \"value\": $value}]" "$TEMP"
    fi
}

# Helper: add a worker override
add_worker_override() {
    local name="$1" value="$2"
    # Ensure overrides array exists on first machineDeployment
    yq -i '.spec.topology.workers.machineDeployments[0].variables.overrides //= []' "$TEMP"
    yq -i ".spec.topology.workers.machineDeployments[0].variables.overrides += [{\"name\": \"$name\", \"value\": $value}]" "$TEMP"
}

CHANGES=0

# ============================================
# Rename simple variables
# ============================================

if has_var "apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs"; then
    val=$(get_var "apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs")
    del_var "apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs"
    set_var "apiServerAllowedCIDRs" "$val"
    echo "Renamed: apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs -> apiServerAllowedCIDRs" >&2
    CHANGES=$((CHANGES + 1))
fi

# ============================================
# Unify CP/Worker split variables
# ============================================

for pair in \
    "controlPlaneFlavor:workerFlavor:flavor" \
    "controlPlaneRootDisk:workerRootDisk:rootDisk" \
    "controlPlaneServerGroupID:workerServerGroupID:serverGroupID"; do

    cp_var="${pair%%:*}"
    rest="${pair#*:}"
    worker_var="${rest%%:*}"
    new_var="${rest#*:}"

    cp_val=""
    worker_val=""
    has_cp=false
    has_worker=false

    if has_var "$cp_var"; then
        cp_val=$(get_var "$cp_var")
        has_cp=true
    fi
    if has_var "$worker_var"; then
        worker_val=$(get_var "$worker_var")
        has_worker=true
    fi

    if $has_cp || $has_worker; then
        # Use CP value as the cluster-level default, or worker if CP not set
        if $has_cp; then
            set_var "$new_var" "\"$cp_val\""
            del_var "$cp_var"
        fi

        if $has_worker; then
            if $has_cp && [[ "$cp_val" != "$worker_val" ]]; then
                # Different values: CP goes to cluster level, worker to override
                add_worker_override "$new_var" "\"$worker_val\""
            elif ! $has_cp; then
                # Only worker set: use as cluster level
                set_var "$new_var" "\"$worker_val\""
            fi
            del_var "$worker_var"
        fi

        echo "Unified: $cp_var + $worker_var -> $new_var" >&2
        CHANGES=$((CHANGES + 1))
    fi
done

# ============================================
# Rename worker-only variables to unified
# ============================================

if has_var "workerAdditionalBlockDevices"; then
    val=$(yq '.spec.topology.variables[] | select(.name == "workerAdditionalBlockDevices") | .value' "$TEMP")
    del_var "workerAdditionalBlockDevices"
    set_var "additionalBlockDevices" "$val"
    echo "Renamed: workerAdditionalBlockDevices -> additionalBlockDevices" >&2
    CHANGES=$((CHANGES + 1))
fi

# Worker-specific security groups are removed — users should use the unified securityGroups/securityGroupIDs
for old_var in "workerSecurityGroups" "workerSecurityGroupIDs"; do
    if has_var "$old_var"; then
        echo "WARNING: $old_var is no longer supported. Use securityGroups/securityGroupIDs instead." >&2
        echo "         The value has been removed. Please review manually." >&2
        del_var "$old_var"
        CHANGES=$((CHANGES + 1))
    fi
done

# ============================================
# Output
# ============================================

if [[ $CHANGES -eq 0 ]]; then
    echo "No migrations needed" >&2
    rm -f "$TEMP"
    exit 0
fi

echo "Applied $CHANGES migration(s)" >&2

if $IN_PLACE; then
    cp "$TEMP" "$INPUT"
    echo "Updated: $INPUT" >&2
else
    cat "$TEMP"
fi

rm -f "$TEMP"
