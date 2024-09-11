# Overview

## Cluster Stacks

Cluster Stacks is a comprehensive framework and reference implementations for defining and managing Kubernetes clusters via the Cluster API. It is designed to cater to multiple providers and supports a broad range of Kubernetes versions, offering a standardized approach to managing and configuring Kubernetes clusters.

It encapsulates multiple layers, including node configuration, Cluster API setup, and application-level configurations, such as the Container Network Interface (CNI). By packaging these interdependent configurations, the cluster stack allows for efficient management and deployment of Kubernetes clusters, offering standardized, resilient, and self-managed Kubernetes environments.

## 🔧 Usage

Follow our [quickstart guide](providers/openstack/quickstart.md) for an introduction on how to deploy cluster stacks on openstack.

## Layers of a Cluster Stack

In essence, a cluster stack is an amalgamation of various components each of which serves a crucial role in setting up, maintaining, and operating a Kubernetes cluster. In the context of our framework, we categorize these components into three core layers: `cluster-class`, `cluster-addons`, and `node-images`. Let's delve deeper into understanding each of these layers:

### 📚 Cluster Class

The Cluster Class serves as a blueprint for creating and configuring Kubernetes clusters consistently. It encapsulates various aspects of a cluster, including:

* The infrastructure provider details
* Networking configurations
* Cluster-class templating
* Other cluster-specific settings

Essentially, it defines the desired configuration and properties of a Kubernetes cluster. It leverages the [ClusterClass](https://cluster-api.sigs.k8s.io/tasks/experimental-features/cluster-class/) feature of Cluster API, which provides a declarative, Kubernetes-style API for cluster creation, configuration, and management. Any change in this layer or in the node-image or cluster-addon layers triggers a version bump in the cluster class, hence the cluster stack.

### 🎁 Cluster Addons

Cluster Addons are core components or services required for the Kubernetes cluster to function correctly and efficiently. These are not user-facing applications but rather foundational services critical to the operation and management of a Kubernetes cluster. They're usually installed and configured after the cluster infrastructure has been provisioned and before the cluster is ready to serve workloads.

Cluster addons encompass a variety of functionalities, including but not limited to:

* Container Network Interfaces (CNI): These are plugins that facilitate container networking. A CNI is integral to setting up network connectivity and ensuring communication between pods in a Kubernetes cluster.
* Cloud Controller Manager (CCM): The CCM is a Kubernetes control plane component that embeds the cloud-specific control logic. Its role is to manage the communication with the underlying cloud services.
* Konnectivity service: This is a network proxy that enables connectivity from the control plane to nodes and vice versa. It is a critical component that supports Kubernetes API server connectivity.
* Metrics Server: A cluster-wide aggregator of resource usage data, Metrics Server collects CPU, memory, and other metrics from nodes and pods, enabling features like Horizontal Pod Autoscaling.

It's important to note that cluster addons are not user-provided applications or services that can be installed multiple times, such as ingress controllers, application-level monitoring tools, or user-facing APIs. Those are left to the discretion and responsibility of the users, who install and manage them according to their specific needs and preferences.

Each addon version is independent and can be updated separately. However, a change in this layer also necessitates a version bump in the cluster class and the cluster stack, which is reflected in the metadata.yaml.

### 🎞️ Node Images

Node images provide the foundation for the operating system environment on each node of a Kubernetes cluster. They are typically a minimal operating system distribution, like a lightweight Linux distro, which may also include container runtime components such as Docker or containerd.

Node images are responsible for providing the necessary environment and dependencies to support Kubernetes components and workloads. This includes components like kubelet, kube-proxy, and other necessary system utilities and libraries.

The version of a node image can be different from that of the cluster stack or the cluster class. However, an update to a node image will trigger a version bump in the cluster class and hence the cluster stack.

In the cluster-stacks repository's directory structure, the build instructions for Node Images are always placed within the respective directory. The instructions outline the steps and configurations required to create the Node Image automatically. The specific method for releasing the Node Image may vary based on the provider's capabilities and requirements.

During the development phase, the build instructions serve as a reference within the repository itself. These instructions may utilize tools like Packer or other image-building techniques. This allows for flexibility and customization, enabling users to define their Node Images according to specific needs and requirements.

However, when it comes to the release of the cluster stack, the Node Image can be provided in different ways depending on the capabilities of the provider or the desired deployment method. Here are a few examples:

1. **URL on a remote endpoint**: In some cases, `providers` may support deploying a Node Image directly from a URL. In this scenario, the Node Image referenced in the `cluster stack`, specifically in the `cluster class`, would be provided as a URL pointing to a pre-built image accessible remotely.
1. **Artifact**: If the provider supports artifacts, the Node Image can be released as an artifact, such as a qcow2 file. The artifact would be uploaded to the provider, and the `cluster stack` references the artifact for node provisioning.
1. **Build Instructions**: In cases where the provider doesn't support direct URL deployment or artifact-based provisioning, the build instructions defined within the repository become critical. The build instructions serve as a comprehensive guide to build the Node Image, specifying all the necessary steps and configurations.

Regardless of the release method, the cluster stack, specifically the cluster class, references the appropriate Node Image to be used for node provisioning.

By allowing flexibility in the release and deployment methods of Node Images, the cluster stack framework caters to various provider capabilities and user requirements. This adaptability ensures the cluster stack can be deployed in diverse environments while maintaining a consistent and manageable approach to managing Kubernetes clusters.

## 🌐 IaaS Provider, Kubernetes Service Provider, and Cluster API
In the context of the `cluster-stacks`, we distinguish between two types of providers:

An **IaaS Provider**, in general, offers Infrastructure as a Service - providing the fundamental compute, storage, and network resources on which workloads can be run. In the context of cluster-stacks, an IaaS Provider specifically refers to an entity that owns an API for their infrastructure. If an organization uses a common infrastructure API, such as OpenStack, they are not considered an IaaS Provider in this context. However, if the organization owns the API for its infrastructure, it becomes an IaaS Provider for the purposes of cluster-stacks.

A **Kubernetes Service Provider**, on the other hand, is an entity that implements a cluster stack. They do so on top of the IaaS Providers, potentially spanning across multiple IaaS Providers. They use the IaaS Provider's infrastructure services and integrate them into their cluster stack implementations.

The **Cluster API (CAPI)** is a Kubernetes project aimed at simplifying the process of managing Kubernetes clusters. It offers a declarative API that automates the creation, configuration, and management of clusters, providing a standardized way to interact with Kubernetes. The cluster stack approach leverages CAPI to deliver self-managed Kubernetes clusters.

## 📌 Defining and Adding Providers
The structure of this repository is specifically designed to handle multiple providers, multiple cluster stacks per provider, and multiple Kubernetes versions per cluster stack. This organized structure allows us to effectively manage, develop, and maintain multiple cluster stacks across various Kubernetes versions and providers, all in a single repository.

### 📁 Repository Structure
The repository maintains a specific structure:

* Each IaaS Provider has a directory under providers.
* Each IaaS Provider can have multiple cluster stack implementations.
* Each cluster stack supports multiple Kubernetes major and minor versions.

```
providers/
└── <provider_name>/
    └── <cluster_stack_name>/
        └── <k8s_major_minor_version>/
```

The directory structure for adding a new provider would look something like this:

```
providers/<provider_name>/<cluster_stack_name>/<k8s_major_minor_version>
# example
providers/openstack/scs/1-28
```
This granular, hierarchical structure allows us to manage different versions of Kubernetes and their associated cluster stacks across different providers.

We decided to support multiple Kubernetes major and minor versions to provide the flexibility to accommodate different implementation requirements of the provider. However, we deliberately chose not to support Kubernetes patch versions directly. The reason is the high frequency of patch versions release (often weekly), which would complicate maintenance efforts significantly.

Instead, we represent Kubernetes patch version updates through changes in our cluster stack version. For instance, if a patch version of Kubernetes necessitates a change in the node-image or the cluster-class configuration, this would trigger a version bump in the corresponding cluster stack, hence the cluster class, as reflected in the metadata.yaml.

In this way, our versioning system, our directory structure, and our approach to Kubernetes versioning are all interlinked, providing us a comprehensive, manageable, and resilient framework for maintaining various Kubernetes distributions or cluster stacks across multiple providers and versions.

## 📑 Versioning

Note: This section is subject to change, as our new tool [csctl](https://github.com/SovereignCloudStack/csctl) will incorporate future versioning capabilities.

A fundamental aspect of the cluster stack approach is the encapsulation of versioning within a cluster stack distribution. Each of the components can be updated independently, leading to a flexible and maintainable system.

However, the critical point to understand here is the relationship between these component versions and the cluster stack version. Whenever there's a change or an update to either the cluster addon or the node image, the version of the cluster stack must be bumped. And due to the connection between the cluster class and the cluster stack, the cluster class version must be updated to match the new cluster stack version.

The cluster stack version doesn't simply mirror the versions of its components, but rather, it reflects the "version of change". In essence, the cluster stack version is a reflection of the state of the entire stack as a whole at a particular point in time. Any change in the components warrants a new state, and therefore a new version of the cluster stack.

So, an update to the cluster addon component will bump the version of the cluster stack, irrespective of the existing version of the node image. The same applies vice versa. When such an update occurs, the version of the cluster class is also incremented to align with the new cluster stack version, maintaining the unity of the cluster stack framework.

This versioning approach ensures a clear and precise track of changes, promoting efficient management, and isolated testing. It offers enhanced resilience for the Kubernetes distribution or the cluster stack, ensuring safe and secure upgrades even in rapid update cycles. It's an efficient method of maintaining stability in the rapidly changing environment of a Kubernetes stack.

The versioning of the cluster stack is primarily managed through a file named metadata.yaml, located at the root directory of each cluster stack. This file serves as the source of truth for the versioning information of the cluster stack, cluster class, node images, and cluster addons.

Here is an example of how metadata.yaml could look like:
```
apiVersion: metadata.clusterstack.x-k8s.io/v1alpha1
versions:
  clusterStack: v3
  kubernetes: v1.27.3
  components:
    clusterAddon: v2
    nodeImage: v1
```
In this example, the cluster stack (and thus the cluster class) is on version 3, while the cluster addon is on version 2 and node image is on version 1.

When there's a change or update in the node images or cluster addons, we would bump the version of the cluster stack and cluster class, while leaving the unaffected component's version intact. So if the node image was updated, the metadata.yaml might then look like this:

```
apiVersion: metadata.clusterstack.x-k8s.io/v1alpha1
versions:
  clusterStack: v4
  kubernetes: v1.27.3
  components:
    clusterAddon: v2
    nodeImage: v2
```

Here, the cluster stack and cluster class versions were updated to v4, the node image version was bumped to v2 due to the changes, while the cluster addon remained on v2 as it was not affected by the update.

This versioning approach allows us to keep track of changes across different components, manage these components effectively, and conduct isolated testing. This ensures that our Kubernetes distribution or cluster stack remains resilient, and we can perform safe and secure upgrades even in the face of rapid update cycles. The metadata.yaml plays a critical role in maintaining this structure and providing an accurate representation of the state of the whole stack at any given time.
