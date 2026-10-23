# OpenStack / scs

Standard SCS cluster stack: dedicated VMs for both control plane and workers.

## Getting started

### Prerequisites

In addition to the [common prerequisites](../../quickstart.md#prerequisites):

- An OpenStack cloud with application credentials
- A `clouds.yaml` with your credentials

### Deploy

```bash
# 1. Management cluster
kind create cluster
clusterctl init --infrastructure openstack

# 2. Deploy credentials
export CS_NAMESPACE=my-tenant
helm upgrade -i csp-helper-${CS_NAMESPACE} \
  -n ${CS_NAMESPACE} --create-namespace \
  https://github.com/SovereignCloudStack/openstack-csp-helper/releases/latest/download/openstack-csp-helper.tgz \
  -f path/to/clouds.yaml

# 3. Build, publish, install CSO, and apply the ClusterStack
just dev 1.36 --install-cso | kubectl apply -f -
kubectl get clusterclass -w

# 4. Create a workload cluster
kubectl create namespace ${CS_NAMESPACE}
just generate-resources 1.36 --cluster-only --namespace ${CS_NAMESPACE} | kubectl apply -f -
```

For a production OCI registry instead of ttl.sh:

```bash
export OCI_REGISTRY=registry.example.com
export OCI_REPOSITORY=kaas/cluster-stacks
just install-cso
just dev 1.36 | kubectl apply -f -
```

---

## Configuration

This page lists the custom configuration options available, including their default values and if they are optional. The following example shows how these variables can be used inside the `cluster.yaml` file under `spec.topology.variables`.

## Version matrix

<!-- BEGIN GENERATED: matrix -->
| Version | K8s | CS Version | cilium | metrics-server | os-csi | os-ccm |
|---------|-----|----------|---------|---------|---------|---------|
| 1-32 | 1.32.5 | - | 1.17.4 | 3.12.2 | 2.32.0 | 2.32.0 |
| 1-33 | 1.33.11 | - | 1.19.4 | 3.13.0 | 2.33.x | 2.33.x |
| 1-34 | 1.34.12 | - | 1.19.4 | 3.13.0 | 2.34.x | 2.34.x |
| 1-35 | 1.35.9 | - | 1.19.4 | 3.13.0 | 2.35.x | 2.35.x |
| 1-36 | 1.36.5 | - | 1.20.2 | 3.14.0 | 2.36.x | 2.36.x |
<!-- END GENERATED: matrix -->

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

`spec.clusterNetwork` is optional. If no pod CIDR is set, the stack assumes
`192.168.0.0/16` as the default. Set pod or service CIDRs only when you need
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

`componentOverrides` is mainly used to set resource requests and limits. The Kubernetes components (`apiServer`, `controllerManager`, `scheduler`, `etcd`, `coreDNS`) accept `resources` only, the addons (`cni`, `ccm`, `csi`, `metricsServer`) accept any values of their Helm chart:

```yaml
...
topology:
  variables:
    - name: componentOverrides
      value:
        apiServer:
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
        metricsServer:
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
...
```

Addon values and `ciliumHostLegacyRouting` are applied when the Cluster Stack Operator installs or upgrades the addons, i.e. on cluster creation and on cluster upgrades.

## Available variables

The variables below apply to 1-35 and 1-36. Older versions do not support all of them.

<!-- BEGIN GENERATED: variables -->
|Name|Type|Default|Example|Description|Required|
|----|----|-------|-------|-----------|--------|
|`imageName`|string|"ubuntu-capi-image"||The base name of the OpenStack image used for provisioning servers.<br />If `imageIsOrc` is enabled, this name refers to an ORC image resource.<br />If `imageIsOrc` is disabled, the name is used to filter images available in the OpenStack project. In this case, the specified image must already exist within the project.<br />If `imageAddVersion` is enabled, the Kubernetes version will be appended to form the complete image name (e.g., imageName-v1.32.5)|false|
|`imageIsOrc`|boolean|false||Indicates whether the image name refers to an ORC image resource.<br />If set to true (default), the `imageName` is interpreted as a reference to an ORC image.<br />If set to false, the `imageName` is used to filter images in the OpenStack project instead.|false|
|`imageAddVersion`|boolean|true||Add a suffix with the Kubernetes version to the imageName. E.g. imageName-v1.32.5.|false|
|`networkExternalID`|string||"ebfe5546-f09f-4f42-ab54-094e457d42ec"|ID of an external OpenStack network. Required when multiple<br />external networks exist and VMs need public internet access.|false|
|`networkMTU`|integer||1500|MTU for the private cluster network. Set this to avoid fragmentation issues.|false|
|`dnsNameservers`|array|["9.9.9.9", "149.112.112.112"]|["9.9.9.9", "149.112.112.112"]|DNS nameservers for the cluster subnet. Only used when a new network/subnet is created.|false|
|`nodeCIDR`|string|"10.8.0.0/20"|"10.8.0.0/20"|CIDR for the cluster subnet. CAPO will create a network, subnet,<br />and router. Leave empty to skip network creation.|false|
|`flavor`|string|"SCS-2V-4"|"SCS-2V-4"|OpenStack instance flavor. Applies to all nodes by default.<br />Override per control plane or worker via topology variables overrides.|false|
|`rootDisk`|integer|50|50|Root disk size in GiB. OpenStack volume will be created and used<br />instead of an ephemeral disk defined in the flavor.<br />Set to 0 to use the flavor's ephemeral disk.|false|
|`diskPinAZ`|boolean|false|true|Create root and additional volumes in the availability zone (failure domain)<br />of the machine. Needed on clouds where volumes can only be attached in the<br />same availability zone.|false|
|`serverGroupID`|string|""|"3adf4e92-bb33-4e44-8ad3-afda9dfe8ec3"|Server group for anti-affinity placement. Override per CP/worker via topology.|false|
|`additionalBlockDevices`|array|[]||Additional block devices (Cinder volumes) to attach to nodes.<br />Override per CP/worker via topology.|false|
|`controlPlaneAvailabilityZones`|array|[]|["nova"]|Availability zones for control plane nodes (OpenStack cluster-level setting).|false|
|`controlPlaneOmitAvailabilityZone`|boolean|false||Omit availability zone when creating control plane nodes, letting the<br />Nova scheduler decide based on other scheduling constraints.|false|
|`sshKeyName`|string|""|"capi-keypair"|SSH key to inject into all nodes (for debugging).|false|
|`securityGroups`|array|[]|["security-group-1"]|Extra security groups by name for all nodes.<br />Ignored if securityGroupIDs is set. Override per CP/worker via topology.|false|
|`securityGroupIDs`|array|[]|["9ae2f488-30a3-4629-bd51-07acb8eb4278"]|Extra security groups by UUID for all nodes.<br />Takes precedence over securityGroups. Override per CP/worker via topology.|false|
|`identityRef.name`|string|"openstack"|"openstack"|The name of the secret that carries the OpenStack clouds.yaml|false|
|`identityRef.cloudName`|string|"openstack"|"openstack"|The name of the cloud to use from the clouds.yaml|false|
|`disableAPIServerFloatingIP`|boolean|false||Disable the floating IP on the API server load balancer.|false|
|`certSANs`|array|[]|["mydomain.example"]|Extra Subject Alternative Names for the API server TLS certificate.|false|
|`serviceLoadBalancer`|string|"octavia-ovn"|"octavia-ovn"|Load balancer provider that the cloud controller manager uses for Services of type<br />LoadBalancer in the workload cluster (e.g. in front of an ingress controller).<br />Options: octavia-amphora, octavia-ovn (default).<br />Changes are applied to the cloud controller manager with the next cluster upgrade.|false|
|`apiServerLoadBalancer`|string|"octavia-ovn"|"octavia-ovn"|Load balancer in front of the API server.<br />Options: none, octavia-amphora, octavia-ovn (default).|false|
|`apiServerAllowedCIDRs`|array||["192.168.10.0/24"]|Restrict access to the API server to these CIDRs (network-level ACL).<br />Requires amphora as load balancer provider (CAPO >= v2.12).<br />Ensure the management cluster's outgoing IP is included,<br />otherwise CAPO cannot reconcile the workload cluster.|false|
|`auditLogging`|boolean|true||Write API server audit logs to /var/log/kubernetes/audit on the control plane nodes.|false|
|`oidcConfig.clientID`|string||"kubectl"|A client id that all tokens must be issued for.|false|
|`oidcConfig.issuerURL`|string||"https://dex.k8s.scs.community"|URL of the provider that allows the API server to discover public signing keys. Only URLs that use the https:// scheme are accepted. This is typically the provider's discovery URL, changed to have an empty path.|false|
|`oidcConfig.usernameClaim`|string|"preferred_username"|"preferred_username"|JWT claim to use as the user name. By default sub, which is expected to be a unique identifier of the end user. Admins can choose other claims, such as email or name, depending on their provider. However, claims other than email will be prefixed with the issuer URL to prevent naming clashes with other plugins.|false|
|`oidcConfig.groupsClaim`|string|"groups"|"groups"|JWT claim to use as the user's group. If the claim is present it must be an array of strings.|false|
|`oidcConfig.usernamePrefix`|string|"oidc:"|"oidc:"|Prefix prepended to username claims to prevent clashes with existing names (such as system: users). For example, the value oidc: will create usernames like oidc:jane.doe. If this flag isn't provided and --oidc-username-claim is a value other than email the prefix defaults to ( Issuer URL )# where ( Issuer URL ) is the value of --oidc-issuer-url. The value - can be used to disable all prefixing.|false|
|`oidcConfig.groupsPrefix`|string|"oidc:"|"oidc:"|Prefix prepended to group claims to prevent clashes with existing names (such as system: groups). For example, the value oidc: will create group names like oidc:engineering and oidc:infra.|false|
|`registryMirrors`|array|[]||Registry mirrors for upstream container registries. Configures both containerd and CRI-O to pull through a mirror.|false|
|`ciliumHostLegacyRouting`|boolean|false||Route pod traffic through the host network stack (Cilium bpf.hostLegacyRouting).|false|
|`componentOverrides.apiServer`|object|||kube-apiserver|false|
|`componentOverrides.controllerManager`|object|||kube-controller-manager|false|
|`componentOverrides.scheduler`|object|||kube-scheduler|false|
|`componentOverrides.etcd`|object|||etcd|false|
|`componentOverrides.coreDNS`|object|||CoreDNS|false|
|`componentOverrides.cni`|object|||Values for the cilium Helm chart.|false|
|`componentOverrides.ccm`|object|||Values for the openstack-cloud-controller-manager Helm chart.|false|
|`componentOverrides.csi`|object|||Values for the openstack-cinder-csi Helm chart.|false|
|`componentOverrides.metricsServer`|object|||Values for the metrics-server Helm chart.|false|
<!-- END GENERATED: variables -->
