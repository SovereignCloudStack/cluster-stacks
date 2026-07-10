# OpenStack Hosted Control Plane Cluster Stack

This cluster stack provides Kubernetes clusters on OpenStack infrastructure using the teutonet hosted control plane provider. Unlike traditional cluster stacks where control plane components run on dedicated OpenStack VMs, this implementation runs control plane components (API server, controller manager, scheduler, etcd) in the management cluster.

## Architecture

- **Control Plane**: Hosted in management cluster (no OpenStack VMs)
- **Worker Nodes**: OpenStack VMs managed by CAPO
- **Control Plane Provider**: teutonet cluster-api-provider-hosted-control-plane
- **Infrastructure Provider**: cluster-api-provider-openstack (CAPO)

## Key Advantages

- **Cost Efficiency**: No dedicated OpenStack resources for control plane
- **Faster Provisioning**: No need to provision/bootstrap control plane VMs
- **Simplified Management**: Control plane managed as pods in management cluster
- **Resource Efficiency**: Control plane scales independently of worker nodes
- **High Availability**: Built-in HA through pod replicas in management cluster

## Prerequisites

### Management Cluster Requirements

1. **Kubernetes** v1.28+ on management cluster
2. **Cluster API** v1.10+ components:
   - cluster-api-controller-manager
   - cluster-api-provider-openstack (CAPO)
3. **cert-manager** v1.18+
4. **teutonet hosted-control-plane provider**

### Installing the Hosted Control Plane Provider

```bash
# Install the latest version
kubectl apply -f https://github.com/teutonet/cluster-api-provider-hosted-control-plane/releases/latest/download/control-plane-components.yaml

# Or install a specific version (recommended for production)
kubectl apply -f https://github.com/teutonet/cluster-api-provider-hosted-control-plane/releases/download/v0.1.0/control-plane-components.yaml

# Verify installation
kubectl get pods -n capi-system | grep hosted-control-plane
kubectl get crd hostedcontrolplanes.controlplane.cluster.x-k8s.io
kubectl get crd hostedcontrolplanetemplates.controlplane.cluster.x-k8s.io
```

### Optional Components

- Gateway API CRDs (recommended for advanced ingress configuration)
- OpenStack Resource Controller (ORC) for image management

### OpenStack Requirements

- Valid OpenStack credentials (clouds.yaml)
- External network with connectivity
- Sufficient quota for worker nodes
- Ubuntu/Flatcar images compatible with Cluster API

## Getting Started

### Initialize Management Cluster

```bash
# Create bootstrap cluster (if needed)
kind create cluster --name capi-management

# Set required environment variables
export CLUSTER_TOPOLOGY=true
export EXP_CLUSTER_RESOURCE_SET=true
export EXP_RUNTIME_SDK=true

# Initialize Cluster API with OpenStack provider
clusterctl init --infrastructure openstack

# Install hosted control plane provider
kubectl apply -f https://github.com/teutonet/cluster-api-provider-hosted-control-plane/releases/latest/download/control-plane-components.yaml

# Wait for deployments to be ready
kubectl -n capi-system rollout status deployment --timeout=5m
kubectl -n capo-system rollout status deployment --timeout=5m
```

### Install Cluster Stack Operator (CSO)

```bash
# Install CSO
helm upgrade -i cso \
  -n cso-system \
  --create-namespace \
  oci://registry.scs.community/cluster-stacks/cso

# Wait for CSO to be ready
kubectl -n cso-system rollout status deployment cso-controller-manager
```

## Deploying a Cluster

### 1. Prepare Environment Variables

```bash
export CLUSTER_NAMESPACE=cluster
export CLUSTER_NAME=my-hosted-cluster
export CLUSTERSTACK_NAMESPACE=cluster
export CLUSTERSTACK_VERSION=v1
export OS_CLIENT_CONFIG_FILE=${PWD}/clouds.yaml
```

### 2. Create Namespace and Secrets

```bash
# Create namespace
kubectl create namespace $CLUSTER_NAMESPACE

# Create OpenStack credentials secret
kubectl create secret -n $CLUSTER_NAMESPACE generic openstack \
  --from-file=clouds.yaml=$OS_CLIENT_CONFIG_FILE

# Create clouds.yaml secret for workload cluster
kubectl create secret -n kube-system generic clouds-yaml \
  --from-file=clouds.yaml=$OS_CLIENT_CONFIG_FILE \
  --dry-run=client -o yaml > clouds-yaml-secret

kubectl create -n $CLUSTER_NAMESPACE secret generic clouds-yaml \
  --from-file=clouds-yaml-secret \
  --type=addons.cluster.x-k8s.io/resource-set
```

### 3. Create ClusterResourceSet

```bash
cat <<EOF | kubectl apply -f -
apiVersion: addons.cluster.x-k8s.io/v1beta1
kind: ClusterResourceSet
metadata:
  name: clouds-yaml
  namespace: $CLUSTER_NAMESPACE
spec:
  strategy: "Reconcile"
  clusterSelector:
    matchLabels:
      managed-secret: clouds-yaml
  resources:
    - name: clouds-yaml
      kind: Secret
EOF
```

### 4. Deploy ClusterStack Resource

```bash
cat <<EOF | kubectl apply -f -
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: openstack
  namespace: $CLUSTERSTACK_NAMESPACE
spec:
  provider: openstack
  name: hosted-control-plane
  kubernetesVersion: "1.33"
  channel: stable
  autoSubscribe: false
  noProvider: true
  versions:
    - $CLUSTERSTACK_VERSION
EOF
```

### 5. Create Cluster

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: $CLUSTER_NAME
  namespace: $CLUSTER_NAMESPACE
  labels:
    managed-secret: clouds-yaml
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - "172.16.0.0/16"
    serviceDomain: cluster.local
    services:
      cidrBlocks:
      - "10.96.0.0/12"
  topology:
    class: openstack-hosted-control-plane-1-33-$CLUSTERSTACK_VERSION
    classNamespace: $CLUSTERSTACK_NAMESPACE
    controlPlane:
      replicas: 3
    version: v1.33.6
    variables:
      - name: controlPlaneReplicas
        value: 3
      - name: workerFlavor
        value: "SCS-2V-4"
      - name: workerRootDisk
        value: 25
      - name: imageName
        value: "ubuntu-capi-image"
      - name: imageAddVersion
        value: true
      - name: networkExternalID
        value: "YOUR-EXTERNAL-NETWORK-ID"
      - name: nodeCIDR
        value: "10.8.0.0/20"
      - name: dnsNameservers
        value: ["9.9.9.9", "149.112.112.112"]
      - name: identityRef
        value:
          name: "openstack"
          cloudName: "openstack"
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 2
EOF
```

### 6. Monitor Cluster Creation

```bash
# Watch cluster status
kubectl get cluster -n $CLUSTER_NAMESPACE -w

# Watch control plane (running in management cluster)
kubectl get hostedcontrolplane -n $CLUSTER_NAMESPACE

# Watch control plane pods
kubectl get pods -n $CLUSTER_NAMESPACE -l cluster.x-k8s.io/cluster-name=$CLUSTER_NAME

# Watch worker machines
kubectl get machine -n $CLUSTER_NAMESPACE

# Get kubeconfig for workload cluster
clusterctl get kubeconfig -n $CLUSTER_NAMESPACE $CLUSTER_NAME > $CLUSTER_NAME-kubeconfig

# Verify worker nodes are ready
kubectl --kubeconfig $CLUSTER_NAME-kubeconfig get nodes
```

## Configuration Variables

### Control Plane Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `controlPlaneReplicas` | integer | 3 | Number of control plane replicas for HA |
| `gatewayName` | string | "" | Name of Gateway API resource for control plane ingress (optional) |
| `gatewayNamespace` | string | "default" | Namespace of Gateway API resource |
| `certSANs` | array | [] | Extra Subject Alternative Names for API Server cert |

### Network Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `networkExternalID` | string | "" | External OpenStack network UUID (required) |
| `networkMTU` | integer | - | Network MTU value |
| `dnsNameservers` | array | ["9.9.9.9", "149.112.112.112"] | DNS servers for cluster network |
| `nodeCIDR` | string | "10.8.0.0/20" | CIDR for cluster node network |

### Worker Node Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `workerFlavor` | string | "SCS-4V-8" | OpenStack flavor for worker nodes |
| `workerRootDisk` | integer | 50 | Root disk size in GiB for workers (0 = use ephemeral) |
| `workerServerGroupID` | string | "" | Server group ID for worker anti-affinity |
| `workerAdditionalBlockDevices` | array | [] | Additional block devices for workers |
| `workerSecurityGroups` | array | [] | Extra security groups for workers (by name) |
| `workerSecurityGroupIDs` | array | [] | Extra security groups for workers (by UUID) |

### Image Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `imageName` | string | "ubuntu-capi-image" | Base image name for nodes |
| `imageIsOrc` | boolean | false | Use ORC image resource |
| `imageAddVersion` | boolean | true | Append K8s version to image name |

### Access Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `sshKeyName` | string | "" | SSH key name for node access (debugging) |
| `identityRef` | object | {name: "openstack", cloudName: "openstack"} | OpenStack credentials reference |
| `securityGroups` | array | [] | Extra security groups for all nodes (by name) |
| `securityGroupIDs` | array | [] | Extra security groups for all nodes (by UUID) |

### API Server Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `apiServerLoadBalancer` | string | "none" | Load balancer type (none, octavia-amphora, octavia-ovn) |
| `apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs` | array | [] | Allowed CIDRs for Octavia Amphora LB |
| `disableAPIServerFloatingIP` | boolean | true | Disable floating IP for API server (recommended for hosted CP) |

## Component Versions

### Kubernetes 1.33.6

| Component | Version | Repository |
|-----------|---------|------------|
| OpenStack Cloud Controller Manager | 2.33.1 | kubernetes.github.io/cloud-provider-openstack |
| OpenStack Cinder CSI | 2.33.1 | kubernetes.github.io/cloud-provider-openstack |
| Cilium CNI | 1.18.1 | helm.cilium.io |
| Metrics Server | 3.13.0 | kubernetes-sigs.github.io/metrics-server |

### Kubernetes 1.32.8

| Component | Version | Repository |
|-----------|---------|------------|
| OpenStack Cloud Controller Manager | 2.32.0 | kubernetes.github.io/cloud-provider-openstack |
| OpenStack Cinder CSI | 2.32.2 | kubernetes.github.io/cloud-provider-openstack |
| Cilium CNI | 1.18.1 | helm.cilium.io |
| Metrics Server | 3.13.0 | kubernetes-sigs.github.io/metrics-server |

### Kubernetes 1.31.12

| Component | Version | Repository |
|-----------|---------|------------|
| OpenStack Cloud Controller Manager | 2.31.3 | kubernetes.github.io/cloud-provider-openstack |
| OpenStack Cinder CSI | 2.31.7 | kubernetes.github.io/cloud-provider-openstack |
| Cilium CNI | 1.18.1 | helm.cilium.io |
| Metrics Server | 3.13.0 | kubernetes-sigs.github.io/metrics-server |

## Key Differences from Traditional Cluster Stacks

### Architectural Differences

| Aspect | Traditional (scs/scs2) | Hosted Control Plane |
|--------|----------------------|---------------------|
| Control Plane Location | OpenStack VMs | Management cluster pods |
| Control Plane Type | KubeadmControlPlane | HostedControlPlane |
| Control Plane VMs | 3+ VMs required | 0 VMs (pods only) |
| API Server Access | LoadBalancer or Floating IP | Via management cluster |
| etcd Storage | On control plane VMs | In management cluster (PVs) |
| Provisioning Time | ~10-15 minutes | ~5-7 minutes |
| Cost | Control plane + workers | Workers only |

### Operational Differences

- **Scaling**: Control plane scales as pods (faster, more flexible)
- **Upgrades**: Control plane upgraded via pod rolling update
- **Backup**: etcd backed up via standard Kubernetes backup tools
- **Monitoring**: Control plane metrics available in management cluster
- **Networking**: Control plane not on OpenStack network

## Troubleshooting

### Check Control Plane Status

```bash
# View control plane resource
kubectl get hostedcontrolplane -n $CLUSTER_NAMESPACE

# View control plane pods
kubectl get pods -n $CLUSTER_NAMESPACE -l cluster.x-k8s.io/cluster-name=$CLUSTER_NAME

# Check control plane logs
kubectl logs -n $CLUSTER_NAMESPACE -l cluster.x-k8s.io/cluster-name=$CLUSTER_NAME -c kube-apiserver
kubectl logs -n $CLUSTER_NAMESPACE -l cluster.x-k8s.io/cluster-name=$CLUSTER_NAME -c kube-controller-manager
kubectl logs -n $CLUSTER_NAMESPACE -l cluster.x-k8s.io/cluster-name=$CLUSTER_NAME -c kube-scheduler
```

### Check Worker Nodes

```bash
# Get kubeconfig
clusterctl get kubeconfig -n $CLUSTER_NAMESPACE $CLUSTER_NAME > /tmp/kubeconfig

# View worker nodes
kubectl --kubeconfig /tmp/kubeconfig get nodes

# View worker pods
kubectl --kubeconfig /tmp/kubeconfig get pods -A
```

### Check Addons

```bash
# Verify CNI (Cilium)
kubectl --kubeconfig /tmp/kubeconfig get pods -n kube-system -l k8s-app=cilium

# Verify CCM
kubectl --kubeconfig /tmp/kubeconfig get pods -n kube-system -l app=openstack-cloud-controller-manager

# Verify CSI
kubectl --kubeconfig /tmp/kubeconfig get pods -n kube-system -l app=cinder-csi

# Verify metrics-server
kubectl --kubeconfig /tmp/kubeconfig top nodes
```

### Common Issues

#### Control plane pods not starting

**Symptom**: HostedControlPlane created but no pods appear

**Solution**:
1. Check teutonet provider is running: `kubectl get pods -n capi-system | grep hosted-control-plane`
2. Check HostedControlPlane events: `kubectl describe hostedcontrolplane -n $CLUSTER_NAMESPACE`
3. Verify management cluster has sufficient resources

#### Worker nodes not joining

**Symptom**: Machines created but nodes don't appear in `kubectl get nodes`

**Solution**:
1. Check cloud-init logs on worker VMs
2. Verify OpenStack network connectivity
3. Check control plane is accessible from workers
4. Verify clouds.yaml secret exists in workload cluster: `kubectl --kubeconfig /tmp/kubeconfig get secret -n kube-system clouds-yaml`

#### Cluster addon failures

**Symptom**: Addons fail to install or pods crash

**Solution**:
1. Check ClusterResourceSet applied: `kubectl get clusterresourceset -n $CLUSTER_NAMESPACE`
2. Verify addon configurations match component versions
3. Check addon logs in workload cluster

## Upgrading

### Upgrade Kubernetes Version

```bash
# Update cluster version
kubectl patch cluster -n $CLUSTER_NAMESPACE $CLUSTER_NAME --type merge -p '{"spec":{"topology":{"version":"v1.32.8"}}}'

# Monitor upgrade
kubectl get cluster -n $CLUSTER_NAMESPACE -w
```

### Scale Control Plane

```bash
# Update control plane replicas
kubectl patch cluster -n $CLUSTER_NAMESPACE $CLUSTER_NAME --type merge -p '{"spec":{"topology":{"variables":[{"name":"controlPlaneReplicas","value":5}]}}}'

# Monitor scaling
kubectl get hostedcontrolplane -n $CLUSTER_NAMESPACE -w
```

### Scale Workers

```bash
# Update worker replicas
kubectl patch cluster -n $CLUSTER_NAMESPACE $CLUSTER_NAME --type merge -p '{"spec":{"topology":{"workers":{"machineDeployments":[{"class":"default-worker","name":"md-0","replicas":5}]}}}}'

# Monitor scaling
kubectl get machines -n $CLUSTER_NAMESPACE -w
```

## Deleting a Cluster

```bash
# Delete cluster resource (will delete all associated resources)
kubectl delete cluster -n $CLUSTER_NAMESPACE $CLUSTER_NAME

# Monitor deletion
kubectl get cluster -n $CLUSTER_NAMESPACE -w

# Verify OpenStack resources are cleaned up
openstack server list
openstack network list
```

## References

- [teutonet hosted-control-plane provider](https://github.com/teutonet/cluster-api-provider-hosted-control-plane)
- [Cluster API documentation](https://cluster-api.sigs.k8s.io/)
- [OpenStack provider documentation](https://github.com/kubernetes-sigs/cluster-api-provider-openstack)
- [Cluster Stacks documentation](https://docs.scs.community/docs/category/cluster-stacks)

## Support

For issues and questions:
- Hosted control plane provider: https://github.com/teutonet/cluster-api-provider-hosted-control-plane/issues
- Cluster stacks: https://github.com/SovereignCloudStack/cluster-stacks/issues
