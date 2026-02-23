# OpenStack HCP (Hosted Control Plane)

The `hcp` cluster stack runs the Kubernetes control plane as pods inside the
management cluster, using the
[teutonet Hosted Control Plane provider](https://github.com/teutonet/cluster-api-provider-hosted-control-plane).
Only worker nodes are created as OpenStack VMs.

## How it differs from the `scs` stack

| Aspect                     | scs                                       | hcp                                        |
|----------------------------|-------------------------------------------|--------------------------------------------|
| Control plane              | Dedicated OpenStack VMs                   | Pods in the management cluster             |
| Control plane template     | `KubeadmControlPlaneTemplate`             | `HostedControlPlaneTemplate` (v1alpha1)    |
| CAPI API version           | `v1beta2` (1-35)                          | `v1beta1`                                  |
| CP machine infrastructure  | `OpenStackMachineTemplate`                | None (no CP VMs)                           |
| API server load balancer   | Configurable (Octavia / none)             | `none` by default (uses Gateway API)       |
| API server floating IP     | Configurable                              | Disabled by default                        |
| Variable model             | Unified (`flavor`, `rootDisk`)            | Worker-prefixed (`workerFlavor`, etc.)     |
| Unique variables           | `oidcConfig`, `registryMirrors`           | `gatewayName`, `gatewayNamespace`, `controlPlaneReplicas` |

## Architecture

```
Management Cluster
  +-- CP pods (etcd, apiserver, controller-manager, scheduler)
  +-- HostedControlPlane resource
  +-- Gateway API ingress (optional)

OpenStack
  +-- Worker VMs only
  +-- Cilium CNI
  +-- CCM + CSI (as DaemonSets/Deployments on workers)
```

The control plane is exposed to worker nodes via the management cluster's
network. For external access to the API server, configure Gateway API resources
using the `gatewayName` and `gatewayNamespace` variables.

## Prerequisites

In addition to the standard [quickstart prerequisites](../../quickstart.md):

1. Install the teutonet Hosted Control Plane provider in the management cluster:

   ```bash
   kubectl apply -f https://github.com/teutonet/cluster-api-provider-hosted-control-plane/releases/latest/download/install.yaml
   ```

2. (Optional) Set up a Gateway API implementation (e.g., Envoy Gateway, Cilium
   Gateway API) if you want external access to the hosted API servers.

## Available versions

| Version | Kubernetes | Notes                      |
|---------|------------|----------------------------|
| 1-33    | 1.33       | Initial HCP release        |
| 1-34    | 1.34       | Updated CCM/CSI            |
| 1-35    | 1.35       | Updated CCM/CSI            |

## Usage

### Build and publish

```bash
export PROVIDER=openstack
export CLUSTER_STACK=hcp

just dev --install-cso --version 1.35
```

### Create a cluster

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: my-hcp-cluster
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
```

### With Gateway API ingress

To expose the hosted API server externally, configure a Gateway resource in the
management cluster and reference it:

```yaml
    variables:
      - name: gatewayName
        value: "cluster-gateway"
      - name: gatewayNamespace
        value: "gateway-system"
```

## Configuration variables

### HCP-specific variables

| Variable                 | Type    | Default     | Description                                      |
|--------------------------|---------|-------------|--------------------------------------------------|
| `controlPlaneReplicas`   | integer | 3           | Number of hosted control plane replicas           |
| `gatewayName`            | string  | ""          | Gateway API resource name for API server ingress  |
| `gatewayNamespace`       | string  | "default"   | Namespace of the Gateway resource                 |
| `disableAPIServerFloatingIP` | boolean | true    | Disable floating IP for API server                |
| `apiServerLoadBalancer`  | string  | "none"      | Load balancer type (typically `none` for HCP)     |

### Worker variables

| Variable                     | Type    | Default         | Description                                |
|------------------------------|---------|-----------------|--------------------------------------------|
| `workerFlavor`               | string  | "SCS-2V-4"     | OpenStack flavor for worker nodes          |
| `workerRootDisk`             | integer | 25              | Root disk size in GiB                      |
| `workerServerGroupID`        | string  | ""              | Anti-affinity server group for workers     |
| `workerAdditionalBlockDevices` | array | []              | Extra Cinder volumes for workers           |
| `workerSecurityGroups`       | array   | []              | Security group names for workers           |
| `workerSecurityGroupIDs`     | array   | []              | Security group UUIDs for workers           |

### Shared variables (same as scs)

| Variable            | Type    | Default                         | Description                              |
|---------------------|---------|---------------------------------|------------------------------------------|
| `imageName`         | string  | "ubuntu-capi-image"             | Base OS image name                       |
| `networkExternalID` | string  | ""                              | External network UUID                    |
| `networkMTU`        | integer | (provider default)              | MTU for cluster network                  |
| `dnsNameservers`    | array   | ["5.1.66.255", "185.150.99.255"]| DNS nameservers                          |
| `nodeCIDR`          | string  | "10.8.0.0/20"                   | Subnet CIDR for cluster nodes            |
| `sshKey`            | string  | ""                              | SSH key to inject into nodes             |
| `certSANs`          | array   | []                              | Extra SANs for API server certificate    |
