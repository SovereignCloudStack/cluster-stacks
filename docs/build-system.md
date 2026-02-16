# Build System

The cluster stacks build system uses bash scripts in `hack/` orchestrated by [just](https://github.com/casey/just).

## Prerequisites

**Required tools:**
- `bash`, `helm`, `yq` (mikefarah), `git`, `curl`, `tar`, `jq`

**Optional:**
- `oras` — for OCI registry publishing
- `python3` + `PyYAML` — for `docugen.py` only
- `just` — task runner (scripts also work standalone)

**Nix dev shell (recommended):**
```bash
# Enter the development environment with all tools
nix develop
```

**Container alternative:**
```bash
# Build the tools container
just container-build

# Run any command inside
just container-run build-all
```

## Configuration

Copy `task.env.example` to `.env` and set your provider/stack:

```bash
PROVIDER=openstack        # or: docker
CLUSTER_STACK=scs2         # or: scs
OCI_REGISTRY=ghcr.io       # for publishing
OCI_REPOSITORY=myorg/cluster-stacks
```

The `justfile` uses `set dotenv-load` to automatically read `.env`.

## Commands

### Building

| Command | Description |
|---------|-------------|
| `just build 1.34` | Build for one K8s version |
| `just build-all` | Build for all versions in versions.yaml |
| `just publish 1.34` | Build + publish to OCI registry |
| `just publish-all` | Build + publish all versions |
| `just clean` | Clean `.release/` and output directories |

The build system:
1. Copies the cluster-class chart, patches `Chart.yaml` with the correct version
2. For each addon in `cluster-addon/`, resolves the version from `versions.yaml` and patches the addon's `Chart.yaml`
3. Runs `helm package` for each chart
4. Bundles everything into a release artifact
5. Optionally publishes to an OCI registry via `oras push`

### Version Management

| Command | Description |
|---------|-------------|
| `just update-versions --check` | Check for K8s patch updates, new minors, and addon bumps |
| `just update-versions --apply` | Apply all updates to `versions.yaml` |
| `just update-versions-all --check` | Check for updates across all stacks |

`update-versions` fetches the latest Kubernetes releases from GitHub tags and queries
Helm repo indexes for K8s-tied addon versions (e.g., CCM, CSI). It automatically:
- Bumps patch versions for existing K8s minors
- Adds new K8s minor versions (with correct Ubuntu image mapping)
- Removes EOL minor versions (keeps the 4 most recent)

Set `GITHUB_TOKEN` for higher API rate limits in CI (optional, 60 req/h without).

### Addon Management

| Command | Description |
|---------|-------------|
| `just update-addons` | Interactive: check upstream Helm repos for new versions |
| `just update-addons --yes` | Auto-approve all updates |
| `just update-addons-all` | Update addons for all providers/stacks |

`update-addons` reads the Helm repository URLs from each addon's `Chart.yaml`, queries for new versions, and updates both `Chart.yaml` and `versions.yaml` (for K8s-version-tied addons).

### Utilities

| Command | Description |
|---------|-------------|
| `just matrix` | Show version matrix (K8s versions, addon versions, CS versions) |
| `just generate-resources 1.34` | Generate ClusterStack + Cluster YAML for testing |
| `just generate-image-manifests` | Generate OpenStack Image CRD manifests |
| `just generate-docs` | Generate configuration docs from ClusterClass variables |

### Provider Shortcuts

Override the default provider/stack for any command:

```bash
PROVIDER=docker CLUSTER_STACK=scs2 just build-all
```

## Scripts Reference

All scripts in `hack/` take the stack directory as the first argument:

```bash
# Direct invocation (without just)
./hack/build.sh providers/openstack/scs2 --version 1.34
./hack/build.sh providers/openstack/scs2 --version 1.34 --publish
./hack/build.sh providers/openstack/scs2 --all
./hack/update-versions.sh providers/openstack/scs2 --check
./hack/update-versions.sh providers/openstack/scs2 --apply
./hack/update-addons.sh providers/openstack/scs2
./hack/update-addons.sh providers/openstack/scs2 --yes
./hack/show-matrix.sh providers/openstack/scs2
./hack/generate-resources.sh providers/openstack/scs2 --version 1.34
./hack/generate-image-manifests.sh providers/openstack/scs2
```

## Linting

```bash
yamllint .
```

Configuration: `.yamllint.yml` — line-length disabled, Helm templates excluded. This is enforced in CI.

## Helm Template Validation

You can validate rendered templates locally:

```bash
# Render the chart
helm template test providers/openstack/scs2/cluster-class/

# Validate against CRD schemas (requires kubeconform)
helm template test providers/openstack/scs2/cluster-class/ | kubeconform -summary -strict \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
```
