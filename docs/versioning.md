# Versioning

## Cluster Stack Versions

Each cluster stack is versioned independently per Kubernetes minor version. The version is embedded in the release artifact name:

```
{provider}-{stack}-{k8s-major}-{k8s-minor}-{cluster-stack-version}
```

Examples:
- `openstack-scs2-1-34-v1` — stable release, K8s 1.34
- `docker-scs2-1-35-v0` — dev release, K8s 1.35

### Version Semantics

| Version | Meaning | Registry |
|---------|---------|----------|
| `v0` | Development / unstable | ttl.sh (24h TTL) or git hash |
| `v1`, `v2`, ... | Stable releases | OCI registry (e.g. ghcr.io) |

Stable versions are auto-incremented by the build system: it queries the OCI registry for the highest existing version and increments by one.

### What Triggers a Version Bump

Any change to these components requires a new cluster stack version:

- **Cluster class** — variable defaults, patches, template structure
- **Cluster addons** — CNI, CCM, CSI, metrics-server versions or configuration
- **Node images** — OS version, containerd version, kubelet version

A cluster stack version is **not** bumped for Kubernetes patch versions. Instead, a new cluster stack version is released that references the updated patch version through its node images and addon compatibility.

## versions.yaml

Each stack has a `versions.yaml` that maps Kubernetes minor versions to addon versions and metadata:

```yaml
# providers/openstack/scs2/versions.yaml
versions:
  "1.32":
    occm: 2.32.3
    cinder-csi: 2.32.3
    ubuntu: "2204"
  "1.33":
    occm: 2.33.2
    cinder-csi: 2.33.2
    ubuntu: "2404"
  "1.34":
    occm: 2.34.0
    cinder-csi: 2.34.0
    ubuntu: "2404"
```

### Keys

- **Addon keys** (e.g. `occm`, `cinder-csi`) must match the Helm dependency names in `cluster-addon/*/Chart.yaml` exactly. The build system uses these to patch `Chart.yaml` with the correct version at build time.
- **Metadata keys** (`kubernetes`, `ubuntu`) are excluded from addon processing. They provide context for image generation and build tooling.

### Docker Stacks

Docker stacks have no version-tied addons (Cilium and metrics-server versions are fixed in their Chart.yaml), so their `versions.yaml` only lists supported Kubernetes versions:

```yaml
# providers/docker/scs2/versions.yaml
versions:
  "1.32": {}
  "1.33": {}
  "1.34": {}
  "1.35": {}
```

## Kubernetes Version Support

Each cluster stack supports multiple Kubernetes minor versions simultaneously. The supported range is defined by the entries in `versions.yaml`.

- Only **minor versions** are tracked — patch versions are handled transparently via node images
- The `csctl.yaml` file records the latest Kubernetes version used during development

### Ubuntu Image Mapping

For OpenStack stacks, the `ubuntu` metadata key controls which Ubuntu release is used for node images:

| Kubernetes Version | Ubuntu Release | Image Name Pattern |
|---|---|---|
| 1.32 and earlier | 22.04 | `ubuntu-capi-image-v1.32.x` |
| 1.33+ | 24.04 | `ubuntu-capi-image-v1.33.x` |
