#!/usr/bin/env bash
# Migrate a Cluster YAML from the scs2 variable names to the unified variable names of the scs stack.
#
# Transforms topology.variables entries:
#   controlPlaneFlavor/workerFlavor        -> flavor (control plane value; workers get an override if different)
#   controlPlaneRootDisk/workerRootDisk    -> rootDisk (same rule)
#   controlPlaneServerGroupID/workerServerGroupID -> serverGroupID (same rule)
#   workerAdditionalBlockDevices           -> additionalBlockDevices override on every machineDeployment
#                                             (additionalBlockDevices also applies to the control plane in scs)
#   apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs -> apiServerAllowedCIDRs
#
# If only the worker variable is set, the control plane keeps the default of the
# scs stack and the worker value is written as override to every machineDeployment.
#
# Not migrated (a warning is printed, the variable is removed):
#   workerSecurityGroups, workerSecurityGroupIDs -> use securityGroups / securityGroupIDs
#
# Variables with the same name in scs (e.g. diskPinAZ) are kept as they are.
#
# This script only converts the variables. Changing topology.class and the ClusterStack
# (scs2 -> scs) has to be done separately.
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

TEMP=$(mktemp)
trap 'rm -f "$TEMP"' EXIT
cp "$INPUT" "$TEMP"

# Helper: check if a variable exists
has_var() {
    local val
    val=$(yq -r ".spec.topology.variables[] | select(.name == \"$1\") | .name" "$TEMP" 2>/dev/null)
    [[ -n "$val" ]]
}

# Helper: get the value of a variable as JSON (keeps strings, numbers, lists and objects intact)
get_var_json() {
    yq -o=json -I=0 ".spec.topology.variables[] | select(.name == \"$1\") | .value" "$TEMP"
}

# Helper: delete a variable by name
del_var() {
    yq -i "del(.spec.topology.variables[] | select(.name == \"$1\"))" "$TEMP"
}

# Helper: set a variable (add or update) from a JSON value
set_var() {
    local name="$1" value="$2"
    if has_var "$name"; then
        yq -i "(.spec.topology.variables[] | select(.name == \"$name\")).value = $value" "$TEMP"
    else
        yq -i ".spec.topology.variables += [{\"name\": \"$name\", \"value\": $value}]" "$TEMP"
    fi
}

# Helper: add a variable override to every machineDeployment
add_worker_override() {
    local name="$1" value="$2"
    yq -i ".spec.topology.workers.machineDeployments[].variables.overrides |= (. // [])" "$TEMP"
    yq -i ".spec.topology.workers.machineDeployments[].variables.overrides += [{\"name\": \"$name\", \"value\": $value}]" "$TEMP"
}

CHANGES=0

# ============================================
# Rename simple variables
# ============================================

if has_var "apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs"; then
    val=$(get_var_json "apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs")
    del_var "apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs"
    set_var "apiServerAllowedCIDRs" "$val"
    echo "Renamed: apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs -> apiServerAllowedCIDRs" >&2
    CHANGES=$((CHANGES + 1))
fi

# additionalBlockDevices applies to control plane AND workers in scs, workerAdditionalBlockDevices
# only applied to workers. Therefore it is set as override on the machineDeployments.
if has_var "workerAdditionalBlockDevices"; then
    val=$(get_var_json "workerAdditionalBlockDevices")
    del_var "workerAdditionalBlockDevices"
    add_worker_override "additionalBlockDevices" "$val"
    echo "Moved: workerAdditionalBlockDevices -> additionalBlockDevices override on the machineDeployments" >&2
    CHANGES=$((CHANGES + 1))
fi

# ============================================
# Unify control plane / worker split variables
# ============================================

for pair in \
    "controlPlaneFlavor:workerFlavor:flavor" \
    "controlPlaneRootDisk:workerRootDisk:rootDisk" \
    "controlPlaneServerGroupID:workerServerGroupID:serverGroupID"; do

    cp_var="${pair%%:*}"
    rest="${pair#*:}"
    worker_var="${rest%%:*}"
    new_var="${rest#*:}"

    has_cp=false
    has_worker=false
    cp_val=""
    worker_val=""

    if has_var "$cp_var"; then
        cp_val=$(get_var_json "$cp_var")
        has_cp=true
    fi
    if has_var "$worker_var"; then
        worker_val=$(get_var_json "$worker_var")
        has_worker=true
    fi

    if ! $has_cp && ! $has_worker; then
        continue
    fi

    if $has_cp; then
        set_var "$new_var" "$cp_val"
        del_var "$cp_var"
    fi

    if $has_worker; then
        # Workers only need an override if they differ from what the control plane gets (cluster level value or default)
        if ! $has_cp || [[ "$cp_val" != "$worker_val" ]]; then
            add_worker_override "$new_var" "$worker_val"
        fi
        del_var "$worker_var"
    fi

    echo "Unified: $cp_var + $worker_var -> $new_var" >&2
    CHANGES=$((CHANGES + 1))
done

# ============================================
# Variables without a direct equivalent
# ============================================

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
    exit 0
fi

echo "Applied $CHANGES migration(s)" >&2

if $IN_PLACE; then
    cp "$TEMP" "$INPUT"
    echo "Updated: $INPUT" >&2
else
    cat "$TEMP"
fi
