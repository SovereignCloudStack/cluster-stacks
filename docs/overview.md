# Overview

Cluster Stacks is the reference implementation for defining and managing Kubernetes clusters via [Cluster API](https://cluster-api.sigs.k8s.io/) (CAPI). Each **cluster stack** is a versioned, self-contained package that bundles everything needed to create production-grade Kubernetes clusters on a given infrastructure provider.

## Architecture

A cluster stack lives in `providers/{provider}/{stack}/` and consists of two main components:

```
providers/openstack/scs2/
  csctl.yaml               # Stack metadata (provider, name, K8s version)
  clusteraddon.yaml        # Addon lifecycle hooks (when to install what)
  versions.yaml            # K8s version -> addon version mapping + metadata
  cluster-class/           # Helm chart: ClusterClass CRD
    Chart.yaml
    values.yaml            # Variable defaults + image references
    templates/
      cluster-class.yaml
      kubeadm-control-plane-template.yaml
      kubeadm-config-template-worker-*.yaml
      *-machine-template-*.yaml
      *-cluster-template.yaml
  cluster-addon/           # Collection of Helm sub-charts
    cni/                   # Cilium
    metrics-server/
    occm/                  # OpenStack Cloud Controller Manager (provider-specific)
    cinder-csi/            # Cinder CSI (provider-specific)
```

### Cluster Class

The **cluster-class** is a single Helm chart that defines the [ClusterClass](https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-class/) CRD. It contains:

- The ClusterClass resource with variables, patches, and template references
- Infrastructure templates (e.g. OpenStackMachineTemplate, DockerClusterTemplate)
- Control plane template (KubeadmControlPlaneTemplate)
- Worker bootstrap template (KubeadmConfigTemplate)

Variables declared in the ClusterClass allow per-cluster customization (flavors, disk sizes, security groups, OIDC, etc.) without modifying the stack itself. Default values are defined in `values.yaml` and referenced via `{{ .Values.variables.* }}` in the templates.

### Cluster Addons

**Cluster addons** are core components installed onto the workload cluster by the [cluster-stack-operator](https://github.com/SovereignCloudStack/cluster-stack-operator). They are **not** user applications — they are foundational services:

| Addon | Purpose | Present in |
|-------|---------|------------|
| **Cilium** (CNI) | Pod networking and network policy | All stacks |
| **metrics-server** | Node/pod resource metrics, enables HPA | All stacks |
| **OCCM** | OpenStack Cloud Controller Manager | OpenStack stacks |
| **Cinder CSI** | Persistent volume provisioning via OpenStack Cinder | OpenStack stacks |

Addon installation timing is controlled by `clusteraddon.yaml` using [CAPI lifecycle hooks](https://cluster-api.sigs.k8s.io/tasks/experimental-features/runtime-sdk/implement-lifecycle-hooks):

- `AfterControlPlaneInitialized` — CNI (required before workers can join)
- `BeforeClusterUpgrade` — all addons (ensures compatibility during upgrades)

### Node Images

For OpenStack, node images are pre-built Ubuntu images with containerd and kubelet. The image name encodes the Kubernetes version (e.g. `ubuntu-capi-image-v1.32.5`). The `versions.yaml` file maps Kubernetes versions to Ubuntu releases:

- K8s 1.32 and earlier: Ubuntu 22.04
- K8s 1.33+: Ubuntu 24.04

For Docker (development/testing), the `kindest/node` images from the kind project are used.

## Available Stacks

| Provider | Stack | API Version | Description |
|----------|-------|-------------|-------------|
| `openstack` | `scs` | v1beta1 | Legacy OpenStack stack |
| `openstack` | `scs2` | v1beta2 | Production OpenStack stack with updated variable names and v1beta2 core resources |
| `docker` | `scs` | v1beta1 | Legacy Docker stack for local development |
| `docker` | `scs2` | v1beta2 | Docker stack with v1beta2 core resources, production tuning, OIDC support |

> **Note:** "v1beta2" refers to CAPI core resources (ClusterClass, KubeadmControlPlaneTemplate, KubeadmConfigTemplate). Infrastructure provider resources (OpenStackMachineTemplate, DockerMachineTemplate) remain at their provider's own API version (currently v1beta1).

## Versioning

Release artifacts follow the naming scheme:

```
{provider}-{stack}-{k8s-major}-{k8s-minor}-{cluster-stack-version}
```

Examples:
- `openstack-scs2-1-34-v1` — first stable release for K8s 1.34
- `docker-scs2-1-35-v0` — dev release for K8s 1.35

Version semantics:
- **`v0`** = development version (published to ttl.sh with 24h TTL or git hash tag)
- **`v1`, `v2`, ...** = stable versions (auto-incremented by querying the OCI registry)

Any change to the cluster-class, cluster-addons, or node images triggers a version bump of the entire cluster stack.

## Repository Structure

```
providers/
  docker/
    scs/                   # v1beta1 Docker stack
    scs2/                  # v1beta2 Docker stack
  openstack/
    scs/                   # v1beta1 OpenStack stack (legacy)
    scs2/                  # v1beta2 OpenStack stack (production)
hack/                      # Build and utility scripts
docs/                      # Documentation (consumed by Docusaurus)
Taskfile.yml               # Task runner definitions
justfile                   # Just runner definitions
Containerfile              # Build container image
```
