# Kamaji

## Prerequisites

- A CAPI management cluster in an environment which can be reached from external
  - Install CAPO, CSO and CSPO e.g. as described in [the openstack quickstart](./quickstart.md)

## Installation

### Kamaji Controller

[Kamaji Controller](https://kamaji.clastix.io/getting-started/#install-kamaji-controller)

### cluster-api-control-plane-provider-kamaji

`clusterctl init --control-plane kamaji`

### Cluster Stacks

```yaml
---
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: kamaji-130
spec:
  provider: openstack
  name: kamaji
  kubernetesVersion: "1.30"
  channel: custom
  autoSubscribe: false
  providerRef:
    apiVersion: infrastructure.clusterstack.x-k8s.io/v1alpha1
    kind: OpenStackClusterStackReleaseTemplate
    name: cspotemplate
  versions:
    - v0-sha.11930ee
```

### Cluster

```
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: kamaji-cluster
spec:
  topology:
    class: openstack-kamaji-1-30-v0-sha.11930ee
    variables:
      - name: data_store
        value: "default"
      - name: dns_service_ips
        value: ["10.96.0.10"]
    controlPlane:
      replicas: 3
    version: v1.30.1
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 1
```
