# Cluster Stacks

## Getting started

At first you need a Ready installed Rancher Management Dashboard (without any existing Downstreamclusters installed via custom-cluster. The cso will breake the management).

For Rancher Version < 2.13 you must install the Rancher Turtles to open the preinstalled capi. https://ranchermanager.docs.rancher.com/integrations-in-rancher/cluster-api/overview

For Rancher Version >= 2.13 the Rancher Turtles is preinstalled and enabled by default. Only the Rancher Turtles UI must be installed sepratly. https://turtles.docs.rancher.com/turtles/v0.24/en/tutorials/quickstart.html#_capi_ui_extension_installation

Now you must install following providers (via GUI Cluster Management > CAPI > Provider > Create)

|Key|Value bootstrap|Value controlplane|Value infrastructure|
|---|---|---|--|
|Namespace|rke2-bootstrap|rke2-controlplane|capo-system|
|Name|rke2-bootstrap|rke2-controlplane|infrastructure-openstack|
|Provider|rke2|rke2|openstack|
|Provider type|bootstrap|controlPlane|infrastructure|
|Features Enable cluster resource set|yes|yes|yes|
|Features Enable cluster topology|yes|yes|yes|
|Features Enable machine pool|yes|yes|yes|
|Variables|EXP_RUNTIME_SDK=true|EXP_RUNTIME_SDK=true|EXP_RUNTIME_SDK=true|



```sh
# Init openstack resource controller
kubectl apply -f https://github.com/k-orc/openstack-resource-controller/releases/latest/download/install.yaml

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
export CLUSTERSTACK_VERSION=v6
export OS_CLIENT_CONFIG_FILE=${PWD}/clouds.yaml
kubectl create namespace $CLUSTER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace $CLUSTER_NAMESPACE cluster-api.cattle.io/rancher-auto-import=true
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
  name: rke2
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
      - name: clusterCNI
        value: "cilium" # also calicio is posible, but musst be manual patched after install: kubectl patch ippools.crd.projectcalico.org default-ipv4-ippool --type='json' -p '[{"op": "replace", "path": "/spec/ipipMode", "value":"CrossSubnet"}]'
      - name: apiServerLoadBalancer
        value: "octavia-ovn"
      - name: imageAddVersion
        value: false
      - name: imageName
        value: "Ubuntu 24.04"
      - name: workerFlavor
        value: "SCS-4V-8"
      - name: controlPlaneFlavor
        value: "SCS-4V-8"
      - name: bastionFlavor
        value: "SCS-2V-4"
      - name: bastionEnabled
        value: true
    class: openstack-rke2-1-33-$CLUSTERSTACK_VERSION
    classNamespace: $CLUSTERSTACK_NAMESPACE
    controlPlane:
      replicas: 1
    version: v1.33.6+rke2r1
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 1
EOF
```

```sh
clusterctl get kubeconfig -n $CLUSTER_NAMESPACE $CLUSTER_NAME > /tmp/kubeconfig
kubectl get nodes --kubeconfig /tmp/kubeconfig
# Enable rke2-ingress-loadbalancer
kubectl --kubeconfig /tmp/kubeconfig -n kube-system patch HelmChart.helm.cattle.io rke2-ingress-nginx --type='json' -p '[{"op": "add", "path": "/spec/set/'controller.service.enabled'", "value":"true"}]'
# Set rke2-ingress-loadbalancer-IP
kubectl --kubeconfig /tmp/kubeconfig -n kube-system patch HelmChart.helm.cattle.io rke2-ingress-nginx --type='json' -p '[{"op": "add", "path": "/spec/set/'controller.service.loadBalancerIP'", "value":"xxx.xxx.xxx.xxx"}]'

```
