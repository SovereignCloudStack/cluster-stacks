# Cluster Stacks

Cluster Stacks is a framework and for defining and managing Kubernetes clusters via the Cluster API. It spans 3 layers: node images, Cluster API cluster-classes and cluster addons. A bundle of those 3 layers is called a Cluster Stack. In this repo you can find several cluster-stacks with different addons bundled together.The components of a cluster-stack are tested to work well with each other, including Kubernetes version, operating system, cloud provider and the shipped addons.
More in-depth information about the concept of cluster-stacks can be found [here](docs/cluster-stacks.md).

## Quickstart

This section guides you through all the necessary steps to create a workload Kubernetes cluster on top of the OpenStack infrastructure. The guide describes a path that utilizes the `clusterctl` CLI tool to manage the lifecycle of a CAPI management cluster and employs `kind` to create a local non-production managemnt cluster.

Note that it is a common practice to create a temporary, local [bootstrap cluster](https://cluster-api.sigs.k8s.io/reference/glossary#bootstrap-cluster) which is then used to provision a target [management cluster](https://cluster-api.sigs.k8s.io/reference/glossary#management-cluster) on the selected infrastructure.

## Prerequisites

- Install [Docker](https://docs.docker.com/get-docker/) and [kind](https://helm.sh/docs/intro/install/)
- Install [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- Install [Helm](https://helm.sh/docs/intro/install/)
- Install [clusterctl](https://cluster-api.sigs.k8s.io/user/quick-start.html#install-clusterctl)
- Install [go](https://go.dev/doc/install) and the package [envsubst](https://github.com/drone/envsubst) is required to enable the expansion of variables specified in CSPO and CSO manifests.
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
export GIT_ACCESS_TOKEN_B64=$(echo -n '<my-github-access-token>' | base64 -w0)
```

### CSO and CSPO deployment (CSP)

Install the [envsubst](https://github.com/drone/envsubst) Go package. It is required to enable the expansion of variables specified in CSPO and CSO manifests.

```bash
GOBIN=/tmp go install github.com/drone/envsubst/v2/cmd/envsubst@latest
```

Get the latest CSO release version and apply CSO manifests to the management cluster.

```bash
# Get the latest CSO release version
CSO_VERSION=$(curl https://api.github.com/repos/SovereignCloudStack/cluster-stack-operator/releases/latest -s | jq .name -r)
# Apply CSO manifests
curl -sSL https://github.com/SovereignCloudStack/cluster-stack-operator/releases/download/${CSO_VERSION}/cso-infrastructure-components.yaml | /tmp/envsubst | kubectl apply -f -
```

Get the latest CSPO release version and apply CSPO manifests to the management cluster.

```bash
# Get the latest CSPO release version
CSPO_VERSION=$(curl https://api.github.com/repos/SovereignCloudStack/cluster-stack-provider-openstack/releases/latest -s | jq .name -r)
# Apply CSPO manifests
curl -sSL https://github.com/sovereignCloudStack/cluster-stack-provider-openstack/releases/download/${CSPO_VERSION}/cspo-infrastructure-components.yaml | /tmp/envsubst | kubectl apply -f -
```

### Deploy CSP-helper chart
The csp-helper chart is meant to create per tenant credentials as well as the tenants namespace where all resources for this tenant will live in. 

cloud and secret name default to `openstack`.

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
helm upgrade -i csp-helper-my-tenant -n my-tenant --create-namespace https://github.com/SovereignCloudStack/cluster-stacks/releases/download/openstack-csp-helper-v0.2.0/openstack-csp-helper.tgz -f path/to/clouds.yaml
```

## Create Cluster Stack definition (CSP/per tenant)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: clusterstack
  namespace: my-tenant
spec:
  provider: openstack
  name: alpha
  kubernetesVersion: "1.28"
  channel: stable
  autoSubscribe: false
  providerRef:
    apiVersion: infrastructure.clusterstack.x-k8s.io/v1alpha1
    kind: OpenStackClusterStackReleaseTemplate
    name: cspotemplate
  versions:
    - v3
---
apiVersion: infrastructure.clusterstack.x-k8s.io/v1alpha1
kind: OpenStackClusterStackReleaseTemplate
metadata:
  name: cspotemplate
  namespace: my-tenant
spec:
  template:
    spec:
      identityRef:
        kind: Secret
        name: openstack
EOF
```

```
clusterstack.clusterstack.x-k8s.io/clusterstack created
openstackclusterstackreleasetemplate.infrastructure.clusterstack.x-k8s.io/cspotemplate created
```

## Create the workload cluster resource (SCS-User/customer)

Create and apply `cluster.yaml` file to the management cluster:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: cs-cluster
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
    variables:
      - name: controller_flavor
        value: "SCS-2V-4-50"
      - name: worker_flavor
        value: "SCS-2V-4-50"
      - name: external_id
        value: "ebfe5546-f09f-4f42-ab54-094e457d42ec" # gx-scs
    class: openstack-alpha-1-28-v3
    controlPlane:
      replicas: 1
    version: v1.28.6
    workers:
      machineDeployments:
        - class: capi-openstack-alpha-1-28
          failureDomain: nova
          name: capi-openstack-alpha-1-28
          replicas: 3
EOF
```

```
cluster.cluster.x-k8s.io/cs-cluster created
```

Utilize a convenient CLI `clusterctl` to investigate the health of the cluster:

```bash
clusterctl -n my-tenant describe cluster cs-cluster
```

Once the cluster is provisioned and in good health, you can retrieve its kubeconfig and establish communication with the newly created workload cluster:

```bash
# Get the workload cluster kubeconfig
clusterctl -n my-tenant get kubeconfig cs-cluster > kubeconfig.yaml
# Communicate with the workload cluster
kubectl --kubeconfig kubeconfig.yaml get nodes
```

## Check the workload cluster health 

```bash
$ kubectl --kubeconfig kubeconfig.yaml get po -A
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
