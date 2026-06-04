# Cluster Stacks

Reference implementation of SCS Kubernetes-as-a-Service cluster stacks, built on
[Cluster API](https://cluster-api.sigs.k8s.io/) and managed by the
[Cluster Stack Operator](https://github.com/SovereignCloudStack/cluster-stack-operator) (CSO).

## Quick start

```bash
# Prerequisites: kind, kubectl, helm, clusterctl, just, yq, oras
# See docs/quickstart.md for full details

# Create a management cluster and install CAPI + provider
kind create cluster
clusterctl init --infrastructure docker   # or: --infrastructure openstack

# Build, publish, install CSO, and apply the ClusterStack in one step
export PROVIDER=docker CLUSTER_STACK=scs
just dev --install-cso --version 1.35 | kubectl apply -f -
```

See [docs/quickstart.md](docs/quickstart.md) for a complete walkthrough.

## Available cluster stacks

| Provider   | Stack | Description                              | Versions       |
|------------|-------|------------------------------------------|----------------|
| OpenStack  | scs   | Standard SCS stack (dedicated VMs)       | 1-32 .. 1-35   |
| OpenStack  | hcp   | Hosted Control Plane (CP as pods)        | 1-33 .. 1-35   |
| Docker     | scs   | Local development stack                  | 1-32 .. 1-35   |

## Repository structure

```text
providers/
  <provider>/
    <stack>/
      1-XX/              # per-Kubernetes-minor-version directory
        csctl.yaml       # stack metadata and addon version pins
        cluster-class/   # Helm chart: ClusterClass + infrastructure templates
        cluster-addon/   # Helm chart: CNI, CCM, CSI, metrics-server
      image-manager.yaml # OpenStack only: aggregated image references
```

Each `1-XX/` directory is self-contained: it carries its own `csctl.yaml`,
ClusterClass definition, and addon charts. There is no shared state between
minor versions.

## Build system

All workflows are driven by [`just`](https://just.systems):

```bash
just build --version 1.35       # build locally to .release/
just publish --version 1.35     # build + push to OCI registry
just dev --version 1.35         # publish + print ClusterStack YAML
just dev --install-cso --version 1.35  # also install/upgrade CSO
just matrix                     # show version/addon matrix
just update versions            # update Kubernetes patch versions
just update addons              # update addon chart versions
just generate-resources --version 1.35  # generate ClusterStack + Cluster YAML
just generate-docs              # regenerate configuration docs
```

Set `PROVIDER` and `CLUSTER_STACK` environment variables (or use a `.env` file)
to target a different stack (default: `openstack`/`scs`).

## Documentation

- [Quickstart](docs/quickstart.md) -- local development with Docker/CAPD
- [Overview](docs/overview.md) -- architecture, versioning, and structure
- [OpenStack / scs](docs/providers/openstack/scs-configuration.md) -- standard SCS stack
- [OpenStack / hcp](docs/providers/openstack/hcp.md) -- Hosted Control Plane stack

Configuration references are generated from ClusterClass definitions via
`just generate-docs`.

## Releases

Releases are published as OCI artifacts to the
[SCS registry](https://registry.scs.community/kaas/cluster-stacks).

## Community

- [Matrix](https://matrix.to/#/!NZpJdPGjAHISXnHUil:matrix.org)
- [Meeting notes](https://input.scs.community/2025-scs-team-container)
