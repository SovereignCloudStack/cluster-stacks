# Configuration

This page lists the custom configuration options available, including their default values and if they are optional. The following example shows how these variables can be used inside the `cluster.yaml` file under `spec.topology.variables`.

## Example

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name:
  namespace:
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
    variables: // <-- variables from the table can be set here
      - name: controller_flavor
        value: "SCS-4V-8-20"
      - name: worker_flavor
        value: "SCS-4V-8-20"
      - name: external_id
        value: "ebfe5546-f09f-4f42-ab54-094e457d42ec"
    class: openstack-alpha-1-29-v2
    controlPlane:
      replicas: 2
    version: v1.29.3
    workers:
      machineDeployments:
        - class: openstack-alpha-1-29-v2
          failureDomain: nova
          name: openstack-alpha-1-29-v2
          replicas: 4
```

Variables from the table containing a `.` are to be used in an object with the part before the dot being the object name and the part behind the dot being the value names. The following example demonstrates this with `oidc_config`.

```yaml
...
topology:
  variables:
    - name: oidc_config
      value:
        issuer_url: "https://dex.k8s.scs.community"
        client_id: "kubectl"
...
```

## Available variables

!!table!!