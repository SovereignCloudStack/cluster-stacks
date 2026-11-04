# Versioning

## Per Kubernetes minor version

Every Kubernetes minor version of a stack lives in its own, self-contained directory
(`providers/<provider>/<stack>/1-XX/`). There is no inheritance or sharing between minor versions.
This allows different ClusterClass API versions (CAPI `v1beta1` and `v1beta2`) and different addon versions per minor version.

> **Requirements:** The ClusterClasses of `openstack/scs` and `docker/scs` use `cluster.x-k8s.io/v1beta2`. They require
> Cluster API >= 1.11 in the management cluster and a Cluster Stack Operator that supports it
> ([cluster-stack-operator#346](https://github.com/SovereignCloudStack/cluster-stack-operator/pull/346)).
> `openstack/scs2` and `openstack/hcp` still use `v1beta1`.
>
> **Kubernetes 1.36** additionally needs Cluster API **>= 1.12.8** (1.12 line) or **>= 1.13.1**. Older Cluster API versions
> set the kubeadm feature gate `ControlPlaneKubeletLocalMode` for every control plane, which was removed in Kubernetes
> 1.36. `kubeadm init` then fails (`featureGates: ... ControlPlaneKubeletLocalMode is not a valid feature name`), the
> control plane never becomes ready and the machine health check replaces the server again and again.

The name of a ClusterClass / release contains the Kubernetes minor version and the version of the cluster stack:

```
openstack-scs-1-35-v3
   |       |   |    |
   |       |   |    +-- cluster stack version, incremented for every release
   |       |   +------- Kubernetes minor version (1.35)
   |       +----------- cluster stack
   +------------------- provider
```

## Breaking changes

The Cluster Stack Operator does not allow to change the ClusterStack of an existing cluster. Clusters can only be
upgraded to newer versions of **the same** ClusterStack. A new cluster stack (e.g. `scs3`) is therefore only created if two
variants are supposed to be maintained in parallel.

Changes of the configuration (new or changed variables, different defaults) that would break existing clusters are
introduced with a **new Kubernetes minor version** of the stack. Within a minor version only patch releases of Kubernetes,
addon updates and compatible changes are released.

## Cluster stacks

| Cluster stack | Status | Notes |
|---|---|---|
| `openstack/scs` | maintained | Unified variables (`flavor`, `rootDisk`, ...), the stack to use. `1-32` is the stack as it was released before (`v1beta1`, variables like `cloud_name` and `ssh_key`), it is frozen and not changed anymore, the new variables start with `1-33` |
| `openstack/hcp` | maintained | Hosted control plane, only worker nodes are created as OpenStack servers |
| `docker/scs` | maintained | For development and testing with the Docker provider |
| `openstack/scs2` | deprecated | Separate `controlPlane*` / `worker*` variables. Only maintained, will be phased out. Migrate with `hack/migrate-cluster.sh` |
