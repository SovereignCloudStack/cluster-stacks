# Cluster Stack openstack/scs2 (deprecated)

> **Deprecated:** `scs2` is only maintained (Kubernetes patch releases, addon updates) and will be phased out.
> New clusters should use the [`scs`](../scs) cluster stack, which will be the only maintained cluster stack.
> Note that the variables of `scs` differ from `scs2` (e.g. `flavor` / `rootDisk` instead of separate `controlPlane*` / `worker*` variables).

## Layout

Every Kubernetes minor version has its own self-contained directory (`1-33`, `1-34`, ...) containing the
`cluster-class` and `cluster-addon` charts, `clusteraddon.yaml` and `csctl.yaml`.
Breaking changes are introduced with a new minor version, so clusters can be upgraded within the same ClusterStack.

The node images of all minor versions are listed in `image-manager.yaml` in this directory
(maintained by `CLUSTER_STACK=scs2 just update versions`).

## Prerequisites

- kind
- kubectl
- helm
- clusterctl (v1.10x)

## Getting started


### Prepare a management Cluster using kind

```sh
# Create bootstrap cluster
kind create cluster

# Init Cluster API
export CLUSTER_TOPOLOGY=true
export EXP_CLUSTER_RESOURCE_SET=true
export EXP_RUNTIME_SDK=true
kubectl apply -f https://github.com/k-orc/openstack-resource-controller/releases/latest/download/install.yaml
clusterctl init --infrastructure openstack:v0.14.4

kubectl -n capi-system rollout status deployment
kubectl -n capo-system rollout status deployment
```

### Install the Cluster Stack Operator

```
helm upgrade -i cso \
-n cso-system \
--create-namespace \
oci://registry.scs.community/cluster-stacks/cso
```

### Prepare some environment variables for reuse

```sh
export CLUSTER_NAMESPACE=cluster
export CLUSTER_NAME=my-cluster
export CLUSTERSTACK_NAMESPACE=cluster
export CLUSTERSTACK_VERSION=v1
export K8S_MINOR=1.35                  # one of the directories next to this README, e.g. 1-35 for 1.35
export K8S_VERSION=v1.35.9             # see <minor>/versions.yaml
export OS_CLIENT_CONFIG_FILE=${PWD}/clouds.yaml
kubectl create namespace $CLUSTER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
```

### Add clouds.yaml as Secret

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

### Install the Cluster Stack resource

```sh
cat <<EOF | kubectl apply -f -
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: openstack
  namespace: $CLUSTERSTACK_NAMESPACE
spec:
  provider: openstack
  name: scs2
  kubernetesVersion: "$K8S_MINOR"
  channel: stable
  autoSubscribe: false
  noProvider: true
  versions:
    - $CLUSTERSTACK_VERSION
EOF
```

### Prepare the Node Images

These Cluster Stacks do not contain fixed image to make it possible to provide the images in different ways.  
Recommended is to add all images using the [Image Manager](https://docs.scs.community/docs/iaas/components/image-manager/) pointing to the file `image-manager.yaml` next to this README.
If you can't add images publicly you can change the visibility in the file to `private`. But in that case it's simpler to just apply an ORC `Image` manifest, which you can generate with
`PROVIDER=openstack CLUSTER_STACK=scs2 ./hack/generate-image-manifests.sh --version $K8S_MINOR | kubectl apply -f -`. Since the OpenStack Resource Controller is a dependency to ClusterAPI Provider OpenStack this will import the image in your project using the same clouds.yaml file from the `openstack` Secret.

### Apply the Cluster resource

```sh
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
    class: openstack-scs2-${K8S_MINOR//./-}-$CLUSTERSTACK_VERSION
    classNamespace: $CLUSTERSTACK_NAMESPACE
    controlPlane:
      replicas: 1
    version: $K8S_VERSION
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 1
EOF
```

### Get the Workload Cluster kubeconfig and try it

```sh
clusterctl get kubeconfig -n $CLUSTER_NAMESPACE openstack-testcluster > /tmp/kubeconfig
kubectl get nodes --kubeconfig /tmp/kubeconfig
```
