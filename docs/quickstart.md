# Quickstart

Get a workload cluster running locally in a few minutes using the CAPI Docker
provider (CAPD). No cloud account required.

For OpenStack, see [providers/openstack/scs-configuration.md](providers/openstack/scs-configuration.md).
For Hosted Control Plane, see [providers/openstack/hcp.md](providers/openstack/hcp.md).

## Prerequisites

Install these tools before starting:

| Tool | Purpose |
|------|---------|
| [Docker](https://docs.docker.com/get-docker/) + [kind](https://kind.sigs.k8s.io/) | Local Kubernetes clusters |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Cluster access |
| [clusterctl](https://cluster-api.sigs.k8s.io/user/quick-start.html#install-clusterctl) | CAPI bootstrap |
| [Helm](https://helm.sh/docs/intro/install/) | Chart installation |
| [make](https://www.gnu.org/software/make/) | Build recipes |
| [yq](https://github.com/mikefarah/yq) (mikefarah variant) | YAML processing |
| [oras](https://oras.land/docs/installation) | OCI artifact push |

## Steps

### 1. Create a management cluster

```bash
kind create cluster
clusterctl init --infrastructure docker
```

### 2. Point the build system at the Docker stack

Set the target provider and stack:

```bash
export PROVIDER=docker
export CLUSTER_STACK=scs
```

Or create a `.env` file if you use [direnv](https://direnv.net/):

```bash
cat > .env <<EOF
PROVIDER=docker
CLUSTER_STACK=scs
EOF
```

### 3. Build, publish, and install the stack

Create the namespace, then run everything in one step: installs the CSO, builds
and publishes the stack to a temporary registry ([ttl.sh](https://ttl.sh), 24 h
TTL), and applies the `ClusterStack` resource:

```bash
kubectl create namespace cluster
make dev ARGS="--install-cso --version 1.35" | kubectl apply -f -
```

Build logs go to stderr. Wait until the `ClusterClass` is ready:

```bash
kubectl get clusterclass -w
# Expected: docker-scs-1-35-<version>   Ready
```

### 4. Create a workload cluster

```bash
make generate-resources ARGS="--version 1.35 --cluster-only" | kubectl apply -f -
```

Watch it come up:

```bash
clusterctl -n cluster describe cluster cs-cluster
```

### 5. Access the workload cluster

```bash
clusterctl -n cluster get kubeconfig cs-cluster > kubeconfig.yaml
kubectl --kubeconfig kubeconfig.yaml get nodes
```

## What was created

```
.release/
  docker-scs-1-35-<version>/
    csctl.yaml             # stack metadata
    clusteraddon.yaml      # addon lifecycle config
    docker-scs-1-35-cluster-class-<version>.tgz
    docker-scs-1-35-cluster-addon-<version>.tgz
    metadata.yaml
```

The Cluster Stack Operator (CSO) pulled this artifact from ttl.sh and installed
the `ClusterClass` into the management cluster. Your `Cluster` resource
references that class.

## Useful commands

```bash
make matrix                   # show K8s versions and addon versions
make clean                    # remove .release/ build artifacts
make update ARGS="versions"   # update K8s patch versions in csctl.yaml
make update ARGS="addons"     # update addon chart versions
```
