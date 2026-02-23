# Configuration (Docker / scs)

The Docker cluster stack is designed for local development and CI. It uses the
CAPI Docker infrastructure provider and requires no cloud credentials.

## Version matrix

| Version | K8s | CS Version | cilium | metrics-server |
|---------|-----|----------|---------|---------|
| 1-32 | 1.32 | - | 1.19.1 | 3.13.0 |
| 1-33 | 1.33 | - | 1.19.1 | 3.13.0 |
| 1-34 | 1.34 | - | 1.19.1 | 3.13.0 |
| 1-35 | 1.35 | - | 1.19.1 | 3.13.0 |

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
    class: docker-scs-1-35-v1
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

|Name|Type|Default|Example|Description|Required|
|----|----|-------|-------|-----------|--------|
|`imageRepository`|string|""|"registry.k8s.io"|Container registry to pull images from. If empty, the kubeadm default is used.|False|
|`certSANs`|array|[]|["mydomain.example"]|Extra Subject Alternative Names for the API Server signing certificate.|False|
|`oidcConfig.clientID`|string||"kubectl"|OIDC client ID for API server authentication.||
|`oidcConfig.issuerURL`|string||"https://dex.example.com"|OIDC provider discovery URL (must be HTTPS).||
|`oidcConfig.usernameClaim`|string|"preferred_username"|"email"|JWT claim to use as the username.||
|`oidcConfig.groupsClaim`|string|"groups"|"groups"|JWT claim to use as groups.||
|`oidcConfig.usernamePrefix`|string|"oidc:"|"oidc:"|Prefix for OIDC usernames.||
|`oidcConfig.groupsPrefix`|string|"oidc:"|"oidc:"|Prefix for OIDC group names.||
|`registryMirrors`|array|[]|[{"hostnameUpstream": "docker.io", "urlMirror": "https://mirror.example.com"}]|Container registry mirrors for node containerd/CRI-O configuration.||
