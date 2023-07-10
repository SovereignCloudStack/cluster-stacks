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

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec
.DEFAULT_GOAL:=help

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

#############
# Variables #
#############

TIMEOUT := $(shell command -v timeout || command -v gtimeout)

# Directories
BIN_DIR := bin
TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(TOOLS_DIR)/$(BIN_DIR)
export PATH := $(abspath $(TOOLS_BIN_DIR)):$(PATH)
export GOBIN := $(abspath $(TOOLS_BIN_DIR))

ARTIFACTS_PATH := $(ROOT_DIR)/_artifacts
# Docker
RM := --rm
TTY := -t

##@ Binaries
############
# Binaries #
############

KUSTOMIZE := $(abspath $(TOOLS_BIN_DIR)/kustomize)
kustomize: $(KUSTOMIZE) ## Build a local copy of kustomize
$(KUSTOMIZE): # Build kustomize from tools folder.
	go install sigs.k8s.io/kustomize/kustomize/v5@v5.1.0

ENVSUBST := $(abspath $(TOOLS_BIN_DIR)/envsubst)
envsubst: $(ENVSUBST) ## Build a local copy of envsubst
$(ENVSUBST): $(TOOLS_DIR)/go.mod # Build envsubst from tools folder.
	go install github.com/drone/envsubst/v2/cmd/envsubst@latest

CTLPTL := $(abspath $(TOOLS_BIN_DIR)/ctlptl)
ctlptl: $(CTLPTL) ## Build a local copy of ctlptl
$(CTLPTL):
	go install github.com/tilt-dev/ctlptl/cmd/ctlptl@v0.8.20

CLUSTERCTL := $(abspath $(TOOLS_BIN_DIR)/clusterctl)
clusterctl: $(CLUSTERCTL) ## Build a local copy of clusterctl
$(CLUSTERCTL): $(TOOLS_DIR)/go.mod
	curl -sSLf https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.4.3/clusterctl-linux-amd64 -o $(CLUSTERCTL)
	chmod a+rx $(CLUSTERCTL)

HELM := $(abspath $(TOOLS_BIN_DIR)/helm)
helm: $(HELM) ## Build a local copy of helm
$(HELM): $(TOOLS_DIR)/go.mod
	go install helm.sh/helm/v3/cmd/helm@v3.12.1

KIND := $(abspath $(TOOLS_BIN_DIR)/kind)
kind: $(KIND) ## Build a local copy of kind
$(KIND): $(TOOLS_DIR)/go.mod
	go install sigs.k8s.io/kind@v0.20.0

all-tools: $(KIND) $(CTLPTL) $(ENVSUBST) $(KUSTOMIZE) $(CLUSTERCTL) $(HELM)
	echo 'done'

.PHONY: basics
basics: $(KIND) $(CTLPTL) $(KIND) $(ENVSUBST) $(KUSTOMIZE)
	@test $${CAPI_VERSION?Please set environment variable}
	@test $${CAPD_VERSION?Please set environment variable}
	@test $${NAMESPACE?Please set environment variable}
	@test $${CLUSTER_CLASS_NAME?Please set environment variable}
	@test $${K8S_VERSION?Please set environment variable}
	@test $${FLAVOR?Please set environment variable}
	@test $${CLUSTER_NAME?Please set environment variable}
	@test $${PROVIDER?Please set environment variable}

##@ Development
###############
# Development #
###############

.PHONY: cluster
cluster: basics $(CLUSTERCTL) ## Creates kind-dev Cluster
	./hack/kind-dev.sh

.PHONY: watch
watch: ## Show the current state of the CRDs and events.
	watch -c "kubectl -n $(NAMESPACE) get cluster; echo; kubectl -n $(NAMESPACE) get machine; echo; kubectl -n $(NAMESPACE) get dockermachine; echo; echo Events; kubectl -A get events --sort-by=metadata.creationTimestamp | tail -5"

##@ Clean
#########
# Clean #
#########
.PHONY: clean
clean: basics ## Remove all generated files
	$(MAKE) clean-bin

.PHONY: clean-bin
clean-bin: ## Remove all generated helper binaries
	rm -rf $(TOOLS_BIN_DIR)

.PHONY: clean-release
clean-release: ## Remove the release folder
	rm -rf $(RELEASE_DIR)

.PHONY: clean-release-git
clean-release-git: ## Restores the git files usually modified during a release
	git restore ./*manager_config_patch.yaml ./*manager_pull_policy.yaml

##@ Releasing
#############
# Releasing #
#############
## latest git tag for the commit, e.g., v0.3.10
RELEASE_TAG ?= $(shell git describe --abbrev=0 2>/dev/null)
# the previous release tag, e.g., v0.3.9, excluding pre-release tags
PREVIOUS_TAG ?= $(shell git tag -l | grep -E "^v[0-9]+\.[0-9]+\.[0-9]." | sort -V | grep -B1 $(RELEASE_TAG) | head -n 1 2>/dev/null)
RELEASE_DIR ?= out
RELEASE_NOTES_DIR := _releasenotes

$(RELEASE_DIR):
	mkdir -p $(RELEASE_DIR)/

$(RELEASE_NOTES_DIR):
	mkdir -p $(RELEASE_NOTES_DIR)/


.PHONY: test-release
test-release: basics
	$(MAKE) set-manifest-image MANIFEST_IMG=$(IMAGE_PREFIX)/capd-staging MANIFEST_TAG=$(TAG)
	$(MAKE) set-manifest-pull-policy PULL_POLICY=IfNotPresent
	$(MAKE) release-manifests

.PHONY: release-manifests
release-manifests: basics generate-manifests generate-go-deepcopy $(RELEASE_DIR) cluster-templates ## Builds the manifests to publish with a release
	$(KUSTOMIZE) build config/default > $(RELEASE_DIR)/infrastructure-components.yaml
	## Build capd-components (aggregate of all of the above).
	cp metadata.yaml $(RELEASE_DIR)/metadata.yaml
	cp templates/cluster-templates/cluster-template* $(RELEASE_DIR)/
	cp templates/cluster-templates/cluster-class* $(RELEASE_DIR)/

.PHONY: release-notes
release-notes: basics $(RELEASE_NOTES_DIR) $(RELEASE_NOTES)
	go run ./hack/tools/release/notes.go --from=$(PREVIOUS_TAG) > $(RELEASE_NOTES_DIR)/$(RELEASE_TAG).md

##@ Testing
###########
# Testing #
###########
ARTIFACTS ?= _artifacts
$(ARTIFACTS):
	mkdir -p $(ARTIFACTS)/

##@ cluster-class
#################
# cluster-class #
#################

.PHONY: re-apply-cluster-class-docker
re-apply-cluster-class-docker: basics ## Re-apply only a cluster-class.
	$(HELM) -n $(NAMESPACE) template docker-$(CLUSTER_CLASS_NAME)-$(K8S_VERSION) providers/docker/$(CLUSTER_CLASS_NAME)/$(K8S_VERSION)/cluster-class | kubectl -n $(NAMESPACE) apply -f -

.PHONY: delete-cluster-class-docker
delete-cluster-class-docker: basics ## Delete a cluster-class.
	$(HELM) -n $(NAMESPACE) template docker-$(CLUSTER_CLASS_NAME)-$(K8S_VERSION) providers/docker/$(CLUSTER_CLASS_NAME)/$(K8S_VERSION)/cluster-class | kubectl -n $(NAMESPACE) delete -f -

##@ cluster-addon
#################
# cluster-addon #
#################

## working on cluster-addon
.PHONY: generate-deps-cluster-addon-docker
generate-deps-cluster-addon-docker: basics ## Build a cluster-class.
	cd providers/docker/$(CLUSTER_CLASS_NAME)/$(K8S_VERSION)/cluster-addon && rm -rf ./charts/* && helm dependency update

.PHONY: package-cluster-addon-docker
package-cluster-addon-docker: basics ## Build a cluster-class.
	@mkdir -p .helm
	$(HELM) package providers/docker/$(CLUSTER_CLASS_NAME)/$(K8S_VERSION)/cluster-addon -d .helm

##@ Main Targets
################
# Main Targets #
################
.PHONY: delete-bootstrap-cluster
delete-bootstrap-cluster: basics ## Deletes Kind-dev Cluster
	$(CTLPTL) delete cluster kind-cluster-stacks
	$(CTLPTL) delete registry cluster-stacks-registry

.PHONY: create-bootstrap-cluster
create-bootstrap-cluster: basics cluster ## Create mgt-cluster and install capi-stack.
	EXP_RUNTIME_SDK=true CLUSTER_TOPOLOGY=true DISABLE_VERSIONCHECK="true" $(CLUSTERCTL) init --core cluster-api:$(CAPI_VERSION) --bootstrap kubeadm:$(CAPI_VERSION) --control-plane kubeadm:$(CAPI_VERSION)
	kubectl wait -n cert-manager deployment cert-manager --for=condition=Available --timeout=300s
	kubectl wait -n capi-kubeadm-bootstrap-system deployment capi-kubeadm-bootstrap-controller-manager --for=condition=Available --timeout=300s
	kubectl wait -n capi-kubeadm-control-plane-system deployment capi-kubeadm-control-plane-controller-manager --for=condition=Available --timeout=300s
	kubectl wait -n capi-system deployment capi-controller-manager --for=condition=Available --timeout=300s

.PHONY: install-provider-docker
install-provider-docker: basics create-bootstrap-cluster  ## Install Docker Infrastructure provider.
	DISABLE_VERSIONCHECK="true" $(CLUSTERCTL) init --infrastructure docker:$(CAPD_VERSION)
	kubectl wait -n capd-system deployment capd-controller-manager --for=condition=Available --timeout=300s

.PHONY: prepare-provider-docker
prepare-provider-docker: basics ## Prepares the Docker Environment.
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

.PHONY: apply-cluster-class-docker
apply-cluster-class-docker: basics prepare-provider-docker package-cluster-addon-docker ## Applies all resources and node-images.
	$(HELM) -n $(NAMESPACE) template docker-$(CLUSTER_CLASS_NAME)-$(K8S_VERSION) providers/docker/$(CLUSTER_CLASS_NAME)/$(K8S_VERSION)/cluster-class | kubectl -n $(NAMESPACE) apply -f -
	# create the docker image
	docker build -t docker-ferrol-1-26-controlplane-amd64-v2:dev --file providers/docker/$(CLUSTER_CLASS_NAME)/$(K8S_VERSION)/node-images/Dockerfile.controlplane \
	providers/docker/$(CLUSTER_CLASS_NAME)/$(K8S_VERSION)/node-images/ \
	& docker build -t docker-ferrol-1-26-worker-amd64-v2:dev --file providers/docker/$(CLUSTER_CLASS_NAME)/$(K8S_VERSION)/node-images/Dockerfile.worker \
	providers/docker/$(CLUSTER_CLASS_NAME)/$(K8S_VERSION)/node-images/
	@echo ""
	@echo "Done"

.PHONY: create-workload-cluster
create-workload-cluster: basics  ## Creates a workload cluster.
	cat providers/docker/$(CLUSTER_CLASS_NAME)/$(K8S_VERSION)/topology-$(FLAVOR).yaml | $(ENVSUBST) - | kubectl apply -f -
	# Wait for the kubeconfig to become available.
	${TIMEOUT} 5m bash -c "while ! kubectl -n $(NAMESPACE) get secrets | grep $(CLUSTER_NAME)-kubeconfig; do sleep 1; done"
	# Get kubeconfig and store it locally.
	@mkdir -p .kubeconfigs
	kubectl -n $(NAMESPACE) get secrets $(CLUSTER_NAME)-kubeconfig -o json | jq -r .data.value | base64 --decode > .kubeconfigs/.$(CLUSTER_NAME)-kubeconfig
	if [ ! -s ".kubeconfigs/.$(CLUSTER_NAME)-kubeconfig" ]; then echo "failed to create .kubeconfigs/.$(CLUSTER_NAME)-kubeconfig"; exit 1; fi
	${TIMEOUT} 15m bash -c "while ! kubectl --kubeconfig=.kubeconfigs/.$(CLUSTER_NAME)-kubeconfig -n $(NAMESPACE) get nodes | grep control-plane; do sleep 1; done"
	@echo ""
	@echo 'Access to API server successful.'

.PHONY: release-docker
release-docker: release-basics  ## Builds and push container images using the latest git tag for the commit.
	# @if [ -z "${RELEASE_TAG}" ]; then echo "RELEASE_TAG is not set"; exit 1; fi
	# @if ! [ -z "$$(git status --porcelain)" ]; then echo "Your local git repository contains uncommitted changes, use git clean before proceeding."; exit 1; fi
	# git checkout "${RELEASE_TAG}"
	@mkdir -p .release
	cp providers/docker/$(RELEASE_CLUSTER_CLASS)/$(RELEASE_KUBERNETES_VERSION)/topology-* .release/
	$(HELM) package providers/docker/$(RELEASE_CLUSTER_CLASS)/$(RELEASE_KUBERNETES_VERSION)/cluster-addon -d .release/
	$(HELM) package providers/docker/$(RELEASE_CLUSTER_CLASS)/$(RELEASE_KUBERNETES_VERSION)/cluster-class -d .release/
	cd .release && tar -zcvf docker-$(RELEASE_CLUSTER_CLASS)-$(RELEASE_KUBERNETES_VERSION)-node-image-$(shell jq .variables.version providers/docker/$(RELEASE_CLUSTER_CLASS)/$(RELEASE_KUBERNETES_VERSION)/node-image/controlPlane-docker-amd64.json).tar.gz -C ../providers/docker/$(RELEASE_CLUSTER_CLASS)/$(RELEASE_KUBERNETES_VERSION)/node-image .
