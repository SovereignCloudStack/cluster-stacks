# SCS Cluster Stack

The SCS Cluster Stacks use the [Cluster API Provider Docker](https://github.com/kubernetes-sigs/cluster-api/blob/main/test/infrastructure/docker/README.md) for developing.

SCS Cluster Stacks should be compatible with all [Infrastructure Providers](https://cluster-api.sigs.k8s.io/reference/providers.html#infrastructure).

## Setting up a workload cluster

`make create-workload-cluster` will:

* Install [kind](https://kind.sigs.k8s.io/) and other tools in hack/tools/bin
* Create a kind cluster with the name "scs-cluster-stacks"
* Install Cluster API
* Install CAPD (Cluster API Provider Docker)
* Create a management cluster
* Create the [Cluster Class](https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-class/)
* Create a workload cluster

If everything works fine, the output is roughly like this:

```
❯ make create-workload-cluster
./hack/kind-dev.sh
+ K8S_VERSION=v1.27.2
++ git rev-parse --show-toplevel
+ REPO_ROOT=/home/myuser/projects/scs-cluster-stacks
+ cd /home/myuser/projects/scs-cluster-stacks
+ echo ''

+ echo 'Cluster initialising... Please hold on'
Cluster initialising... Please hold on
+ echo ''

+ ctlptl_kind-cluster scs-cluster-stacks v1.27.2
+ local CLUSTER_NAME=scs-cluster-stacks
+ local CLUSTER_VERSION=v1.27.2
+ cat
+ ctlptl apply -f -
registry.ctlptl.dev/scs-cluster-stacks-registry created
Creating cluster "scs-cluster-stacks" ...
 ✓ Ensuring node image (kindest/node:v1.27.2) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-scs-cluster-stacks"
You can now use your cluster with:

kubectl cluster-info --context kind-scs-cluster-stacks

Not sure what to do next? 😅  Check out https://kind.sigs.k8s.io/docs/user/quick-start/
Switched to context "kind-scs-cluster-stacks".
 🔌 Connected cluster kind-scs-cluster-stacks to registry scs-cluster-stacks-registry at localhost:5000
 👐 Push images to the cluster like 'docker push localhost:5000/alpine'
cluster.ctlptl.dev/kind-scs-cluster-stacks created
kubectl config set-context --current --namespace scs-cs
Context "kind-scs-cluster-stacks" modified.
EXP_RUNTIME_SDK=true CLUSTER_TOPOLOGY=true DISABLE_VERSIONCHECK="true" /home/myuser/projects/scs-cluster-stacks/hack/tools/bin/clusterctl init --core cluster-api:v1.5.1 --bootstrap kubeadm:v1.5.1 --control-plane kubeadm:v1.5.1
Fetching providers
Installing cert-manager Version="v1.12.3"
Waiting for cert-manager to be available...
Installing Provider="cluster-api" Version="v1.5.1" TargetNamespace="capi-system"
Installing Provider="bootstrap-kubeadm" Version="v1.5.1" TargetNamespace="capi-kubeadm-bootstrap-system"
Installing Provider="control-plane-kubeadm" Version="v1.5.1" TargetNamespace="capi-kubeadm-control-plane-system"

Your management cluster has been initialized successfully!

You can now create your first workload cluster by running the following:

  clusterctl generate cluster [name] --kubernetes-version [version] | kubectl apply -f -

# kubectl apply -f https://github.com/kubernetes-sigs/cluster-api-addon-provider-helm/releases/download//add-on-components.yaml
kubectl wait -n cert-manager deployment cert-manager --for=condition=Available --timeout=300s
deployment.apps/cert-manager condition met
kubectl wait -n capi-kubeadm-bootstrap-system deployment capi-kubeadm-bootstrap-controller-manager --for=condition=Available --timeout=300s
deployment.apps/capi-kubeadm-bootstrap-controller-manager condition met
kubectl wait -n capi-kubeadm-control-plane-system deployment capi-kubeadm-control-plane-controller-manager --for=condition=Available --timeout=300s
deployment.apps/capi-kubeadm-control-plane-controller-manager condition met
kubectl wait -n capi-system deployment capi-controller-manager --for=condition=Available --timeout=300s
deployment.apps/capi-controller-manager condition met
# hangs for ever waiting for cert-manger to get available if called twice.
if kubectl get deployments.apps -n capd-system capd-controller-manager > /dev/null 2>&1; then \
    echo "capd is already installed" ; \
else \
    echo "installing capd" ; \
        DISABLE_VERSIONCHECK="true" /home/myuser/projects/scs-cluster-stacks/hack/tools/bin/clusterctl init --infrastructure docker:v1.5.1; \
fi
installing capd
Fetching providers
Skipping installing cert-manager as it is already installed
Installing Provider="infrastructure-docker" Version="v1.5.1" TargetNamespace="capd-system"
kubectl wait -n capd-system deployment capd-controller-manager --for=condition=Available --timeout=300s
deployment.apps/capd-controller-manager condition met
kubectl create namespace scs-cs --dry-run=client -o yaml | kubectl apply -f -
namespace/scs-cs created
/home/myuser/projects/scs-cluster-stacks/hack/tools/bin/helm package providers/docker/ferrol/1-27/cluster-addon -d .helm
Successfully packaged chart and saved it to: .helm/docker-ferrol-1-27-v1.tgz
/home/myuser/projects/scs-cluster-stacks/hack/tools/bin/helm -n scs-cs template docker-ferrol-1-27 \
    providers/docker/ferrol/1-27/cluster-class | kubectl -n scs-cs apply -f -
clusterclass.cluster.x-k8s.io/docker-ferrol-1-27-v1 created
dockerclustertemplate.infrastructure.cluster.x-k8s.io/docker-ferrol-1-27-v1-cluster created
dockermachinetemplate.infrastructure.cluster.x-k8s.io/docker-ferrol-1-27-v1-machinetemplate-docker created
kubeadmconfigtemplate.bootstrap.cluster.x-k8s.io/docker-ferrol-1-27-v1-worker-bootstraptemplate-docker created
kubeadmcontrolplanetemplate.controlplane.cluster.x-k8s.io/docker-ferrol-1-27-v1-control-plane created
# create the docker image. Start first build in background to
docker build -t docker-ferrol-1-27-controlplaneamd64-v1:dev \
    --file providers/docker/ferrol/1-27/node-images/Dockerfile.controlplane \
     providers/docker/ferrol/1-27/node-images/ & \
  docker build -t docker-ferrol-1-27-workeramd64-v1:dev \
  --file providers/docker/ferrol/1-27/node-images/Dockerfile.worker \
  providers/docker/ferrol/1-27/node-images/
[+] Building ...
 => => writing image sha256:e86e490149f0d6b32dda7843a08cade8fd29c1cf870c44738b0308c6a151d38f                                                            0.0s
 => => naming to docker.io/library/docker-ferrol-1-27-workeramd64-v1:dev                                                                                0.0s

Done
cat providers/docker/ferrol/1-27/topology-docker.yaml | /home/myuser/projects/scs-cluster-stacks/hack/tools/bin/envsubst - > build/topology.yaml
kubectl apply -f build/topology.yaml
cluster.cluster.x-k8s.io/cs-cluster created
# Wait for the kubeconfig to become available.
/usr/bin/timeout 5m bash -c "while ! kubectl -n scs-cs get secrets | grep cs-cluster-kubeconfig; do date; echo waiting for secret cs-cluster-kubeconfig; sleep 1; done"
Mo 11. Sep 13:03:50 CEST 2023
waiting for secret cs-cluster-kubeconfig
Mo 11. Sep 13:03:51 CEST 2023
waiting for secret cs-cluster-kubeconfig
cs-cluster-kubeconfig    cluster.x-k8s.io/secret   1      1s
# Get kubeconfig and store it locally.
kubectl -n scs-cs get secrets cs-cluster-kubeconfig -o json | jq -r .data.value | base64 --decode > .kubeconfigs/.cs-cluster-kubeconfig
if [ ! -s ".kubeconfigs/.cs-cluster-kubeconfig" ]; then echo "failed to create .kubeconfigs/.cs-cluster-kubeconfig"; exit 1; fi
/usr/bin/timeout 15m bash -c "while ! kubectl --kubeconfig=.kubeconfigs/.cs-cluster-kubeconfig -n scs-cs get nodes | grep control-plane; do sleep 1; done"
E0911 13:04:05.596836 2490994 memcache.go:265] couldn't get current server API group list: Get "https://172.18.0.7:6443/api?timeout=32s": EOF
E0911 13:04:15.604868 2490994 memcache.go:265] couldn't get current server API group list: Get "https://172.18.0.7:6443/api?timeout=32s": EOF
E0911 13:04:25.611916 2490994 memcache.go:265] couldn't get current server API group list: Get "https://172.18.0.7:6443/api?timeout=32s": EOF
error: the server doesn't have a resource type "nodes"
No resources found
No resources found
cs-cluster-8z9c8-jv45h   NotReady   control-plane   2s    v1.27.3

Access to API server successful.
```

To make your workload cluster functional you need to install the cluster addons:

```
make install-addons-in-workload-cluster
```

This will install:

* CNI: kindnet
* metrics-server

You can check the conditions of all resources with this tool:

```
go run github.com/guettli/check-conditions@latest all
```

It takes some time until all conditions unhealthy conditions are resolved.


## Access to Workload Cluster

The kubeconfig for accessing the workload cluster is in the file ``.kubeconfigs/.cs-cluster-kubeconfig`.

You can export this variable, so that `kubectl` will use this file.

```
export KUBECONFIG=.kubeconfigs/.cs-cluster-kubeconfig
```

## Testing Reconciling

To test the reconciling you can change the number of replicas:

```
kubectl edit cluster cs-cluster
```

Your configured editor opens and you can change the value for "replicas" in the yaml file.

There are two places: The first "replicas" is for the number of control planes.
The second is for the number of worker nodes.

After you saved the file the reconciling of cluster-api changes the number of replicas.

You can observe your changes with:

```
watch kubectl get machines
```

## Checking Metrics Server

The cluster addon metrics server gets installed in the workloadcluster.

You can check the resource (CPU/Memory) usage like this:
```
❯ KUBECONFIG=.kubeconfigs/.cs-cluster-kubeconfig kubectl top nodes  cs-cluster-YOUR-ID

NAME                     CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
cs-cluster-7rwpz-8gfrb   73m          0%     602Mi           1%
```

## Delete Workload Cluster

To delete the workload cluster, delete the corresponding resource:

```
kubectl delete cluster cs-cluster
```

## Delete Management Cluster

There is a Makefile target for this:

```
make delete-mgt-cluster
```

## Troubleshooting

Be sure to connect to the matching cluster.

* Use `.mgt-cluster-kubeconfig.yaml` for the management cluster (Kind cluster)
* Use `.cs-cluster-kubeconfig` for the workload cluster.

Set environment variable `KUBECONFIG` accordingly.

### Check latest Events

To see the latest events use:

```
kubectl get events --sort-by=.lastTimestamp -A
```

### Check all conditions

You can check all conditions of all resources in the cluster with this tool:

```
go run github.com/guettli/check-conditions@latest all
```

The output will be:

```
NAMESPACE RESOURCE NAME Condition ...
```

Example output while scaling from one control plane to three:

```
❯ go run github.com/guettli/check-conditions@latest all
  scs-cs clusters cs-cluster Condition Ready=False ScalingUp "Scaling up control plane to 3 replicas (actual 2)"
  scs-cs clusters cs-cluster Condition ControlPlaneReady=False ScalingUp "Scaling up control plane to 3 replicas (actual 2)"
  scs-cs kubeadmcontrolplanes cs-cluster-66mht Condition Ready=False ScalingUp "Scaling up control plane to 3 replicas (actual 2)"
  scs-cs kubeadmcontrolplanes cs-cluster-66mht Condition MachinesReady=False WaitingForBootstrapData @ /cs-cluster-66mht-zxq4k "1 of 2 completed"
  scs-cs kubeadmcontrolplanes cs-cluster-66mht Condition Resized=False ScalingUp "Scaling up control plane to 3 replicas (actual 2)"
  scs-cs machines cs-cluster-66mht-zxq4k Condition Ready=False Bootstrapping "1 of 2 completed"
  scs-cs machines cs-cluster-66mht-zxq4k Condition InfrastructureReady=False Bootstrapping "1 of 2 completed"
  scs-cs machines cs-cluster-66mht-zxq4k Condition NodeHealthy=False WaitingForNodeRef ""
  scs-cs dockermachines cs-cluster-control-plane-b9b82-7kwjq Condition Ready=False Bootstrapping "1 of 2 completed"
  scs-cs dockermachines cs-cluster-control-plane-b9b82-7kwjq Condition BootstrapExecSucceeded=False Bootstrapping ""
Checked 209 conditions of 796 resources of 75 types. Duration: 118.329196ms
```

### Orphaned Docker Containers

If you are using the Cluster API Docker provider, it is likely that orphaned containers keep on 
running on your machine. This can happen if you delete a kind (management) cluster, without deleting
the workload cluster first.

You can check with `docker ps` which containers are running. You can delete orphaned containers with `docker rm -f CONTAINER_ID`.

