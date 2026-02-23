# Configuration

This page lists the custom configuration options available, including their default values and if they are optional. The following example shows how these variables can be used inside the `cluster.yaml` file under `spec.topology.variables`.

## Version matrix

| Version | K8s | CS Version | cilium | metrics-server | os-csi | os-ccm |
|---------|-----|----------|---------|---------|---------|---------|
| 1-32 | 1.32 | - | 1.19.1 | 3.13.0 | 2.32.x | 2.32.x |
| 1-33 | 1.33 | - | 1.19.1 | 3.13.0 | 2.33.x | 2.33.x |
| 1-34 | 1.34 | - | 1.19.1 | 3.13.0 | 2.34.x | 2.34.x |
| 1-35 | 1.35 | - | 1.19.1 | 3.13.0 | 2.35.x | 2.35.x |

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

> **Note:** This table documents the **1-35** (v1beta2) variable set with unified
> variable names. Older versions (1-32, 1-33) use role-prefixed names like
> `controlPlaneFlavor` / `workerFlavor` instead of the unified `flavor`.

|Name|Type|Default|Example|Description|Required|
|----|----|-------|-------|-----------|--------|
|`imageName`|string|"ubuntu-capi-image"|"ubuntu-capi-image"|Base name of the OpenStack image for cluster nodes.|False|
|`imageIsOrc`|boolean|false|true|Whether the image name refers to an ORC (OpenStack Resource Controller) image resource instead of a Glance image.|False|
|`imageAddVersion`|boolean|true|false|Append the Kubernetes version suffix to the image name (e.g. `ubuntu-capi-image-v1.35`).|False|
|`networkExternalID`|string|""|"ebfe5546-f09f-4f42-ab54-094e457d42ec"|ID of the external OpenStack network for public internet access.|False|
|`networkMTU`|integer||1500|Maximum transmission unit (MTU) for the private cluster network.|False|
|`dnsNameservers`|array|["5.1.66.255", "185.150.99.255"]|["8.8.8.8"]|DNS nameservers for the cluster subnet.|False|
|`nodeCIDR`|string|"10.8.0.0/20"|"10.8.0.0/20"|CIDR for the cluster subnet. A network, subnet, and router will be created.|False|
|`flavor`|string|"SCS-2V-4-20s"|"SCS-4V-8-20"|OpenStack instance flavor for all nodes. Override per role using topology variable overrides.|False|
|`rootDisk`|integer|0|50|Root disk size in GiB. When set, an OpenStack volume is used instead of the ephemeral disk from the flavor.|False|
|`serverGroupID`|string|""|"3adf4e92-bb33-4e44-8ad3-afda9dfe8ec3"|Server group for anti-affinity placement. Override per role using topology variable overrides.|False|
|`additionalBlockDevices`|array|[]|[{"name": "data", "sizeGiB": 100, "type": "Volume"}]|Additional Cinder volumes to attach to nodes.|False|
|`sshKey`|string|""|"capi-keypair"|SSH key pair name to inject into nodes.|False|
|`apiServerLoadBalancer`|string|"octavia-ovn"|"none"|Load balancer for the API server. Options: `none`, `octavia-amphora`, `octavia-ovn`.|False|
|`apiServerAllowedCIDRs`|array|[]|["10.0.0.0/8"]|CIDRs allowed to access the API server load balancer.|False|
|`disableAPIServerFloatingIP`|boolean|false|true|Disable floating IP for the API server.|False|
|`certSANs`|array|[]|["mydomain.example"]|Extra Subject Alternative Names for the API server certificate.|False|
|`controlPlaneAvailabilityZones`|array|[]|["nova"]|Availability zones for control plane nodes.|False|
|`controlPlaneOmitAvailabilityZone`|boolean|false|true|Omit availability zone when creating control plane nodes, letting Nova schedule freely.|False|
|`identityRef.name`|string|"openstack"|"openstack"|Name of the Secret containing OpenStack credentials.|False|
|`identityRef.cloudName`|string|"openstack"|"openstack"|Cloud name within the credentials Secret.|False|
|`oidcConfig.clientID`|string||"kubectl"|OIDC client ID for API server authentication.||
|`oidcConfig.issuerURL`|string||"https://dex.example.com"|OIDC provider discovery URL (must be HTTPS).||
|`oidcConfig.usernameClaim`|string|"preferred_username"|"email"|JWT claim to use as the username.||
|`oidcConfig.groupsClaim`|string|"groups"|"groups"|JWT claim to use as groups.||
|`oidcConfig.usernamePrefix`|string|"oidc:"|"oidc:"|Prefix for OIDC usernames.||
|`oidcConfig.groupsPrefix`|string|"oidc:"|"oidc:"|Prefix for OIDC group names.||
|`registryMirrors`|array|[]|[{"hostnameUpstream": "docker.io", "urlMirror": "https://mirror.example.com"}]|Container registry mirrors for node containerd configuration.||
