# Configuration (openstack/scs2)

This page lists all ClusterClass variables available in the `openstack/scs2` cluster stack. Variables are set in the `Cluster` resource under `spec.topology.variables`.

## Example

```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: my-cluster
  namespace: my-tenant
  labels:
    managed-secret: cloud-config
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["192.168.0.0/16"]
    services:
      cidrBlocks: ["10.96.0.0/12"]
    serviceDomain: cluster.local
  topology:
    class: openstack-scs2-1-34-v1
    version: v1.34.3
    controlPlane:
      replicas: 3
    workers:
      machineDeployments:
        - class: default-worker
          name: default-worker
          replicas: 3
          variables:
            overrides:
              - name: flavor
                value: "SCS-4V-8"
    variables:
      - name: flavor
        value: "SCS-2V-4-20s"
      - name: rootDisk
        value: 50
      - name: networkExternalID
        value: "ebfe5546-f09f-4f42-ab54-094e457d42ec"
```

Note how `flavor` is set once at cluster level (`SCS-2V-4-20s`) and then overridden for workers via `machineDeployments[].variables.overrides`. You can also do it the other way around — set the worker flavor at cluster level and override the control plane via `topology.controlPlane.variables.overrides`. This works for all unified machine variables (`flavor`, `rootDisk`, `serverGroupID`, `additionalBlockDevices`).

Object variables (like `identityRef` and `oidcConfig`) are set as nested values:

```yaml
    variables:
      - name: identityRef
        value:
          name: "my-openstack-secret"
          cloudName: "my-cloud"
      - name: oidcConfig
        value:
          clientID: "kubectl"
          issuerURL: "https://dex.k8s.example.com"
```

## Image Variables

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `imageName` | string | `"ubuntu-capi-image"` | Base name of the OpenStack image. If `imageAddVersion` is enabled, the K8s version is appended (e.g. `ubuntu-capi-image-v1.34.3`). |
| `imageIsOrc` | boolean | `false` | If true, `imageName` refers to an ORC image resource. If false, it filters images in the OpenStack project. |
| `imageAddVersion` | boolean | `true` | Append the Kubernetes version as suffix to `imageName`. |

## API Server

| Name | Type | Default | Example | Description |
|------|------|---------|---------|-------------|
| `disableAPIServerFloatingIP` | boolean | `false` | | Disable the floating IP on the API server load balancer. |
| `certSANs` | array | `[]` | `["mydomain.example"]` | Extra Subject Alternative Names for the API server TLS cert. |
| `apiServerLoadBalancer` | string | `"octavia-ovn"` | `"octavia-ovn"` | Load balancer in front of the API server. Options: `none`, `octavia-amphora`, `octavia-ovn`. |
| `apiServerAllowedCIDRs` | array | *(none)* | `["192.168.10.0/24"]` | Restrict API server access to these CIDRs. Requires amphora LB (CAPO >= v2.12). Include the management cluster's outgoing IP. |

## Network

| Name | Type | Default | Example | Description |
|------|------|---------|---------|-------------|
| `dnsNameservers` | array | `["9.9.9.9", "149.112.112.112"]` | | DNS nameservers for the cluster subnet. |
| `nodeCIDR` | string | `"10.8.0.0/20"` | | CIDR for the cluster subnet. CAPO creates network, subnet, and router. Leave empty to skip. |
| `networkExternalID` | string | *(none)* | `"ebfe5546-..."` | ID of an external network. Required when multiple external networks exist. |
| `networkMTU` | integer | *(none)* | `1500` | MTU for the private cluster network. |

## Machine Variables

These variables apply to **all nodes** by default. Override per control plane or worker via `topology.controlPlane.variables.overrides` and `topology.workers.machineDeployments[].variables.overrides`.

| Name | Type | Default | Example | Description |
|------|------|---------|---------|-------------|
| `flavor` | string | `"SCS-2V-4"` | `"SCS-4V-8"` | OpenStack instance flavor. |
| `rootDisk` | integer | `50` | `25` | Root disk size in GiB. Use 0 for flavors with ephemeral disk. |
| `serverGroupID` | string | `""` | `"3adf4e92-..."` | Server group UUID for anti-affinity. |
| `additionalBlockDevices` | array | `[]` | see below | Additional Cinder volumes to attach. |

### additionalBlockDevices

Each entry is an object:

```yaml
- name: data
  sizeGiB: 100
  type: __DEFAULT__    # uses the default volume type
```

## Cluster-Level Control Plane Settings

These are CAPO cluster-level settings and apply only to the control plane. They cannot be overridden per worker.

| Name | Type | Default | Example | Description |
|------|------|---------|---------|-------------|
| `controlPlaneAvailabilityZones` | array | `[]` | `["nova"]` | Availability zones for control plane placement. |
| `controlPlaneOmitAvailabilityZone` | boolean | `false` | `true` | Let Nova scheduler choose the AZ. |

## Access Management

| Name | Type | Default | Example | Description |
|------|------|---------|---------|-------------|
| `sshKeyName` | string | `""` | `"capi-keypair"` | SSH key to inject into all nodes (for debugging). |
| `securityGroups` | array | `[]` | `["sg-name"]` | Extra security groups by name for all nodes. |
| `securityGroupIDs` | array | `[]` | `["9ae2f488-..."]` | Extra security groups by UUID for all nodes. Takes precedence over `securityGroups`. |

## Identity

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `identityRef` | object | `{"name": "openstack", "cloudName": "openstack"}` | Reference to the OpenStack credentials secret. |
| `identityRef.name` | string | `"openstack"` | Name of the Secret containing `clouds.yaml`. |
| `identityRef.cloudName` | string | `"openstack"` | Cloud name within `clouds.yaml`. |

## OIDC Configuration

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `oidcConfig` | object | *(none)* | OIDC configuration for API server authentication. Only applied if both `clientID` and `issuerURL` are set. |
| `oidcConfig.clientID` | string | *(none)* | Client ID for OIDC tokens. |
| `oidcConfig.issuerURL` | string | *(none)* | OIDC provider URL (must be https). |
| `oidcConfig.usernameClaim` | string | `"preferred_username"` | JWT claim for the username. |
| `oidcConfig.groupsClaim` | string | `"groups"` | JWT claim for groups. |
| `oidcConfig.usernamePrefix` | string | `"oidc:"` | Prefix for username claims. |
| `oidcConfig.groupsPrefix` | string | `"oidc:"` | Prefix for group claims. |

## Registry Mirrors

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `registryMirrors` | array | `[]` | Configure registry mirrors for both containerd and CRI-O. |

Each entry is an object:

```yaml
- name: registryMirrors
  value:
    - hostnameUpstream: "docker.io"
      urlUpstream: "https://registry-1.docker.io"
      urlMirror: "https://registry.example.com/v2/dockerhub"
      certMirror: ""
    - hostnameUpstream: "gcr.io"
      urlUpstream: "https://gcr.io"
      urlMirror: "https://registry.example.com/v2/gcr"
      certMirror: ""
```

| Field | Type | Description |
|-------|------|-------------|
| `hostnameUpstream` | string | Hostname of the upstream registry (e.g. `docker.io`). |
| `urlUpstream` | string | Server URL of the upstream registry. |
| `urlMirror` | string | URL of the mirror registry. |
| `certMirror` | string | TLS certificate of the mirror in PEM format (optional). |

This writes configuration files to all nodes (control plane and workers) for both container runtimes:

- **containerd**: `hosts.toml` in `/etc/containerd/certs.d/{hostname}/`
- **CRI-O**: drop-in config in `/etc/containers/registries.conf.d/50-mirror-{hostname}.conf`

If `certMirror` is provided, the CA certificate is written to both `/etc/containerd/certs/{hostname}/ca.crt` and `/etc/containers/certs.d/{hostname}/ca.crt`.

## Migration from scs (v1beta1)

The `scs2` stack uses camelCase variable names instead of snake_case. If migrating from `scs`:

| scs (old) | scs2 (new) | Notes |
|-----------|------------|-------|
| `controller_flavor` | `flavor` | Unified; override per CP or worker via topology overrides |
| `worker_flavor` | `flavor` | |
| `controller_root_disk` | `rootDisk` | Unified; override per CP or worker via topology overrides |
| `worker_root_disk` | `rootDisk` | |
| `external_id` | `networkExternalID` | |
| `controller_server_group_id` | `serverGroupID` | Unified; override per CP or worker via topology overrides |
| `worker_server_group_id` | `serverGroupID` | |
| `ssh_key` | `sshKeyName` | |
| `openstack_security_groups` | `securityGroups` | |
| `cloud_name` | `identityRef.cloudName` | |
| `secret_name` | `identityRef.name` | |
| `dns_nameservers` | `dnsNameservers` | |
| `node_cidr` | `nodeCIDR` | |
| `apiserver_loadbalancer` | `apiServerLoadBalancer` | |
| `restrict_kubeapi` | `apiServerAllowedCIDRs` | Renamed |
| `network_mtu` | `networkMTU` | |
| `oidc_config.*` | `oidcConfig.*` | camelCase sub-fields |

### Migration from earlier scs2 (pre-simplification)

If migrating from an earlier `scs2` version that used split variable names:

| Old scs2 | New scs2 | Notes |
|----------|----------|-------|
| `controlPlaneFlavor` | `flavor` | Unified; override per CP or worker via topology overrides |
| `workerFlavor` | `flavor` | |
| `controlPlaneRootDisk` | `rootDisk` | Unified; override per CP or worker via topology overrides |
| `workerRootDisk` | `rootDisk` | |
| `controlPlaneServerGroupID` | `serverGroupID` | Unified; override per CP or worker via topology overrides |
| `workerServerGroupID` | `serverGroupID` | |
| `workerAdditionalBlockDevices` | `additionalBlockDevices` | Now applies to all nodes |
| `workerSecurityGroups` | *(removed)* | Use `securityGroups` for all nodes |
| `workerSecurityGroupIDs` | *(removed)* | Use `securityGroupIDs` for all nodes |
| `apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs` | `apiServerAllowedCIDRs` | Shortened |

See `hack/migrate-cluster.sh` for an automated migration script.
