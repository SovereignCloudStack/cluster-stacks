# Cluster Stacks

Reference implementation of SCS Kubernetes-as-a-Service cluster stacks, built on
[Cluster API](https://cluster-api.sigs.k8s.io/) and managed by the
[Cluster Stack Operator](https://github.com/SovereignCloudStack/cluster-stack-operator) (CSO).

## Quick start

```bash
# Prerequisites: kind, kubectl, helm, clusterctl, make, yq, oras
# See docs/quickstart.md for full details

# Create a management cluster and install CAPI + provider
kind create cluster
clusterctl init --infrastructure docker   # or: --infrastructure openstack

# Build, publish, install CSO, and apply the ClusterStack in one step
export PROVIDER=docker CLUSTER_STACK=scs
make dev ARGS="--install-cso --version 1.35" | kubectl apply -f -
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

All workflows are driven by `make`:

```bash
make build ARGS="--version 1.35"       # build locally to .release/
make publish ARGS="--version 1.35"     # build + push to OCI registry
make dev ARGS="--version 1.35"         # publish + print ClusterStack YAML
make dev ARGS="--install-cso --version 1.35"  # also install/upgrade CSO
make matrix                     # show version/addon matrix
make update ARGS="versions"     # update Kubernetes patch versions
make update ARGS="addons"       # update addon chart versions
make generate-resources ARGS="--version 1.35"  # generate ClusterStack + Cluster YAML
make generate-docs              # regenerate configuration docs
```

Set `PROVIDER` and `CLUSTER_STACK` environment variables (or use direnv with a `.env` file)
to target a different stack (default: `openstack`/`scs`).

## Documentation

- [Quickstart](docs/quickstart.md) -- local development with Docker/CAPD
- [Overview](docs/overview.md) -- architecture, versioning, and structure
- [OpenStack / scs](docs/providers/openstack/scs-configuration.md) -- standard SCS stack
- [OpenStack / hcp](docs/providers/openstack/hcp.md) -- Hosted Control Plane stack

Configuration references are generated from ClusterClass definitions via
`make generate-docs`.

## Releases

Releases are published as OCI artifacts to the
[SCS registry](https://registry.scs.community/kaas/cluster-stacks).

## Community

- [Matrix](https://matrix.to/#/!NZpJdPGjAHISXnHUil:matrix.org)
- [Meeting notes](https://input.scs.community/2025-scs-team-container)
