# Build System

The Cluster Stacks are built, published and maintained with bash scripts in `hack/`, wrapped by a
[`justfile`](https://github.com/casey/just). Run `just` to list all recipes.
The `csctl` binary is **not** required anymore. The `csctl.yaml` files are still used as the per-version configuration
(provider, cluster stack name, Kubernetes version, addon constraints), but they are read by the scripts directly.

## Layout

```
providers/<provider>/<stack>/
  image-manager.yaml        # node images (OpenStack only), maintained by hack/update.sh
  1-35/                     # one self-contained directory per Kubernetes minor version
    csctl.yaml              # provider, stack name, Kubernetes version
    clusteraddon.yaml       # addon stages and hooks
    cluster-class/          # Helm chart rendering the ClusterClass
    cluster-addon/          # one sub directory (Helm chart) per addon
```

A stack directory containing a file called `DEPRECATED` (currently `openstack/scs2`) is only maintained
(patch releases, addon updates) and does not get new Kubernetes minor versions.

## Prerequisites

- `bash`, `helm`, `yq` ([mikefarah](https://github.com/mikefarah/yq)), `git`, `curl`, `tar`, `jq`
- `oras` for publishing to an OCI registry
- `just` as task runner (the scripts in `hack/` also work without it)
- `python3` with `PyYAML` for `just generate-docs`
- `nix develop` (see `flake.nix`) or the `Containerfile` provide all of them

## Configuration

Copy `.envrc.example` to `.envrc` (or export the variables, or put them into a `.env` file which `just` reads automatically):

| Variable | Description |
|---|---|
| `PROVIDER`, `CLUSTER_STACK` | Stack to work on, default `openstack` / `scs` |
| `OCI_REGISTRY`, `OCI_REPOSITORY` | Target registry. If unset, the temporary registry `ttl.sh` is used (24h TTL) |
| `OCI_USERNAME`, `OCI_PASSWORD` or `OCI_ACCESS_TOKEN` | Credentials for the registry |
| `GITHUB_TOKEN` | Optional, higher GitHub API rate limit when resolving Kubernetes versions |
| `OUTPUT_DIR` | Output directory for built releases, default `.release` |
| `CSO_CHART` | Chart for `just install-cso`, default the published chart. A local path works as well, e.g. `../cluster-stack-operator/charts` |
| `CSO_IMAGE_REPOSITORY`, `CSO_IMAGE_TAG` | Override the operator image for `just install-cso`, e.g. to test a locally built operator |

## Commands

| Command | Description |
|---|---|
| `just build 1.35` | Build the release of one Kubernetes minor version |
| `just build --all` | Build all minor versions of the stack |
| `just publish 1.35` | Build and push to the OCI registry |
| `just dev 1.35` | Build, push and print the matching `ClusterStack` resource (add `--install-cso` to install the operator as well) |
| `just install-cso` | Install or upgrade the Cluster Stack Operator with the matching OCI configuration (does not build anything) |
| `just clean` | Remove `.release` |
| `just update versions` | Update Kubernetes patch versions and `image-manager.yaml` |
| `just update addons` | Update the Helm chart dependencies of the addons |
| `just update --all --dry-run` | Preview updates for all stacks |
| `just add-version 1.37` | Scaffold a new Kubernetes minor version for all stacks that are not deprecated |
| `just matrix` | Show the version matrix |
| `just generate-resources 1.35` | Generate `ClusterStack` and `Cluster` manifests for testing |
| `just generate-image-manifests 1.35` | Generate ORC `Image` manifests (or `--format image-manager`) |
| `just generate-image-manifests 1.35 --format image-manager` | Same in the format of the OpenStack image manager |
| `just generate-docs` | Update the generated sections of the configuration docs, see below |
| `just migrate-cluster cluster.yaml` | Convert the variables of a `scs2` Cluster manifest to `scs` |
| `just container-build`, `just container-run <recipe> ...` | Build the tools container and run a recipe inside it |

A bare Kubernetes minor version as first argument is shorthand for `--version`: `just build 1.35` is the same as
`just build --version 1.35`. All other arguments are passed to the script unchanged.

Select another stack with `PROVIDER=... CLUSTER_STACK=...`, either as environment variables or as `just` variables:
`CLUSTER_STACK=scs2 just matrix` or `just CLUSTER_STACK=scs2 matrix`.

## Generated documentation

`just generate-docs` renders the ClusterClass of the newest minor version of every stack and updates
`docs/providers/<provider>/<stack>-configuration.md`. Only the parts between the markers

```
<!-- BEGIN GENERATED: matrix -->     ...  <!-- END GENERATED: matrix -->
<!-- BEGIN GENERATED: variables -->  ...  <!-- END GENERATED: variables -->
```

are replaced, everything else is hand written. Documents without markers are skipped. The descriptions in the
variables table come from the ClusterClass, so improve them there.

## Releases

A release consists of the packaged `cluster-class` chart, the `cluster-addon` bundle, `clusteraddon.yaml`,
`csctl.yaml`, `metadata.yaml` and `hashes.json`. It is published as one OCI artifact with the tag

```
<provider>-<stack>-<k8s major>-<k8s minor>-<version>      e.g. openstack-scs-1-35-v3
```

- Stable versions are `v1`, `v2`, ...: `hack/build.sh` queries the registry and uses the next free number.
- Development builds (no registry configured, or `ttl.sh`) get the version `v0-ttl.<timestamp>` inside the charts and
  `metadata.yaml`, but the **directory and OCI tag use the dash notation** `v0-ttl-<timestamp>`. The operator derives
  the tag it downloads from the name of the `ClusterStackRelease`, which does not contain dots.

## Updating

```bash
just update --all --dry-run      # what would change?
just update versions --all       # Kubernetes patch versions + image-manager.yaml
just update addons --all         # addon Helm chart versions
```

Minor versions with a `FROZEN` file (`openstack/scs` `1-32`) are skipped by `update`.

`image-manager.yaml` is merged: new versions are added and existing ones updated, but images of minor versions that
have been removed from the repository are kept, because running clusters may still use them. Check that the node image
(and its checksum) has been published before releasing a new patch version.

## Gateway API CRDs

The `scs` stacks enable the Gateway API of Cilium. Cilium does not install the Gateway API CRDs, therefore every stack
with `gatewayAPI.enabled` has a `gateway-api` cluster addon that carries them. It is applied before `cni`, so that the
Cilium operator finds the CRDs when it starts, and `gatewayAPI.gatewayClass.create` is set to `"true"` (the default
`auto` only creates the `GatewayClass` if the CRD is visible while rendering the chart, which it never is for the
operator).

The CRDs are vendored, the version has to match the Cilium version of the `cni` addon (Cilium 1.19: Gateway API v1.4.1,
Cilium 1.20: Gateway API v1.6.3):

```bash
./hack/update-gateway-api-crds.sh v1.4.1 providers/openstack/scs/1-35 providers/docker/scs/1-35
./hack/update-gateway-api-crds.sh v1.6.3 providers/openstack/scs/1-36
```

The standard channel is installed plus `TLSRoute`, which the hosted control plane provider needs (experimental channel
before Gateway API v1.5, standard channel since then). Clusters that are upgraded to a release that contains the addon
need a restart of the `cilium-operator` once (`kubectl -n kube-system rollout restart deploy/cilium-operator`), the
operator only looks for the CRDs when it starts.

## Migrating clusters from scs2 to scs

`scs` uses unified variables (`flavor`, `rootDisk`, `serverGroupID`, `additionalBlockDevices`, ...) instead of the separate
`controlPlane*` / `worker*` variables of `scs2`. `hack/migrate-cluster.sh` converts the `topology.variables` of a `Cluster`
manifest, see the header of the script for the exact rules and the variables that can not be migrated.

```bash
./hack/migrate-cluster.sh cluster.yaml > cluster-scs.yaml
```

It does not change `topology.class`. Note that the Cluster Stack Operator's webhook does not allow changing the
ClusterStack of an existing cluster.
