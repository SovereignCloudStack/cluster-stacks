# Quickstart

This quickstart guide contains steps to install the [Cluster Stack Operator][CSO] (CSO) to provide [ClusterClasses][ClusterClass] which can be used with the [Kubernetes Cluster API][CAPI] to create Kubernetes Clusters.

This section guides you through all the necessary steps to create a workload Kubernetes cluster on top of the Hetzner baremetal infrastructure. The guide describes a path that utilizes the `clusterctl` CLI tool to manage the lifecycle of a CAPI management cluster and employs `kind` to create a local non-production management cluster.

Note that it is a common practice to create a temporary, local [bootstrap cluster](https://cluster-api.sigs.k8s.io/reference/glossary#bootstrap-cluster) which is then used to provision a target [management cluster](https://cluster-api.sigs.k8s.io/reference/glossary#management-cluster) on the selected infrastructure.

## Prerequisites

- Install [Docker](https://docs.docker.com/get-docker/) and [kind](https://kind.sigs.k8s.io/#installation-and-usage)
- Install [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- Install [clusterctl](https://cluster-api.sigs.k8s.io/user/quick-start.html#install-clusterctl)
- Install [go](https://go.dev/doc/install)

## Initialize the management cluster

Create the kind cluster:

```bash
kind create cluster
```

Transform the Kubernetes cluster into a management cluster by using `clusterctl init` and bootstrap it with CAPI and Cluster API Provider Hetzner ([CAPH][CAPH]) components:

```bash
export CLUSTER_TOPOLOGY=true
export EXP_RUNTIME_SDK=true
clusterctl init --infrastructure hetzner
```

### CSO variables preparation

The CSO must be directed to the Cluster Stacks repository housing releases for the Hetzner provider.
Modify and export the following environment variables if you wish to redirect CSO to an alternative Git repository.

Be aware that GitHub enforces limitations on the number of API requests per unit of time. To overcome this,
it is recommended to configure a [personal access token](https://github.com/settings/personal-access-tokens/new) for authenticated calls. This will significantly increase the rate limit for GitHub API requests.
Fine grained PAT with `Public Repositories (read-only)` is enough.

```bash
export GIT_PROVIDER_B64=Z2l0aHVi  # github
export GIT_ORG_NAME_B64=U292ZXJlaWduQ2xvdWRTdGFjaw== # SovereignCloudStack
export GIT_REPOSITORY_NAME_B64=Y2x1c3Rlci1zdGFja3M=  # cluster-stacks
export GIT_ACCESS_TOKEN_B64=$(echo -n '<my-personal-access-token>' | base64 -w0)
```

### CSO deployment

Install the [envsubst](https://github.com/drone/envsubst) Go package. It is required to enable the expansion of variables specified in CSO manifests.

```bash
GOBIN=/tmp go install github.com/drone/envsubst/v2/cmd/envsubst@latest
```

Get the latest CSO release version and apply CSO manifests to the management cluster.

```bash
# Get the latest CSO release version and apply CSO manifests
curl -sSL https://github.com/SovereignCloudStack/cluster-stack-operator/releases/latest/download/cso-infrastructure-components.yaml | /tmp/envsubst | kubectl apply -f -
```

## Create Cluster Stack definition

Configure the Cluster Stack you want to use:

```sh
# the name of the cluster stack (must match a name of a directory in https://github.com/SovereignCloudStack/cluster-stacks/tree/main/providers/hetzner)
export CS_NAME=baremetal

# the kubernetes version of the cluster stack (must match a tag for the kubernetes version and the stack version)
export CS_K8S_VERSION=1.30

# the version of the cluster stack (must match a tag for the kubernetes version and the stack version)
export CS_VERSION=v0-sha.e21ba15
export CS_CHANNEL=custom
```

This will use the cluster-stack as defined in the `providers/hetzner/baremetal` directory.

```bash
cat > clusterstack.yaml <<EOF
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: clusterstack
spec:
  provider: hetzner
  name: ${CS_NAME}
  kubernetesVersion: "${CS_K8S_VERSION}"
  channel: ${CS_CHANNEL}
  autoSubscribe: false
  noProvider: true
  versions:
  - ${CS_VERSION}
EOF

kubectl apply -f clusterstack.yaml
```

```
clusterstack.clusterstack.x-k8s.io/clusterstack created
```

## Create the workload cluster

### Hetzner account preparation

```bash
# hcloud api token with read and write access and robot web service user credentials
export HCLOUD_TOKEN=<my-hcloud-api-token>
export HETZNER_ROBOT_USER=<my-robot-webservice-user>
export HETZNER_ROBOT_PASSWORD=<my-robot-webservice-password>
```
```bash
kubectl create secret generic hetzner --from-literal=hcloud=$HCLOUD_TOKEN --from-literal=robot-user=$HETZNER_ROBOT_USER --from-literal=robot-password=$HETZNER_ROBOT_PASSWORD
kubectl patch secret hetzner -p '{"metadata":{"labels":{"clusterctl.cluster.x-k8s.io/move":""}}}'
```

```bash
# CAPH will upload the ssh key and provision baremetal servers with this key
export SSH_KEY_NAME=cluster
export HETZNER_SSH_PUB_PATH=/path/to/file/<ssh-key-name>.pub
export HETZNER_SSH_PRIV_PATH=/path/to/file/<ssh-key-name>
```
```bash
kubectl create secret generic robot-ssh --from-literal=sshkey-name=$SSH_KEY_NAME --from-file=ssh-privatekey=$HETZNER_SSH_PRIV_PATH --from-file=ssh-publickey=$HETZNER_SSH_PUB_PATH
kubectl patch secret robot-ssh -p '{"metadata":{"labels":{"clusterctl.cluster.x-k8s.io/move":""}}}'
```

```bash
$ kubectl get secret --show-labels 
NAME        TYPE     DATA   AGE   LABELS
hetzner     Opaque   3      10m   clusterctl.cluster.x-k8s.io/move=
robot-ssh   Opaque   3      53s   clusterctl.cluster.x-k8s.io/move=
```

### Create Host Object In Management Cluster

For using baremetal servers as nodes, you need to create a `HetznerBareMetalHost` object for each bare metal server that you bought and specify its server ID in the specs.
Below is a sample manifest for one HetznerBareMetalHost object later used as a control plane and one HetznerBareMetalHost object later used as a worker:
```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HetznerBareMetalHost
metadata:
  name: "cp0"
  labels:
    type: control-plane
spec:
  description: CAPH BareMetal Server
  serverID: <ID-of-your-server> # please check robot console
  rootDeviceHints:
    raid:
      wwn: # lsblk --nodeps --output name,type,wwn
      - <wwn1>
      - <wwn2>
  maintenanceMode: false
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HetznerBareMetalHost
metadata:
  name: "w0"
  labels:
    type: worker
spec:
  description: CAPH BareMetal Server
  serverID: <ID-of-your-server> # please check robot console
  rootDeviceHints:
    wwn: <wwn> # lsblk --nodeps --output name,type,wwn
  maintenanceMode: false
```

```bash
$ kubectl get hetznerbaremetalhost --show-labels
NAME  PHASE   IPV4   IPV6   MAINTENANCE   CPU   RAM   HETZNERBAREMETALMACHINE   AGE     REASON   MESSAGE   LABELS
cp0                         false                                               2m18s                      type=control-plane
w0                          false                                               2m18s                      type=worker
```

### Workload cluster

To create a workload cluster you must configure the following things:

```bash
export CS_CLUSTER_NAME=cs-cluster
# Note: if you need more than one POD_CIDR, please adjust the yaml file accordingly
export CS_POD_CIDR=192.168.0.0/16
# Note: if you need more than one SERVICE_CIDR, please adjust the yaml file accordingly
export CS_SERVICE_CIDR=10.96.0.0/12
export CS_CLASS_NAME=hetzner-"${CS_NAME}"-"${CS_K8S_VERSION/./-}"-"${CS_VERSION}"
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
    - name: bareMetalControlPlaneRaidEnabled # HetznerBareMetalHost is configured with RAID
      value: true
    - name: bareMetalControlPlaneHostSelector
      value:
        matchLabels:
          type: control-plane
    class: ${CS_CLASS_NAME}
    controlPlane:
      replicas: 1
    version: v${CS_K8S_VERSION}.${CS_K8S_PATCH_VERSION}
    workers:
      machineDeployments:
      - class: baremetal-worker
        name: md-0
        replicas: 1
        variables:
          overrides:
          - name: bareMetalWorkerHostSelector
            value:
              matchLabels:
                type: worker
EOF

kubectl apply -f cluster.yaml
```

```
cluster.cluster.x-k8s.io/cs-cluster created
```

Utilize a convenient CLI `clusterctl` to investigate the health of the cluster:

```bash
$ clusterctl describe cluster ${CS_CLUSTER_NAME}
NAME                                                       READY  SEVERITY  REASON                       SINCE  MESSAGE                                                       
Cluster/cs-cluster                                         True                                          9m16s                                                                 
├─ClusterInfrastructure - HetznerCluster/cs-cluster-54tc2  True                                          9m16s                                                                 
├─ControlPlane - KubeadmControlPlane/cs-cluster-vffsd      True                                          9m18s                                                                 
│ └─Machine/cs-cluster-vffsd-qvdjz                         True                                          9m19s                                                                 
└─Workers                                                                                                                                                                      
  └─MachineDeployment/cs-cluster-md-0-b9sl6                False  Warning   WaitingForAvailableMachines  23m    Minimum availability requires 1 replicas, current 0 available  
    └─Machine/cs-cluster-md-0-b9sl6-hbhg4-f9xnl            True
```

Fix providerID incompatibility, until https://github.com/hetznercloud/hcloud-cloud-controller-manager/issues/702 is resolved:

```bash
KUBE_EDITOR="sed -i 's#hcloud://bm-#hrobot://#'" kubectl edit hetznerbaremetalmachine
```

Once the cluster is provisioned and in good health, you can retrieve its kubeconfig and establish communication with the newly created workload cluster:

```bash
# Get the workload cluster kubeconfig
clusterctl get kubeconfig ${CS_CLUSTER_NAME} > kubeconfig.yaml
# Communicate with the workload cluster
kubectl --kubeconfig kubeconfig.yaml get nodes
```

## Check the workload cluster health

```bash
$ kubectl --kubeconfig kubeconfig.yaml get pods -A
NAMESPACE     NAME                                                READY   STATUS    RESTARTS      AGE
kube-system   cilium-operator-597fcffd95-pq4ws                    1/1     Running   0             13m
kube-system   cilium-operator-597fcffd95-w5qsf                    1/1     Running   0             13m
kube-system   cilium-q8tj7                                        1/1     Running   0             7m2s
kube-system   cilium-sv6v7                                        1/1     Running   0             13m
kube-system   coredns-7db6d8ff4d-tr2nw                            1/1     Running   0             13m
kube-system   coredns-7db6d8ff4d-zxf82                            1/1     Running   0             13m
kube-system   etcd-bm-cs-cluster-vffsd-qvdjz                      1/1     Running   0             13m
kube-system   hcloud-cloud-controller-manager-64dccb657f-fmffg    1/1     Running   1 (12m ago)   13m
kube-system   hubble-relay-5cb8db664-5hc7m                        1/1     Running   0             13m
kube-system   hubble-ui-57f6ffdcb5-67vl9                          2/2     Running   0             13m
kube-system   kube-apiserver-bm-cs-cluster-vffsd-qvdjz            1/1     Running   0             13m
kube-system   kube-controller-manager-bm-cs-cluster-vffsd-qvdjz   1/1     Running   0             13m
kube-system   kube-proxy-jnvx9                                    1/1     Running   0             13m
kube-system   kube-proxy-n2x9z                                    1/1     Running   0             7m2s
kube-system   kube-scheduler-bm-cs-cluster-vffsd-qvdjz            1/1     Running   0             13m
kube-system   metrics-server-59f544c997-bktv6                     1/1     Running   0             13m
```

[CAPI]: https://cluster-api.sigs.k8s.io/
[CAPH]: https://github.com/syself/cluster-api-provider-hetzner
[CSO]: https://github.com/SovereignCloudStack/cluster-stack-operator/
[ClusterClass]: https://github.com/kubernetes-sigs/cluster-api/blob/main/docs/proposals/20210526-cluster-class-and-managed-topologies.md
