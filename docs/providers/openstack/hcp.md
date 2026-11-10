# OpenStack HCP (Hosted Control Plane)

The `hcp` cluster stack runs the Kubernetes control plane as pods inside the
management cluster, using the
[teutonet Hosted Control Plane provider](https://github.com/teutonet/cluster-api-provider-hosted-control-plane).
Only worker nodes are created as OpenStack VMs.

## How it differs from the `scs` stack

| Aspect | scs | hcp |
| ------ | --- | --- |
| Control plane | Dedicated OpenStack VMs | Pods in the management cluster |
| Control plane template | `KubeadmControlPlaneTemplate` | `HostedControlPlaneTemplate` (v1alpha1) |
| CAPI API version | `v1beta2` (1-35) | `v1beta1` |
| CP machine infrastructure | `OpenStackMachineTemplate` | None (no CP VMs) |
| API server load balancer | Configurable (Octavia / none) | `none` by default (uses Gateway API) |
| API server floating IP | Configurable | Disabled by default |
| Variable model | Unified (`flavor`, `rootDisk`) | Worker-prefixed (`workerFlavor`, etc.) |
| Unique variables | `oidcConfig`, `registryMirrors` | `gatewayName`, `gatewayNamespace`, `controlPlaneReplicas` |

## Architecture

```text
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

1. A Gateway API implementation with the `TLSRoute` CRD and a `Gateway` with a TLS passthrough listener on a wildcard
   hostname (for example `*.<floating-ip>.sslip.io`). The workers reach the hosted API server and the Konnectivity
   server through it. On an `scs` management cluster the Gateway API CRDs and the `cilium` `GatewayClass` come with the
   stack, see [Gateway API CRDs](../../build-system.md#gateway-api-crds).

2. cert-manager >= 1.18, started with `--enable-certificate-owner-ref=true`.

3. Install the teutonet Hosted Control Plane provider in the management cluster. The provider has to match the Gateway
   API version of the management cluster:

   | Provider | Needs | Works with |
   |---|---|---|
   | v1.5.0 | `TLSRoute` `v1alpha2` (Gateway API >= 1.3) | Cilium 1.19 (Gateway API v1.4.1), tested |
   | v1.6.0 and newer | `TLSRoute` `v1` (Gateway API >= 1.5) | Cilium 1.20 (Gateway API v1.6.3), not tested |

   Newer providers do not start with Cilium 1.19 (`no matches for kind "TLSRoute" in version "gateway.networking.k8s.io/v1"`),
   although the README of the provider states Gateway API v1.3+. Installation:

   ```bash
   kubectl apply -f https://github.com/teutonet/cluster-api-provider-hosted-control-plane/releases/download/v1.5.0/control-plane-components.yaml
   ```

4. A default `StorageClass` with fast volumes for etcd. The `HostedControlPlane` does not offer a setting for the
   `StorageClass` of etcd, it uses the default one. On a cloud where the default volume type has a high latency etcd
   becomes slow, the API server answers watch requests late and the Konnectivity agents on the workers do not become
   ready (`kubectl logs` and `kubectl exec` fail, the metrics server does not work).

5. If the tenant networks of the cloud have a larger MTU than the external network, set the variable `networkMTU` (for
   example `1442`). Otherwise connections from the workers to the hosted API server through a floating IP take several
   seconds per connection, as the path MTU discovery does not work between the networks.

## Available versions

| Version | Kubernetes | Notes                      |
|---------|------------|----------------------------|
| 1-33    | 1.33       | Initial HCP release        |
| 1-34    | 1.34       | Updated CCM/CSI            |
| 1-35    | 1.35       | Updated CCM/CSI            |
| 1-36    | 1.36       | Needs Cluster API >= 1.12.8 or >= 1.13.1, see [Versioning](../../versioning.md) |

## Usage

### Build and publish

```bash
export PROVIDER=openstack
export CLUSTER_STACK=hcp

just dev 1.35 --install-cso | kubectl apply -f -
kubectl get clusterclass -w
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

| Variable | Type | Default | Description |
| -------- | ---- | ------- | ----------- |
| `controlPlaneReplicas` | integer | 3 | Number of hosted control plane replicas |
| `gatewayName` | string | "" | Gateway API resource name for API server ingress |
| `gatewayNamespace` | string | "default" | Namespace of the Gateway resource |
| `disableAPIServerFloatingIP` | boolean | true | Disable floating IP for API server |
| `apiServerLoadBalancer` | string | "none" | Load balancer type (typically `none` for HCP) |

### Worker variables

| Variable | Type | Default | Description |
| -------- | ---- | ------- | ----------- |
| `workerFlavor` | string | "SCS-2V-4" | OpenStack flavor for worker nodes |
| `workerRootDisk` | integer | 25 | Root disk size in GiB |
| `workerServerGroupID` | string | "" | Anti-affinity server group for workers |
| `workerAdditionalBlockDevices` | array | [] | Extra Cinder volumes for workers |
| `workerSecurityGroups` | array | [] | Security group names for workers |
| `workerSecurityGroupIDs` | array | [] | Security group UUIDs for workers |

### Shared variables (same as scs)

| Variable | Type | Default | Description |
| -------- | ---- | ------- | ----------- |
| `imageName` | string | "ubuntu-capi-image" | Base OS image name |
| `networkExternalID` | string | "" | External network UUID |
| `networkMTU` | integer | (provider default) | MTU for cluster network |
| `dnsNameservers` | array | ["9.9.9.9", "149.112.112.112"] | DNS nameservers |
| `nodeCIDR` | string | "10.8.0.0/20" | Subnet CIDR for cluster nodes |
| `sshKeyName` | string | "" | SSH key to inject into nodes |
| `certSANs` | array | [] | Extra SANs for API server certificate |
