# Configuration (Docker / scs)

The Docker cluster stack is designed for local development and CI. It uses the
CAPI Docker infrastructure provider and requires no cloud credentials.

## Version matrix

<!-- BEGIN GENERATED: matrix -->
| Version | K8s | CS Version | cilium | metrics-server |
|---------|-----|----------|---------|---------|
| 1-32 | 1.32.11 | - | 1.19.4 | 3.13.0 |
| 1-33 | 1.33.12 | - | 1.19.4 | 3.13.0 |
| 1-34 | 1.34.8 | - | 1.19.4 | 3.13.0 |
| 1-35 | 1.35.5 | - | 1.19.4 | 3.13.0 |
| 1-36 | 1.36.4 | - | 1.19.4 | 3.13.0 |
<!-- END GENERATED: matrix -->

## Example

```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: my-docker-cluster
  namespace: default
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
    classRef:
      name: docker-scs-1-35-v1
    controlPlane:
      replicas: 1
    version: v1.35.0
    workers:
      machineDeployments:
        - class: default-worker
          name: default-worker
          replicas: 1
```

## Available variables

<!-- BEGIN GENERATED: variables -->
|Name|Type|Default|Example|Description|Required|
|----|----|-------|-------|-----------|--------|
|`imageRepository`|string|""|"registry.k8s.io"|imageRepository sets the container registry to pull images from. If empty, the kubeadm default will be used.|false|
|`certSANs`|array|[]|["mydomain.example"]|certSANs sets extra Subject Alternative Names for the API Server signing cert.|false|
|`oidcConfig.clientID`|string||"kubectl"|A client id that all tokens must be issued for.|false|
|`oidcConfig.issuerURL`|string||"https://dex.k8s.scs.community"|URL of the provider that allows the API server to discover public signing keys. Only URLs that use the https:// scheme are accepted.|false|
|`oidcConfig.usernameClaim`|string|"preferred_username"|"preferred_username"|JWT claim to use as the user name.|false|
|`oidcConfig.groupsClaim`|string|"groups"|"groups"|JWT claim to use as the user's group. If the claim is present it must be an array of strings.|false|
|`oidcConfig.usernamePrefix`|string|"oidc:"|"oidc:"|Prefix prepended to username claims to prevent clashes with existing names.|false|
|`oidcConfig.groupsPrefix`|string|"oidc:"|"oidc:"|Prefix prepended to group claims to prevent clashes with existing names.|false|
|`registryMirrors`|array|[]||Registry mirrors for upstream container registries. Configures both containerd and CRI-O to pull through a mirror.|false|
<!-- END GENERATED: variables -->
