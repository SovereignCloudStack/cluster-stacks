This chart can be used to create a new namespace and two secrets for the clusterstacks approach. It reads clouds.yaml files in its raw form either with username and password or with an application credential. The chart is intended to be used once per Openstack-Project/Tenant. It is meant to prepare one corresponding namespace in the cluster-API management cluster (1:1 relation between openstackproject and cluster-namespace). The recommended way to invoke the chart is:

```
helm upgrade -i <tenant>-credentials -n <tenant> --create-namespace https://github.com/SovereignCloudStack/cluster-stacks/releases/download/openstack-alpha-1-28-v3/csp-helper-chart.tgz -f clouds.yaml
```
