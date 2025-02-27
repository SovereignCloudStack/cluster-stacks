# Cluster Stacks

## Getting started

```sh
# Create bootstrap cluster
echo "
---
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  ipFamily: dual
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /var/run/docker.sock
        containerPath: /var/run/docker.sock" | kind create cluster --config -

# Init Cluster API
export CLUSTER_TOPOLOGY=true
export EXP_CLUSTER_RESOURCE_SET=true
export EXP_RUNTIME_SDK=true
clusterctl init --infrastructure docker

kubectl -n capi-system rollout status deployment
kubectl -n capd-system rollout status deployment

# Install CSO and CSPO
helm upgrade -i cso \
-n cso-system \
--create-namespace \
oci://registry.scs.community/cluster-stacks/cso \
--set clusterStackVariables.ociRepository=registry.scs.community/kaas/cluster-stacks

kubectl create namespace cluster
```

clusterstack.yaml

```yaml
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: docker
  namespace: cluster
spec:
  provider: docker
  name: scs
  kubernetesVersion: "1.30"
  channel: custom
  autoSubscribe: false
  noProvider: true
  versions:
    - v0-sha.rwvgrna
```

Check if ClusterClasses exist

```sh
kubectl get clusterclass -n cluster
```

cluster.yaml

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: docker-testcluster
  namespace: cluster
  labels:
    managed-secret: cloud-config
spec:
  topology:
    class: docker-scs-1-30-v0-sha.rwvgrna
    controlPlane:
      replicas: 1
    version: v1.30.10
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 1
```

```sh
clusterctl get kubeconfig -n cluster docker-testcluster > /tmp/kubeconfig
kubectl get nodes --kubeconfig /tmp/kubeconfig
```
