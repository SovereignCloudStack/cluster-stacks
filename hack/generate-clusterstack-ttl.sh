#!/bin/bash
# Copyright 2024 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

# Generate ClusterStack Kubernetes resources for ttl.sh daily repository
#
# Usage: ./hack/generate-clusterstack-ttl.sh [NAMESPACE] [PROVIDER] [STACK] [K8S_VERSION]
#
# Environment variables:
#   OCI_DATE    - Override date (format: YYYYMMDD), defaults to today
#
# Examples:
#   # Generate for default settings
#   ./hack/generate-clusterstack-ttl.sh > clusterstack.yaml
#
#   # Generate for custom settings
#   ./hack/generate-clusterstack-ttl.sh my-namespace openstack scs2 1.34
#
#   # Generate for specific date
#   OCI_DATE=20260125 ./hack/generate-clusterstack-ttl.sh
#
#   # Generate and apply directly
#   ./hack/generate-clusterstack-ttl.sh | kubectl apply -f -

NAMESPACE="${1:-cluster}"
PROVIDER="${2:-openstack}"
STACK="${3:-scs2}"
K8S_VERSION="${4:-1.34}"

DATE_YYYYMMDD="${OCI_DATE:-$(date +%Y%m%d)}"
REPO="ttl.sh/clusterstacks-${DATE_YYYYMMDD}"

# Check if oras is available
if ! command -v oras >/dev/null 2>&1; then
    echo "# ❌ Error: oras not installed" >&2
    echo "# Install: https://oras.land/docs/installation" >&2
    exit 1
fi

echo "# ClusterStack resources for ttl.sh daily repository"
echo "# Generated: $(date)"
echo "# Repository: $REPO"
echo "# Provider: $PROVIDER, Stack: $STACK, Kubernetes: $K8S_VERSION"
echo ""

# Convert K8S_VERSION dots to dashes for tag matching (1.34 → 1-34)
K8S_VERSION_DASHED="${K8S_VERSION//./-}"

# Get list of versions for this provider/stack/k8s
VERSIONS=$(oras repo tags "$REPO" 2>/dev/null | grep "${PROVIDER}-${STACK}-${K8S_VERSION_DASHED}" || true)

if [[ -z "$VERSIONS" ]]; then
    echo "# ❌ No versions found for ${PROVIDER}/${STACK}/${K8S_VERSION}" >&2
    echo "# " >&2
    echo "# Repository: $REPO" >&2
    echo "# Pattern: ${PROVIDER}-${STACK}-${K8S_VERSION_DASHED}-*" >&2
    echo "# " >&2
    echo "# To create versions, run:" >&2
    echo "#   task build-version -- ${K8S_VERSION}" >&2
    echo "#   ./hack/build-stack.sh providers/${PROVIDER}/out/${K8S_VERSION_DASHED} --publish" >&2
    exit 1
fi

# Generate one ClusterStack per version
COUNTER=1
for TAG in $VERSIONS; do
    # Extract version from tag: openstack-scs2-1-34-v0-ttl-1768809871 → v0-ttl.1768809871
    # Replace last dash with dot to get proper version format
    VERSION=$(echo "$TAG" | grep -oP 'v0-ttl-\K[0-9]+')
    if [[ -n "$VERSION" ]]; then
        VERSION="v0-ttl.${VERSION}"
    else
        echo "# ⚠️  Warning: Could not extract version from tag: $TAG" >&2
        continue
    fi
    
    cat <<EOF
---
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: ${PROVIDER}-${STACK}-ttl-${COUNTER}
  namespace: ${NAMESPACE}
  labels:
    cluster-stacks.io/source: ttl.sh
    cluster-stacks.io/date: "${DATE_YYYYMMDD}"
  annotations:
    cluster-stacks.io/oci-repository: "${REPO}"
    cluster-stacks.io/expires: "24h from first push $(date +%Y-%m-%d)"
spec:
  provider: ${PROVIDER}
  name: ${STACK}
  kubernetesVersion: "${K8S_VERSION}"
  channel: custom
  autoSubscribe: false
  noProvider: true
  versions:
    - ${VERSION}

EOF
    COUNTER=$((COUNTER + 1))
done

echo "# Total versions: $((COUNTER - 1))"
echo "#"
echo "# Apply with:"
echo "#   kubectl apply -f <this-file>"
echo "#"
echo "# Or pipe directly:"
echo "#   $0 $* | kubectl apply -f -"
