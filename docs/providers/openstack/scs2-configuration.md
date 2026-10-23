# Configuration of the `scs2` Cluster Stack (deprecated)

> **Deprecated:** `scs2` is only maintained and will be phased out. Use the [`scs` cluster stack](scs-configuration.md) for new clusters.

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
---
topology:
  variables:
    - name: oidc_config
      value:
        issuer_url: "https://dex.k8s.scs.community"
        client_id: "kubectl"
```

## Available variables


<!-- BEGIN GENERATED: variables -->
|Name|Type|Default|Example|Description|Required|
|----|----|-------|-------|-----------|--------|
|`imageName`|string|"ubuntu-capi-image"||The base name of the OpenStack image used for provisioning servers.<br />If `imageIsOrc` is enabled, this name refers to an ORC image resource.<br />If `imageIsOrc` is disabled, the name is used to filter images available in the OpenStack project. In this case, the specified image must already exist within the project.<br />If `imageAddVersion` is enabled, the Kubernetes version will be appended to form the complete image name (e.g., imageName-v1.32.5)|false|
|`imageIsOrc`|boolean|false||Indicates whether the image name refers to an ORC image resource.<br />If set to true (default), the `imageName` is interpreted as a reference to an ORC image.<br />If set to false, the `imageName` is used to filter images in the OpenStack project instead.|false|
|`imageAddVersion`|boolean|true||Add a suffix with the Kubernetes version to the imageName. E.g. imageName-v1.32.5.|false|
|`disableAPIServerFloatingIP`|boolean|false|false|DisableAPIServerFloatingIP controls whether a floating IP should be attached to the API server.|false|
|`networkExternalID`|string||"ebfe5546-f09f-4f42-ab54-094e457d42ec"|networkExternalID is the ID of an external OpenStack Network. This is necessary to get public internet to the VMs in case there are several external networks.|false|
|`networkMTU`|integer||1500|networkMTU sets the maximum transmission unit (MTU) value to address fragmentation for the private network ID.|false|
|`dnsNameservers`|array|["9.9.9.9", "149.112.112.112"]|["9.9.9.9", "149.112.112.112"]|dnsNameservers is the list of nameservers for the OpenStack Subnet being created. Set this value when you need to create a new network/subnet which requires access to DNS.|false|
|`nodeCIDR`|string|"10.8.0.0/20"|"10.8.0.0/20"|nodeCIDR is the OpenStack Subnet to be created.<br />Cluster actuator will create a network, a subnet with nodeCIDR,<br /> and a router connected to this subnet.<br />If you leave this empty, no network will be created.|false|
|`diskPinAZ`|boolean|false|true|Pass availabilityZone (failureDomain) of the machine to its (root) disk volumes.<br />Some clouds have a 1:1 relationship of storage availability zones with compute AZs.<br />In these, attaching a disk from another AZ often comes with a performance penalty<br />or is not possible at all. You can set this to true to tell capo to create the root<br />disk in the stated failureDomain of this machine. This setting applies to controlPlane<br />root disks (if they use root volumes), worker machine root disks (if they use root<br />volumes) and workerAdditionalBlockDevices (if any are configured).|false|
|`controlPlaneFlavor`|string|"SCS-2V-4"|"SCS-2V-4-20s"|OpenStack instance flavor for control plane nodes. (The default, SCS-2V-4, is not ideal;<br />recommendation is to replace this by SCS-2V-4-20s and set controlPlaneRootDisk to 0<br />or specify a non-zero controlPlaneRootDisk with a diskless flavor.)|false|
|`controlPlaneRootDisk`|integer|50|25|Root disk size in GiB for control-plane nodes.<br />OpenStack volume will be created and used instead of an ephemeral disk defined in flavor.<br />Should only be used for the diskless flavors (and then be set >= 20), otherwise set to 0.|false|
|`controlPlaneServerGroupID`|string|""|"3adf4e92-bb33-4e44-8ad3-afda9dfe8ec3"|The server group to assign the control plane nodes to (can be used for anti-affinity).|false|
|`controlPlaneAvailabilityZones`|array||["nova"]|controlPlaneAvailabilityZones is the set of availability zones which control plane machines may be deployed to.|false|
|`controlPlaneOmitAvailabilityZone`|boolean||true|controlPlaneOmitAvailabilityZone causes availability zone to be omitted when creating control plane nodes,<br />allowing the Nova scheduler to make a decision on which availability zone to use based on other scheduling constraints.|false|
|`workerFlavor`|string|"SCS-4V-8"|"SCS-4V-8"|OpenStack instance flavor for worker nodes (default: SCS-4V-8, which requires workerRootDisk).|false|
|`workerRootDisk`|integer|50|25|Root disk size in GiB for worker nodes.<br />OpenStack volume will be created and used instead of an ephemeral disk defined in flavor.<br />Should be used for the diskless flavors (>= 20), otherwise set to 0.|false|
|`workerServerGroupID`|string|""|"869fe071-1e56-46a9-9166-47c9f228e297"|The server group to assign the worker nodes to.|false|
|`workerAdditionalBlockDevices`|array|[]||You may pass an array with additional volumes (disks) here, consisting of<br />name, sizeGiB (default: 20) and type (aka storage class, default: __DEFAULT__).|false|
|`sshKeyName`|string|""|"capi-keypair"|The ssh key name to inject in the nodes (for debugging).|false|
|`securityGroups`|array|[]|["security-group-1"]|The names of extra security groups to assign to worker and control plane nodes.<br />Will be ignored if `securityGroupIDs` is used.|false|
|`securityGroupIDs`|array|[]|["9ae2f488-30a3-4629-bd51-07acb8eb4278"]|The UUIDs of extra security groups to assign to worker and control plane nodes|false|
|`workerSecurityGroups`|array|[]|["security-group-1"]|The names of extra security groups to assign to the worker nodes.<br />Will be ignored if `workerSecurityGroupIDs` is used.|false|
|`workerSecurityGroupIDs`|array|[]|["9ae2f488-30a3-4629-bd51-07acb8eb4278"]|The UUIDs of extra security groups to assign to the worker nodes|false|
|`identityRef.name`|string|"openstack"|"openstack"|The name of the secret that carries the OpenStack clouds.yaml|false|
|`identityRef.cloudName`|string|"openstack"|"openstack"|The name of the cloud to use from the clouds.yaml|false|
|`certSANs`|array|[]|["mydomain.example"]|certSANs sets extra Subject Alternative Names for the API Server signing cert.|false|
|`apiServerLoadBalancer`|string|"octavia-ovn"|"none, octavia-amphora, octavia-ovn"|Cluster-API by default places a LoadBalancer in front of the kubernetes API server.<br />(There are also LBs that the CCM creates for a service type LoadBalancer which are configured independently.)<br />This setting here is to configure the LoadBalancer that is placed in front of the apiServer.<br />You can choose from 3 options:<br /><br />none:<br />  No LoadBalancer solution will be deployed<br /><br />octavia-amphora:<br />  Uses OpenStack's LoadBalancer service Octavia (provider:amphora)<br /><br />octavia-ovn:<br />  (default) Uses OpenStack's LoadBalancer service Octavia (provider:ovn)|false|
|`apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs`|array||["192.168.10.0/24"]|apiServerLoadBalancerOctaviaAmphoraAllowedCIDRs restrict access to the Kubernetes API server on a network level.<br />Ensure that at least the outgoing IP of your Management Cluster is added to the list of allowed CIDRs.<br />Otherwise CAPO can’t reconcile the target Cluster correctly.<br />This requires amphora as load balancer provider in version >= v2.12.|false|
|`oidcConfig.clientID`|string||"kubectl"|A client id that all tokens must be issued for.|false|
|`oidcConfig.issuerURL`|string||"https://dex.k8s.scs.community"|URL of the provider that allows the API server to discover public signing keys. Only URLs that use the https:// scheme are accepted. This is typically the provider's discovery URL, changed to have an empty path.|false|
|`oidcConfig.usernameClaim`|string|"preferred_username"|"preferred_username"|JWT claim to use as the user name. By default sub, which is expected to be a unique identifier of the end user. Admins can choose other claims, such as email or name, depending on their provider. However, claims other than email will be prefixed with the issuer URL to prevent naming clashes with other plugins.|false|
|`oidcConfig.groupsClaim`|string|"groups"|"groups"|JWT claim to use as the user's group. If the claim is present it must be an array of strings.|false|
|`oidcConfig.usernamePrefix`|string|"oidc:"|"oidc:"|Prefix prepended to username claims to prevent clashes with existing names (such as system: users). For example, the value oidc: will create usernames like oidc:jane.doe. If this flag isn't provided and --oidc-username-claim is a value other than email the prefix defaults to ( Issuer URL )# where ( Issuer URL ) is the value of --oidc-issuer-url. The value - can be used to disable all prefixing.|false|
|`oidcConfig.groupsPrefix`|string|"oidc:"|"oidc:"|Prefix prepended to group claims to prevent clashes with existing names (such as system: groups). For example, the value oidc: will create group names like oidc:engineering and oidc:infra.|false|
<!-- END GENERATED: variables -->
