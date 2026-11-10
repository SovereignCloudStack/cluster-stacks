# Configuration

This page lists the custom configuration options available, including their default values and whether they are optional. The following example shows how these variables can be used inside the `cluster.yaml` file under `spec.topology.variables`.

## Version matrix

!!matrix!!

## Example

```yaml
apiVersion: <cluster-api-version>
kind: Cluster
metadata:
  name: my-cluster
  namespace: my-namespace
  labels:
    managed-secret: cloud-config
spec:
  topology:
    variables:   # <-- variables from the table below can be set here
      - name: <variable-name>
        value: <value>
    classRef:   # cluster.x-k8s.io/v1beta1 clusters (hcp) use "class: <installed-clusterclass>" instead
      name: <installed-clusterclass>
    controlPlane:
      replicas: 3
      variables:
        overrides:
          - name: <variable-name>
            value: <value>
    version: v<supported-kubernetes-patch>
    workers:
      machineDeployments:
        - class: default-worker
          name: md-0
          replicas: 3
```

`spec.clusterNetwork` is optional. Set pod or service CIDRs only when you need
non-default values or explicit network settings.

Variables of type `object` are set as nested values. The following example demonstrates the shape:

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
