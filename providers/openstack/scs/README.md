# Cluster Stacks

## Getting started

```sh
# Create bootstrap cluster
kind create cluster

# Init Cluster API
export CLUSTER_TOPOLOGY=true
export EXP_CLUSTER_RESOURCE_SET=true
export EXP_RUNTIME_SDK=true
kubectl apply -f https://github.com/k-orc/openstack-resource-controller/releases/latest/download/install.yaml
clusterctl init --infrastructure openstack

kubectl -n capi-system rollout status deployment
kubectl -n capo-system rollout status deployment

```

values.yaml

```
clusterStackVariables:
  ociRepository: registry.scs.community/kaas/cluster-stacks
controllerManager:
  rbac:
    additionalRules:
      - apiGroups:
          - "openstack.k-orc.cloud"
        resources:
          - "images"
        verbs:
          - create
          - delete
          - get
          - list
          - patch
          - update
          - watch
```

```
# Install CSO and CSPO
helm upgrade -i cso \
-n cso-system \
--create-namespace \
oci://registry.scs.community/cluster-stacks/cso \
--values values.yaml

kubectl create namespace cluster
```

```
# Add secret using csp-helper chart
helm upgrade -i openstack-secrets -n cluster --create-namespace https://github.com/SovereignCloudStack/openstack-csp-helper/releases/latest/download/openstack-csp-helper.tgz -f <PATH TO CLOUDS YAML>
```

```sh
cat <<EOF | kubectl apply -f -
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: openstack
  namespace: cluster
spec:
  provider: openstack
  name: scs
  kubernetesVersion: "1.30"
  channel: stable
  autoSubscribe: false
  noProvider: true
  versions:
    - v2
EOF
```

Check if ClusterClasses exist

```sh
kubectl get clusterclass -n cluster
```

cluster.yaml

```sh
cat <<EOF | kubectl apply -f -
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: my-cluster
  namespace: cluster
  labels:
    managed-secret: cloud-config
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
    class: openstack-scs-1-31-v2
    controlPlane:
      replicas: 1
    version: v1.30.11
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 1
EOF
```

```sh
clusterctl get kubeconfig -n cluster openstack-testcluster > /tmp/kubeconfig
kubectl get nodes --kubeconfig /tmp/kubeconfig
```
