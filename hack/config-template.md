# Configuration

This page lists the custom configuration options available, including their default values and if they are optional. The following example shows how these variables can be used inside the `cluster.yaml` file under `spec.topology.variables`.

## Version matrix

!!matrix!!

## Example

```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: my-cluster
  namespace: my-namespace
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
    variables:   # <-- variables from the table below can be set here
      - name: flavor
        value: "SCS-4V-8-20"
      - name: networkExternalID
        value: "ebfe5546-f09f-4f42-ab54-094e457d42ec"
    class: openstack-scs-1-35-v1
    controlPlane:
      replicas: 3
      variables:
        overrides:
          - name: flavor
            value: "SCS-4V-8-50"
    version: v1.35.0
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 3
```

Variables of type `object` are set as nested values. The following example demonstrates this with `oidcConfig`:

```yaml
...
topology:
  variables:
    - name: oidcConfig
      value:
        issuerURL: "https://dex.k8s.scs.community"
        clientID: "kubectl"
...
```

In v1beta2, per-role overrides (e.g. different flavors for control plane and workers) are set via `topology.controlPlane.variables.overrides` and `topology.workers.machineDeployments[].variables.overrides` instead of separate variable names.

## Available variables

!!table!!
