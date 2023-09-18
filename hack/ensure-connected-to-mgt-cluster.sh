#!/bin/bash
# Copyright 2023 The Kubernetes Authors.
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

set -euo pipefail

context="$(kubectl config current-context 2>/dev/null || true)"

if [ "$context" = "kind-scs-cluster-stacks" ]; then
  exit 0
fi

if [ "$context" = "" ]; then
  echo "No context set"
  exit 1
fi


echo "You are connected to $context. Please set KUBECONFIG to .mgt-cluster-kubeconfig.yaml"
exit 1

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 VAR1 VAR2 ..."
  exit 1
fi

missing_vars=()
for varname in "$@"; do
  eval varvalue="\$$varname"
  if [ -z "$varvalue" ]; then
    missing_vars+=("$varname")
  fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
  echo "Missing or empty environment variables: ${missing_vars[*]}"
  exit 1
fi
