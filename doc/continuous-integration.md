# Continuous integration

Project `cluster-stacks` use the [SCS Zuul](https://zuul.scs.community) CI platform to
drive its continuous integration tests. The project is registered under the [SCS tenant](https://zuul.scs.community/t/SCS/projects)
and therefore is able to use a set of pre-defined pipelines, jobs, and ansible roles that the
SCS Zuul instance defines and imports. If you want to explore currently available SCS pipelines,
visit the [SCS zuul-config](https://github.com/SovereignCloudStack/zuul-config) project.
If you want to see the full list of jobs that are available, visit the [SCS Zuul UI](https://zuul.scs.community/t/SCS/jobs).
And if you are looking for some handy ansible role that SCS Zuul imports, visit the [source](https://opendev.org/zuul/zuul-jobs/src/branch/master/roles).

Refer to the SCS [Zuul users guide](https://github.com/SovereignCloudStack/docs/blob/main/contributor-docs/operations/operations/zuul-ci-cd-quickstart-user-guide.md) and/or
[Zuul docs](https://zuul-ci.org/docs/) for further details on how to define and use Zuul
CI/CD pipelines and jobs.

> [!NOTE]
> If you are interested in the Zuul CI platform and want to deploy your own development instance of it,
then read the official [quick-start](https://zuul-ci.org/docs/zuul/latest/tutorials/quick-start.html) manual
or visit [this](https://github.com/matofederorg/zuul-config?tab=readme-ov-file#zuul-ci) tutorial which aims a connect
of Zuul CI platform with a GitHub organization.

## Configuration

SCS Zuul automatically recognizes `.zuul.yaml` configuration file that is located in the
cluster-stacks's root. This file informs Zuul about the project's [default-branch](https://zuul-ci.org/docs/zuul/latest/config/project.html#attr-project.default-branch) and
preferred [merge-mode](https://zuul-ci.org/docs/zuul/latest/config/project.html#attr-project.merge-mode).
It also references [SCS Zuul pipelines](https://github.com/SovereignCloudStack/zuul-config) and
their jobs used by the cluster-stacks project. Then, jobs link Ansible playbooks that contain
tasks for actual CI testing.

See relevant CI configuration files:

```text
├── .zuul.yaml
├── playbooks
│   ├── dependencies.yaml
│   ├── openstack
│   │   ├──  e2e.yaml
│   │   ├──  templates
│   │   │    ├── mgmt-cluster-config.yaml.j2
│   │   │    ├── cluster.yaml.j2
│   │   │    └── cluster-stack-template.yaml.j2
```

## Pipelines

This section describes an [SCS Zuul pipelines](https://github.com/SovereignCloudStack/zuul-config/blob/main/zuul.d/gh_pipelines.yaml) that are used by the cluster-stacks project.

- `e2e-test`
  - It is triggered by the `e2e-test` label in the opened PR
  - It executes `e2e-openstack-conformance` job
  - It applies the PR label `successful-e2e-test` and leaves an informative PR comment when the `e2e-openstack-conformance` job succeeded
  - It applies the PR label `failed-e2e-test` and leaves an informative PR comment when the `e2e-openstack-conformance` job failed
  - It applies the PR label `cancelled-e2e-test` and leaves an informative PR comment when the `e2e-openstack-conformance` job is canceled

- `unlabel-on-update-e2e-test`
  - It is triggered by the PR update only when PR contains the `successful-e2e-test` label
  - It ensures that any PR update invalidates a previous successful e2e test
  - It removes `successful-e2e-test` label from the PR

- `e2e-quick-test`
  - It is triggered by the `e2e-quick-test` label in the opened PR
  - It executes `e2e-openstack-quick` job
  - It applies the PR label `successful-e2e-quick-test` and leaves an informative PR comment when the `e2e-openstack-quick` job succeeded
  - It applies the PR label `failed-e2e-quick-test` and leaves an informative PR comment when the `e2e-openstack-quick` job failed
  - It applies the PR label `cancelled-e2e-quick-test` and leaves an informative PR comment when the `e2e-openstack-quick` job is canceled

- `unlabel-on-update-e2e-quick-test`
  - It is triggered by the PR update only when PR contains the `successful-e2e-quick-test` label
  - It ensures that any PR update invalidates a previous successful e2e test
  - It removes `successful-e2e-quick-test` label from the PR

## Jobs

This section describes Zuul jobs defined within the cluster-stacks project and linked in the above pipelines.

- `e2e-openstack-conformance`
  - It runs a sonobuoy conformance test against Kubernetes cluster spawned by a specific cluster-stack
  - This job is a child job of `openstack-access-base` that ensures OpenStack credentials
    availability in Zuul worker node. Parent job also defines a Zuul semaphore `semaphore-openstack-access`,
    that ensures that only one `openstack-access-base` job (or its children) can run at a time
  - See a high level `e2e-openstack-conformance` job steps:
    - Pre-run playbook `dependencies.yaml` installs project prerequisites, e.g. clusterctl, KinD, csctl, etc.
    - Main playbook `e2e.yaml` spawns a k8s workload cluster using a specific cluster-stack in OpenStack, runs sonobuoy conformance test, SCS compliance test, and cleans created k8s workload cluster

- `e2e-openstack-quick`
  - It runs a sonobuoy quick test against Kubernetes cluster spawned by a specific cluster-stack
  - This job is a child job of `openstack-access-base` that ensures OpenStack credentials
    availability in Zuul worker node. Parent job also defines a Zuul semaphore `semaphore-openstack-access`,
    that ensures that only one `openstack-access-base` job (or its children) can run at a time
  - See a high level `e2e-openstack-quick` job steps:
    - Pre-run playbook `dependencies.yaml` installs project prerequisites, e.g. clusterctl, KinD, csctl, etc.
    - Main playbook `e2e.yaml` spawns a k8s workload cluster using a specific cluster-stack in OpenStack, runs sonobuoy quick test, SCS compliance test, and cleans created k8s workload cluster

### Secrets

The parent job `openstack-access-base`, from which e2e jobs inherit, defines the secret variable `openstack-application-credential`.
This secret is stored directly in the [SCS/zuul-config repository](https://github.com/SovereignCloudStack/zuul-config/blob/main/zuul.d/secrets.yaml) in an encrypted form. It contains OpenStack application credentials to access the OpenStack project dedicated to CI testing.

This secret is encrypted by the SCS/zuul-config repository RSA key that has been generated by SCS Zuul instance.
So only SCS Zuul instance is able to decrypt it (read the [docs](https://zuul-ci.org/docs/zuul/latest/project-config.html#encryption)).

If you want to re-generate the mentioned secret or add another one using SCS/zuul-config repository RSA key, follow the below instructions:

- Install zuul-client

```bash
pip install zuul-client
```

- Encrypt "super-secret" string by the SCS/zuul-config repository public key from SCS Zuul

```bash
echo -n "super-secret" | \
  zuul-client --zuul-url https://zuul.scs.community encrypt \
  --tenant SCS \
  --project github.com/SovereignCloudStack/zuul-config
```

### Job customization

In a pull request (PR), you may want to run the end-to-end (e2e) test against the specific cluster-stack you are changing or adding, without modifying the `cluster_stack` variable in the `e2e.yaml` file in the repository.

To achieve this, include the following text in the body of the PR:

```text
    ```ZUUL_CONFIG
    cluster_stack = "openstack-alpha-1-29"
    ```
```

> [!NOTE]
> Please note that only cluster-stacks for OpenStack are currently supported.

### FAQ

#### How do developers/reviewers should proceed if they want to CI test this project?

A developer initiates a PR as usual. If a reviewer deems that the PR requires e2e testing, they can apply a specific label to the PR. Currently, the following labels could be applied:

- `e2e-test` (for comprehensive end-to-end (e2e) testing, including Kubernetes (k8s) workload cluster creation, execution of Sonobuoy conformance and SCS compliance tests, and cluster deletion.)
- `e2e-quick-test` (for comprehensive end-to-end (e2e) testing, including Kubernetes (k8s) workload cluster creation, execution of Sonobuoy quick and SCS compliance tests, and cluster deletion.)

After the e2e test has completed, the reviewer can examine the test results and respond accordingly, such as approving the PR if everything appears to be in order or requesting changes. Sonobuoy test results, along with a link to the e2e logs, are conveyed back to the PR via a comment. Additionally, the PR is labeled appropriately based on the overall e2e test results, using labels like
`successful-e2e-test`, `successful-e2e-quick-test`, `failed-e2e-test`, or `failed-e2e-quick-test`.

#### Why do we use PR `label` as an e2e pipeline trigger instead of e.g. PR `comment`?

We consider PR labels to be a more secure pipeline trigger compared to, for example, PR comments.
PR labels can only be applied by developers with [triage](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/repository-roles-for-an-organization#permissions-for-each-role) repository access or higher.
In contrast, PR comments can be added by anyone with a GitHub account.

Members of the SCS GitHub organization are automatically granted 'write' access to SCS repositories. Consequently, the PR label mechanism ensures that only SCS organization members can trigger e2e pipelines.

#### How do we ensure that any PR update invalidates a previous successful e2e test?

In fact, two mechanisms ensure the invalidation of a previously successful test when a PR is updated.

Firstly, the pipelines `unlabel-on-update-<e2e-test-name>` remove the `successful-<e2e-test-name>` label
from the PR when it's updated after a successful e2e test has finished. If an e2e test is in progress and the PR is updated, the currently running e2e test is canceled, the `successful-<e2e-test-name>` label is removed (if it exists), and the `cancelled-<e2e-test-name>` label is applied along with an informative PR comment to inform the reviewer about the situation.
