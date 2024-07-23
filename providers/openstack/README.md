# Quickstart

This quickstart guide contains steps to install the [Cluster Stack Operator][CSO] (CSO) utilizing the [Cluster Stack Provider OpenStack][CSPO] (CSPO) to provide [ClusterClasses][ClusterClass] which can be used with the [Kubernetes Cluster API][CAPI] to create Kubernetes Clusters.

This section guides you through all the necessary steps to create a workload Kubernetes cluster on top of the OpenStack infrastructure. The guide describes a path that utilizes the `clusterctl` CLI tool to manage the lifecycle of a CAPI management cluster and employs `kind` to create a local non-production managemnt cluster.

Note that it is a common practice to create a temporary, local [bootstrap cluster](https://cluster-api.sigs.k8s.io/reference/glossary#bootstrap-cluster) which is then used to provision a target [management cluster](https://cluster-api.sigs.k8s.io/reference/glossary#management-cluster) on the selected infrastructure.

## Prerequisites

- Install [Docker](https://docs.docker.com/get-docker/) and [kind](https://helm.sh/docs/intro/install/)
- Install [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- Install [Helm](https://helm.sh/docs/intro/install/)
- Install [clusterctl](https://cluster-api.sigs.k8s.io/user/quick-start.html#install-clusterctl)
- Install [go](https://go.dev/doc/install)
- Install [jq](https://jqlang.github.io/jq/)

## Initialize the management cluster

Create the kind cluster:

```bash
kind create cluster
```

Transform the Kubernetes cluster into a management cluster by using `clusterctl init` and bootstrap it with CAPI and Cluster API Provider OpenStack ([CAPO](https://github.com/kubernetes-sigs/cluster-api-provider-openstack)) components:

```bash
export CLUSTER_TOPOLOGY=true
export EXP_CLUSTER_RESOURCE_SET=true
export EXP_RUNTIME_SDK=true
clusterctl init --infrastructure openstack
```

### CSO and CSPO variables preparation (CSP)

The CSO and CSPO must be directed to the Cluster Stacks repository housing releases for the OpenStack provider.
Modify and export the following environment variables if you wish to redirect CSO and CSPO to an alternative Git repository

Be aware that GitHub enforces limitations on the number of API requests per unit of time. To overcome this,
it is recommended to configure a [personal access token](https://github.com/settings/personal-access-tokens/new) for authenticated calls. This will significantly increase the rate limit for GitHub API requests.
Fine grained PAT with `Public Repositories (read-only)` is enough.

```bash
export GIT_PROVIDER_B64=Z2l0aHVi  # github
export GIT_ORG_NAME_B64=U292ZXJlaWduQ2xvdWRTdGFjaw== # SovereignCloudStack
export GIT_REPOSITORY_NAME_B64=Y2x1c3Rlci1zdGFja3M=  # cluster-stacks
export GIT_ACCESS_TOKEN_B64=$(echo -n '<my-personal-access-token>' | base64 -w0)
```

### CSO and CSPO deployment (CSP)

Install the [envsubst](https://github.com/drone/envsubst) Go package. It is required to enable the expansion of variables specified in CSPO and CSO manifests.

```bash
GOBIN=/tmp go install github.com/drone/envsubst/v2/cmd/envsubst@latest
```

Get the latest CSO release version and apply CSO manifests to the management cluster.

```bash
# Get the latest CSO release version and apply CSO manifests
curl -sSL https://github.com/SovereignCloudStack/cluster-stack-operator/releases/latest/download/cso-infrastructure-components.yaml | /tmp/envsubst | kubectl apply -f -
```

Get the latest CSPO release version and apply CSPO manifests to the management cluster.

```bash
# Get the latest CSPO release version and apply CSPO manifests
curl -sSL https://github.com/sovereignCloudStack/cluster-stack-provider-openstack/releases/latest/download/cspo-infrastructure-components.yaml | /tmp/envsubst | kubectl apply -f -
```

## Define a namespace for a tenant (CSP/per tenant)

```sh
export CS_NAMESPACE=my-tenant
```

### Deploy CSP-helper chart

The csp-helper chart is meant to create per tenant credentials as well as the tenants namespace where all resources for this tenant will live in.

Cloud and secret name default to `openstack`.

Example `clouds.yaml`

```yaml
clouds:
  openstack:
    auth:
      auth_url: https://api.gx-scs.sovereignit.cloud:5000/v3
      application_credential_id: ""
      application_credential_secret: ""
    region_name: "RegionOne"
    interface: "public"
    identity_api_version: 3
    auth_type: "v3applicationcredential"
```

```bash
helm upgrade -i csp-helper-"${CS_NAMESPACE}" -n "${CS_NAMESPACE}" --create-namespace https://github.com/SovereignCloudStack/openstack-csp-helper/releases/latest/download/openstack-csp-helper.tgz -f path/to/clouds.yaml
```

## Create Cluster Stack definition (CSP/per tenant)

Configure the Cluster Stack you want to use:

```sh
# the name of the cluster stack (must match a name of a directory in https://github.com/SovereignCloudStack/cluster-stacks/tree/main/providers/openstack)
export CS_NAME=alpha

# the kubernetes version of the cluster stack (must match a tag for the kubernetes version and the stack version)
export CS_K8S_VERSION=1.29

# the version of the cluster stack (must match a tag for the kubernetes version and the stack version)
export CS_VERSION=v2
export CS_CHANNEL=stable

# must match a cloud section name in the used clouds.yaml
export CS_CLOUDNAME=openstack
export CS_SECRETNAME="${CS_CLOUDNAME}"
```

This will use the cluster-stack as defined in the `providers/openstack/alpha` directory.

```bash
cat >clusterstack.yaml <<EOF
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: clusterstack
  namespace: ${CS_NAMESPACE}
spec:
  provider: openstack
  name: ${CS_NAME}
  kubernetesVersion: "${CS_K8S_VERSION}"
  channel: ${CS_CHANNEL}
  autoSubscribe: false
  providerRef:
    apiVersion: infrastructure.clusterstack.x-k8s.io/v1alpha1
    kind: OpenStackClusterStackReleaseTemplate
    name: cspotemplate
  versions:
    - ${CS_VERSION}
---
apiVersion: infrastructure.clusterstack.x-k8s.io/v1alpha1
kind: OpenStackClusterStackReleaseTemplate
metadata:
  name: cspotemplate
  namespace: ${CS_NAMESPACE}
spec:
  template:
    spec:
      identityRef:
        kind: Secret
        name: ${CS_SECRETNAME}
EOF

kubectl apply -f clusterstack.yaml
```

```
clusterstack.clusterstack.x-k8s.io/clusterstack created
openstackclusterstackreleasetemplate.infrastructure.clusterstack.x-k8s.io/cspotemplate created
```

## Create the workload cluster resource (SCS-User/customer)

To create a workload cluster you must configure the following things:

```bash
export CS_CLUSTER_NAME=cs-cluster
# Note: if you need more than one POD_CIDR, please adjust the yaml file accordingly
export CS_POD_CIDR=192.168.0.0/16
# Note: if you need more than one SERVICE_CIDR, please adjust the yaml file accordingly
export CS_SERVICE_CIDR=10.96.0.0/12
export CS_EXTERNAL_ID=ebfe5546-f09f-4f42-ab54-094e457d42ec # gx-scs
export CS_CLASS_NAME=openstack-"${CS_NAME}"-"${CS_K8S_VERSION/./-}"-"${CS_VERSION}"
export CS_K8S_PATCH_VERSION=3
```

Create and apply `cluster.yaml` file to the management cluster.

Depending on your cluster-class and cluster addons, some more variables may have to be provided in the `spec.topology.variables` list.
An error message after applying the `Cluster` resource will tell you if more variables are necessary.

```bash
cat > cluster.yaml <<EOF
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: ${CS_CLUSTER_NAME}
  namespace: ${CS_NAMESPACE}
  labels:
    managed-secret: cloud-config
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
        - ${CS_POD_CIDR}
    serviceDomain: cluster.local
    services:
      cidrBlocks:
        - ${CS_SERVICE_CIDR}
  topology:
    variables:
      - name: controller_flavor
        value: "SCS-2V-4-50"
      - name: worker_flavor
        value: "SCS-2V-4-50"
      - name: external_id
        value: ${CS_EXTERNAL_ID}
    class: ${CS_CLASS_NAME}
    controlPlane:
      replicas: 1
    version: v${CS_K8S_VERSION}.${CS_K8S_PATCH_VERSION}
    workers:
      machineDeployments:
        - class: default-worker
          failureDomain: nova
          name: default-worker
          replicas: 3
EOF

kubectl apply -f cluster.yaml
```

```
cluster.cluster.x-k8s.io/cs-cluster created
```

Utilize a convenient CLI `clusterctl` to investigate the health of the cluster:

```bash
clusterctl -n ${CS_NAMESPACE} describe cluster ${CS_CLUSTER_NAME}
```

Once the cluster is provisioned and in good health, you can retrieve its kubeconfig and establish communication with the newly created workload cluster:

```bash
# Get the workload cluster kubeconfig
clusterctl -n "${CS_NAMESPACE}" get kubeconfig ${CS_CLUSTER_NAME} > kubeconfig.yaml
# Communicate with the workload cluster
kubectl --kubeconfig kubeconfig.yaml get nodes
```

## Check the workload cluster health

```bash
$ kubectl --kubeconfig kubeconfig.yaml get pods -A
NAMESPACE     NAME                                                     READY   STATUS    RESTARTS   AGE
kube-system   cilium-8mzrx                                             1/1     Running   0          7m58s
kube-system   cilium-jdxqm                                             1/1     Running   0          6m43s
kube-system   cilium-operator-6bb4c7d6b6-c77tn                         1/1     Running   0          7m57s
kube-system   cilium-operator-6bb4c7d6b6-l2df8                         1/1     Running   0          7m58s
kube-system   cilium-p9tkv                                             1/1     Running   0          6m44s
kube-system   cilium-thbc8                                             1/1     Running   0          6m45s
kube-system   coredns-5dd5756b68-k68j4                                 1/1     Running   0          8m3s
kube-system   coredns-5dd5756b68-vjg9r                                 1/1     Running   0          8m3s
kube-system   etcd-cs-cluster-pwblg-xkptx                              1/1     Running   0          8m3s
kube-system   kube-apiserver-cs-cluster-pwblg-xkptx                    1/1     Running   0          8m3s
kube-system   kube-controller-manager-cs-cluster-pwblg-xkptx           1/1     Running   0          8m3s
kube-system   kube-proxy-54f8w                                         1/1     Running   0          6m44s
kube-system   kube-proxy-8z8kb                                         1/1     Running   0          6m43s
kube-system   kube-proxy-jht46                                         1/1     Running   0          8m3s
kube-system   kube-proxy-mt69p                                         1/1     Running   0          6m45s
kube-system   kube-scheduler-cs-cluster-pwblg-xkptx                    1/1     Running   0          8m3s
kube-system   metrics-server-6578bd6756-vztzf                          1/1     Running   0          7m57s
kube-system   openstack-cinder-csi-controllerplugin-776696786b-ksf77   6/6     Running   0          7m57s
kube-system   openstack-cinder-csi-nodeplugin-96dlg                    3/3     Running   0          6m43s
kube-system   openstack-cinder-csi-nodeplugin-crhc4                    3/3     Running   0          6m44s
kube-system   openstack-cinder-csi-nodeplugin-d7rzz                    3/3     Running   0          7m58s
kube-system   openstack-cinder-csi-nodeplugin-nkgq6                    3/3     Running   0          6m44s
kube-system   openstack-cloud-controller-manager-hp2n2                 1/1     Running   0          7m9s
```

[CAPI]: https://cluster-api.sigs.k8s.io/
[CSO]: https://github.com/sovereignCloudStack/cluster-stack-operator/
[CSPO]: https://github.com/SovereignCloudStack/cluster-stacks/tree/main/providers/openstack
[ClusterClass]: https://github.com/kubernetes-sigs/cluster-api/blob/main/docs/proposals/20210526-cluster-class-and-managed-topologies.md
