# Quickstart

This guide walks through creating a CAPI management cluster and deploying a
workload cluster using one of the available cluster stacks. It covers OpenStack,
Docker (local development), and HCP (Hosted Control Plane) variants.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and
  [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [Helm](https://helm.sh/docs/intro/install/)
- [clusterctl](https://cluster-api.sigs.k8s.io/user/quick-start.html#install-clusterctl)
- [just](https://just.systems/man/en/installation.html)

For OpenStack stacks you also need:

- An OpenStack cloud with application credentials
- A `clouds.yaml` with your credentials

## 1. Create a management cluster

```bash
kind create cluster
```

## 2. Install CAPI and the infrastructure provider

### OpenStack (scs and hcp stacks)

```bash
clusterctl init --infrastructure openstack
```

For clusters using the [OpenStack Resource Controller](https://github.com/k-orc/openstack-resource-controller)
image format (ORC), also install ORC:

```bash
kubectl apply -f https://github.com/k-orc/openstack-resource-controller/releases/latest/download/install.yaml
```

### Docker (local development)

```bash
clusterctl init --infrastructure docker
```

### HCP (Hosted Control Plane)

The HCP stack requires both the OpenStack provider and the teutonet Hosted
Control Plane provider:

```bash
clusterctl init --infrastructure openstack
# Install the Hosted Control Plane provider (see teutonet docs for latest URL)
kubectl apply -f https://github.com/teutonet/cluster-api-provider-hosted-control-plane/releases/latest/download/install.yaml
```

## 3. Install the Cluster Stack Operator

The quickest way during development:

```bash
just install-cso
```

This installs the CSO Helm chart from
`oci://registry.scs.community/cluster-stacks/cso` and auto-configures
[ttl.sh](https://ttl.sh) as a temporary OCI registry.

For production, set `OCI_REGISTRY` and `OCI_REPOSITORY` before running:

```bash
export OCI_REGISTRY=registry.example.com
export OCI_REPOSITORY=kaas/cluster-stacks
just install-cso
```

## 4. Build and publish a cluster stack

```bash
# Build and publish all versions for the default stack (openstack/scs)
just publish --all

# Or target a specific version
just publish --version 1.35

# For a different stack, set the environment
PROVIDER=docker CLUSTER_STACK=scs just publish --version 1.35
```

The `dev` recipe combines publish with generating the `ClusterStack` resource:

```bash
just dev --version 1.35
```

This prints a `ClusterStack` YAML that you can pipe to `kubectl apply -f -`.

To also install/upgrade the CSO in one step:

```bash
just dev --install-cso --version 1.35
```

## 5. Deploy OpenStack credentials (OpenStack only)

Create a namespace for your tenant and deploy credentials using the
[csp-helper chart](https://github.com/SovereignCloudStack/openstack-csp-helper):

```bash
export CS_NAMESPACE=my-tenant

helm upgrade -i csp-helper-"${CS_NAMESPACE}" \
  -n "${CS_NAMESPACE}" --create-namespace \
  https://github.com/SovereignCloudStack/openstack-csp-helper/releases/latest/download/openstack-csp-helper.tgz \
  -f path/to/clouds.yaml
```

## 6. Apply the ClusterStack resource

If you used `just dev`, the output already contains this. Otherwise, generate it:

```bash
just generate-resources --version 1.35 --clusterstack-only
```

Example output:

```yaml
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: openstack-1-35
  namespace: cluster
spec:
  provider: openstack
  name: scs
  kubernetesVersion: "1.35"
  channel: custom
  autoSubscribe: false
  versions:
    - v1   # matches your published version
```

Apply it and wait for the `ClusterClass` to become available:

```bash
kubectl apply -f clusterstack.yaml
kubectl get clusterclass -w
```

## 7. Create a workload cluster

Generate a `Cluster` resource:

```bash
just generate-resources --version 1.35 --cluster-only
```

Or write one manually. Here is a minimal example for OpenStack/scs 1-35:

```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: my-cluster
  namespace: my-tenant
  labels:
    managed-secret: cloud-config
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
        - 192.168.0.0/16
    serviceDomain: cluster.local
    services:
      cidrBlocks:
        - 10.96.0.0/12
  topology:
    class: openstack-scs-1-35-v1
    controlPlane:
      replicas: 3
    version: v1.35.0
    workers:
      machineDeployments:
        - class: default-worker
          name: default-worker
          replicas: 3
    variables:
      - name: flavor
        value: "SCS-4V-8-20"
      - name: networkExternalID
        value: "your-external-network-uuid"
```

Apply and monitor:

```bash
kubectl apply -f cluster.yaml
clusterctl -n my-tenant describe cluster my-cluster
```

## 8. Access the workload cluster

```bash
clusterctl -n my-tenant get kubeconfig my-cluster > kubeconfig.yaml
kubectl --kubeconfig kubeconfig.yaml get nodes
```

## Docker variant

For the Docker provider, no cloud credentials or external network are needed:

```bash
export PROVIDER=docker
export CLUSTER_STACK=scs

just dev --install-cso --version 1.35
# Apply the printed ClusterStack YAML, then create a cluster
just generate-resources --version 1.35 --cluster-only | kubectl apply -f -
```

## HCP variant

The HCP stack creates control plane pods in the management cluster instead of
dedicated VMs. Worker-specific variables use the `worker` prefix
(`workerFlavor`, `workerRootDisk`):

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: my-hcp-cluster
  namespace: my-tenant
  labels:
    managed-secret: cloud-config
spec:
  topology:
    class: openstack-hcp-1-35-v1
    controlPlane:
      replicas: 3
    version: v1.35.0
    workers:
      machineDeployments:
        - class: default-worker
          name: default-worker
          replicas: 3
    variables:
      - name: workerFlavor
        value: "SCS-4V-8-20"
      - name: networkExternalID
        value: "your-external-network-uuid"
      - name: gatewayName
        value: "my-gateway"
      - name: gatewayNamespace
        value: "default"
```

See [providers/openstack/hcp.md](providers/openstack/hcp.md) for full details.

## Useful commands

```bash
just matrix                      # show version/addon matrix for all stacks
just update versions             # update Kubernetes patch versions
just update addons               # update addon chart versions
just generate-docs               # regenerate configuration reference docs
just clean                       # remove build artifacts
```
