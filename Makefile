# Cluster Stacks build system
# Usage: make <target> [ARGS="..."] [PROVIDER=...] [CLUSTER_STACK=...]
#
# Examples:
#   make build ARGS="--version 1.34"
#   make build ARGS="--all"
#   make publish ARGS="--version 1.34"
#   make dev ARGS="--version 1.35"
#   make matrix
#   make update ARGS="versions"
#
# All hack/ scripts derive the stack base directory from $PROVIDER and $CLUSTER_STACK
# automatically (e.g., providers/openstack/scs). Each base directory contains
# per-minor-version subdirs (1-32, 1-33, etc.) with self-contained csctl.yaml.

PROVIDER ?= openstack
CLUSTER_STACK ?= scs
VERSION ?=
export PROVIDER
export CLUSTER_STACK

.PHONY: default help build publish dev install-cso clean update \
        generate-resources generate-clusterstack generate-cluster \
        generate-image-manifests matrix generate-docs add-version

default: help

help:
	@echo "Usage: make <target> [ARGS=\"...\"] [PROVIDER=...] [CLUSTER_STACK=...]"
	@echo ""
	@echo "Targets:"
	@echo "  build [ARGS]                  Build cluster-stack (e.g., ARGS=\"--version 1.34\")"
	@echo "  publish [ARGS]                Build and publish to OCI"
	@echo "  dev [ARGS]                    Build, publish, and print ClusterStack resource"
	@echo "  install-cso                   Install/upgrade the Cluster Stack Operator"
	@echo "  clean                         Remove build artifacts"
	@echo "  update [ARGS]                 Update K8s versions and/or addons"
	@echo "  generate-resources [ARGS]     Generate ClusterStack + Cluster YAML"
	@echo "  generate-clusterstack [ARGS]  Generate only the ClusterStack resource"
	@echo "  generate-cluster [ARGS]       Generate only the Cluster resource"
	@echo "  generate-image-manifests [ARGS] Generate OpenStack image manifests"
	@echo "  add-version VERSION=1.36       Scaffold a new K8s minor version for all stacks"
	@echo "  matrix                        Show version matrix for all K8s versions"
	@echo "  generate-docs                 Regenerate configuration documentation"

build:
	./hack/build.sh $(ARGS)

publish:
	./hack/build.sh --publish $(ARGS)

dev:
	@set -euo pipefail; \
	./hack/build.sh --publish $(ARGS); \
	version=""; \
	prev=""; \
	for arg in $(ARGS); do \
		if [ "$$prev" = "--version" ]; then version="$$arg"; fi; \
		prev="$$arg"; \
	done; \
	if [ -n "$$version" ]; then \
		echo "" >&2; \
		echo "================================================================" >&2; \
		echo "ClusterStack resource (pipe to kubectl apply -f -)" >&2; \
		echo "================================================================" >&2; \
		./hack/generate-resources.sh --version "$$version" --clusterstack-only; \
	fi

install-cso:
	./hack/build.sh --install-cso

add-version:
	@set -euo pipefail; \
	if [ -z "$(VERSION)" ]; then \
		echo "Usage: make add-version VERSION=1.36" >&2; \
		exit 1; \
	fi; \
	new_short="$(VERSION)"; \
	new_dash="$${new_short//./-}"; \
	new_minor="$$(echo "$$new_short" | cut -d. -f2)"; \
	found=0; \
	for stack_base in providers/*/*/; do \
		[ -d "$$stack_base" ] || continue; \
		latest=$$(ls -d "$$stack_base"/1-*/ 2>/dev/null | sort -t- -k2 -n | tail -1); \
		[ -n "$$latest" ] || continue; \
		src="$${latest%/}"; \
		dst="$$stack_base$$new_dash"; \
		if [ -d "$$dst" ]; then \
			echo "  SKIP $$dst (already exists)" >&2; \
			continue; \
		fi; \
		found=1; \
		old_minor="$$(echo "$$src" | grep -oP '1-\K\d+')"; \
		old_dash="1-$$old_minor"; \
		echo "---" >&2; \
		echo "Creating $$dst ..." >&2; \
		cp -r "$$src" "$$dst"; \
		csctl="$$dst/csctl.yaml"; \
		if [ -f "$$csctl" ]; then \
			yq -i ".config.kubernetesVersion = \"v$$new_short\"" "$$csctl"; \
			if yq -e '.addons.ccm' "$$csctl" >/dev/null 2>&1; then \
				sed -i "s/\.$$old_minor\.x/\.$$new_minor\.x/g" "$$csctl"; \
			fi; \
			if yq -e '.addons.csi' "$$csctl" >/dev/null 2>&1; then \
				sed -i "s/\.$$old_minor\.x/\.$$new_minor\.x/g" "$$csctl"; \
			fi; \
		fi; \
		chart="$$dst/cluster-class/Chart.yaml"; \
		if [ -f "$$chart" ]; then \
			sed -i "s/$$old_dash/$$new_dash/g" "$$chart"; \
		fi; \
		values="$$dst/cluster-class/values.yaml"; \
		if [ -f "$$values" ] && yq -e '.images' "$$values" >/dev/null 2>&1; then \
			sed -i "s|:v1\.$$old_minor\.|:v1.$$new_minor.|g" "$$values"; \
		fi; \
		for addon_chart in "$$dst"/cluster-addon/*/Chart.yaml; do \
			[ -f "$$addon_chart" ] || continue; \
			case "$$(basename "$$(dirname "$$addon_chart")")" in \
				ccm|csi) \
					sed -i "s/\.$$old_minor\./\.$$new_minor./g" "$$addon_chart"; \
					;; \
			esac; \
		done; \
		echo "  Done: $$dst" >&2; \
	done; \
	if [ "$$found" -eq 0 ]; then \
		echo "No stacks found to scaffold." >&2; \
		exit 1; \
	fi; \
	echo "" >&2; \
	echo "=== Resolving latest patches ===" >&2; \
	./hack/update.sh versions --all; \
	echo "" >&2; \
	echo "New version $(VERSION) scaffolded for all stacks." >&2

clean:
	rm -rf .release
	@echo "Cleaned .release"

update:
	./hack/update.sh $(ARGS)

generate-resources:
	./hack/generate-resources.sh $(ARGS)

generate-clusterstack:
	./hack/generate-resources.sh --clusterstack-only $(ARGS)

generate-cluster:
	./hack/generate-resources.sh --cluster-only $(ARGS)

generate-image-manifests:
	./hack/generate-image-manifests.sh $(ARGS)

matrix:
	./hack/show-matrix.sh $(ARGS)

generate-docs:
	@set -euo pipefail; \
	template="hack/config-template.md"; \
	for stack_base in providers/*/*; do \
		[ -d "$$stack_base" ] || continue; \
		provider=$$(basename "$$(dirname "$$stack_base")"); \
		stack=$$(basename "$$stack_base"); \
		latest=$$(ls -d "$$stack_base"/1-*/ 2>/dev/null | sort -V | tail -1); \
		[ -n "$$latest" ] || continue; \
		outdir="docs/providers/$${provider}"; \
		outfile="$${outdir}/$${stack}-configuration.md"; \
		mkdir -p "$$outdir"; \
		echo "Generating $${outfile} from $${latest} ..."; \
		python3 ./hack/docugen.py "$$latest" --template "$$template" --matrix --output "$$outfile"; \
	done; \
	echo "Done."
