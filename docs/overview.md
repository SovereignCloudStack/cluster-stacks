# Overview

## What is a Cluster Stack?

A cluster stack is a versioned bundle of everything needed to create and operate
a Kubernetes cluster via the Cluster API (CAPI). It packages three layers:

1. **Cluster Class** -- a CAPI `ClusterClass` resource that defines the
   infrastructure templates, machine configurations, and topology variables.
2. **Cluster Addons** -- Helm charts for core cluster components: CNI (Cilium),
   Cloud Controller Manager, CSI driver, and metrics-server.
3. **Node Images** -- build instructions or references for the OS images that
   run on cluster nodes.

These layers are published together as an OCI artifact. The
[Cluster Stack Operator](https://github.com/SovereignCloudStack/cluster-stack-operator)
(CSO) pulls these artifacts and installs them into a management cluster, making
the `ClusterClass` available for creating workload clusters.

## Repository structure

```text
providers/
  <provider>/
    <stack>/
      1-XX/                  # one directory per Kubernetes minor version
        stack.yaml           # metadata: provider, name, k8s version, addon pins
        cluster-class/       # Helm chart producing the ClusterClass
        cluster-addon/       # Helm chart with CNI, CCM, CSI, metrics-server
      image-manager.yaml     # OpenStack only: aggregated image references
```

### Per-minor-version directories

Each `1-XX/` directory is completely self-contained. It carries its own
`stack.yaml`, ClusterClass templates, and addon charts. There is no inheritance
or sharing between minor versions -- changes to one version never affect another.

This design makes it straightforward to:

- Support provider-specific API and implementation differences across minors.
- Pin addons to version ranges that match the Kubernetes minor
  (e.g. CCM `2.34.x` for K8s 1.34).
- Drop old versions by simply removing their directory.

### stack.yaml

Each version directory contains a `stack.yaml` that serves as the single source
of truth for that version:

```yaml
provider: openstack
clusterStackName: scs
kubernetesVersion: 1.35

addons:                    # version pins used by `just update addons`
  ccm: 2.35.x
  csi: 2.35.x
```

The `addons` section declares SemVer ranges. When you run `just update addons`,
the build system resolves these ranges against upstream Helm repositories and
updates the `Chart.yaml` dependencies in the addon chart.

## Available stacks

### OpenStack / scs

The standard SCS cluster stack. Creates dedicated VMs for both control plane and
worker nodes on OpenStack. Supports Kubernetes 1.32 through 1.35.

- Versions 1-32 through 1-35 use a `ClusterClass`-based configuration model.
- Version 1-35 uses unified variables (`flavor`) and
  per-role overrides via `topology.controlPlane.variables.overrides`.

### OpenStack / hcp

Hosted Control Plane stack. The Kubernetes control plane runs as pods in the
management cluster (using the
[teutonet Hosted Control Plane provider](https://github.com/teutonet/cluster-api-provider-hosted-control-plane));
only worker nodes are OpenStack VMs.

See [providers/openstack/hcp.md](providers/openstack/hcp.md) for details.

### Docker / scs

A lightweight stack for local development and CI. Uses the CAPI Docker
infrastructure provider. No cloud credentials required.

## Versioning

A cluster stack version is a single integer (`v1`, `v2`, ...) that represents
the state of the entire bundle at a point in time. Any change to the
ClusterClass, addons, or node images produces a new version.

The full identifier of a cluster stack release is:

```text
<provider>-<stack>-<k8s-major>-<k8s-minor>-v<version>
```

For example: `openstack-scs-1-35-v3` means the third release of the `scs` stack
for Kubernetes 1.35 on OpenStack.

Kubernetes patch versions are not part of the directory structure. A patch
version update (e.g. 1.35.1 to 1.35.2) is delivered by bumping the cluster
stack version, which updates the `kubernetesVersion` field and triggers a
rolling update of nodes.

## Build system

The build system uses [`just`](https://just.systems) as a task runner and a set
of bash scripts in `hack/`:

| Command                                 | Description                                    |
| --------------------------------------- | ---------------------------------------------- |
| `just build --version 1.35`             | Build locally to `.release/`                   |
| `just publish --version 1.35`           | Build and push to OCI registry                 |
| `just dev --version 1.35`               | Publish and print `ClusterStack` resource YAML |
| `just dev --install-cso --version 1.35` | Also install/upgrade CSO via Helm              |
| `just install-cso`                      | Install CSO standalone                         |
| `just matrix`                           | Show version and addon matrix                  |
| `just update versions`                  | Update Kubernetes patch versions               |
| `just update addons`                    | Update addon charts from upstream              |
| `just generate-resources`               | Generate `ClusterStack` + `Cluster` YAML       |
| `just generate-docs`                    | Regenerate configuration documentation         |
| `just clean`                            | Remove `.release/` build artifacts             |

### OCI workflow

Cluster stack releases are OCI artifacts. For development, the build system
auto-configures [ttl.sh](https://ttl.sh) as a temporary registry (artifacts
expire after 24 hours). For production, set `OCI_REGISTRY` and
`OCI_REPOSITORY` environment variables to point to your registry.

The CSO is installed via its Helm chart at
`oci://registry.scs.community/cluster-stacks/cso` and configured to pull from
whichever OCI registry you are publishing to.

## Providers and the Cluster API

The Cluster API (CAPI) provides a declarative, Kubernetes-native API for
creating and managing clusters. Each infrastructure provider (OpenStack, Docker,
etc.) implements the CAPI contracts for provisioning machines and networks.

The CSO sits on top of CAPI: it manages the lifecycle of cluster stack releases,
installs ClusterClasses, and handles version upgrades. Users create `Cluster`
resources that reference a `ClusterClass` -- the CAPI topology controller then
reconciles the desired state into actual infrastructure.
