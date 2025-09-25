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

```
# Install CSO and CSPO
helm upgrade -i cso \
-n cso-system \
--create-namespace \
oci://registry.scs.community/cluster-stacks/cso
```

```sh
export CLUSTER_NAMESPACE=cluster
export CLUSTER_NAME=my-cluster
export CLUSTERSTACK_NAMESPACE=cluster
export CLUSTERSTACK_VERSION=v1
export OS_CLIENT_CONFIG_FILE=${PWD}/clouds.yaml
kubectl create namespace $CLUSTER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
```

```sh
# Create secret for CAPO
kubectl create secret -n $CLUSTER_NAMESPACE generic openstack --from-file=clouds.yaml=$OS_CLIENT_CONFIG_FILE --dry-run=client -oyaml | kubectl apply -f -

# Prepare the Secret as it will be deployed in the Workload Cluster
kubectl create secret -n kube-system generic clouds-yaml --from-file=clouds.yaml=$OS_CLIENT_CONFIG_FILE --dry-run=client -oyaml > clouds-yaml-secret

# Add the Secret to the ClusterResourceSet Secret in the Management Cluster
kubectl create -n $CLUSTER_NAMESPACE secret generic clouds-yaml --from-file=clouds-yaml-secret --type=addons.cluster.x-k8s.io/resource-set --dry-run=client -oyaml | kubectl apply -f -
```

```yaml
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

```sh
# Apply ClusterStack resource
cat <<EOF | kubectl apply -f -
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: openstack
  namespace: $CLUSTERSTACK_NAMESPACE
spec:
  provider: openstack
  name: scs2
  kubernetesVersion: "1.33"
  channel: stable
  autoSubscribe: false
  noProvider: true
  versions:
    - $CLUSTERSTACK_VERSION
EOF
```

```sh
# Apply Cluster resource
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
    variables:
    class: openstack-scs2-1-33-$CLUSTERSTACK_VERSION
    classNamespace: $CLUSTERSTACK_NAMESPACE
    controlPlane:
      replicas: 1
    version: v1.33.4
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 1
EOF
```

```sh
clusterctl get kubeconfig -n $CLUSTER_NAMESPACE openstack-testcluster > /tmp/kubeconfig
kubectl get nodes --kubeconfig /tmp/kubeconfig
```
