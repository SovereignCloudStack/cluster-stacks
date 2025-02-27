# use with https://github.com/casey/just
#
# Cluster Stack Creation automation
#

set export := true
set dotenv-filename := "just.env"
set dotenv-load := true

PATH := env_var('PATH') + ":" + justfile_directory() + "/bin"
repo := "https://github.com/SovereignCloudStack/cluster-stacks"
mainBranch := "main"
workingBranchPrefix := "chore/update-"
targetBranchPrefix := "release-"

# For Cluster Stack creation

mgmtcluster := "contextName"
mgmcluster_namespace := "NamespaceName"

[private]
default:
    @just --list --justfile {{ justfile() }}

# Show available commands
[group('General')]
help: default

# Check if csctl and clusterstack-provider-openstack are available and build them if neccessary. Checks for helm and yq
[group('General')]
dependencies:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! which csctl >/dev/null 2>&1; then
      echo -e "\e[33m\e[1mcsctl not found, building it from source.\e[0m"
      mkdir -p bin
      pushd bin
      git clone https://github.com/SovereignCloudStack/csctl csctl-git
      pushd csctl-git
      make build
      mv csctl ../csctl
      popd
      rm -rf csctl-git
      popd
    fi
    if ! which csctl-openstack >/dev/null 2>&1; then
      echo -e "\e[33m\e[1mcsctl-plugin-openstack not found, building it from source.\e[0m"
      mkdir -p bin
      pushd bin
      git clone https://github.com/SovereignCloudStack/csctl-plugin-openstack
      pushd csctl-plugin-openstack
      make build
      mv csctl-openstack ../csctl-openstack
      popd
      rm -rf csctl-plugin-openstack
      popd
    fi
    if ! which yq; then
      echo -e "\e[33m\e[1myq not found. Installing from GitHub.\e[0m"
      mkdir -p bin
      wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O bin/yq
      chmod +x bin/yq
    fi
    if ! which helm; then
      echo -e "\e[31m\e[1mHelm not found. Please install it.\e[0m"
    fi

# Clean temporary files and binaries
[group('General')]
clean:
    @echo -e "\e[33m\e[1mClean Buildtools\e[0m"
    rm -rf bin
    @echo -e "\e[33m\e[1mClean Provider Versions\e[0m"
    rm -rf providers/openstack/out
    @echo -e "\e[33m\e[1mClean Assets\e[0m"
    rm -rf .release

# Calculate the diff in the versions.yaml against main/HEAD to get relevant versions
[group('General')]
diff:
    #!/usr/bin/env bash
    set -euo pipefail
    versionsPath="providers/openstack/scs/versions.yaml"
    currentVersions=$(cat ${versionsPath})
    mainVersions=$(git show ${mainBranch}:${versionsPath})
    kubernetesVersions=$(yq -r '.[].kubernetes' ${versionsPath} | grep -Po "1\.\d+")
    toTest=()
    for version in ${kubernetesVersions}; do
      currentManifest=$(echo "${currentVersions}" | yq --sort-keys ".[] | select(.kubernetes | test(\"${version}\"))")
      mainManifest=$(echo "${mainVersions}" | yq --sort-keys ".[] | select(.kubernetes | test(\"${version}\"))")
      if ! diff -q <(echo "$currentManifest") <(echo "$mainManifest") >/dev/null; then
        toTest=("${toTest[@]}" "${version}")
      fi
    done
    echo "${toTest[@]}"

# Build Clusterstacks version directories according to changes in versions.yaml. Builds out directoy
[group('Building Manifests')]
build-versions: dependencies
    #!/usr/bin/env bash
    set -euxo pipefail
# Build Clusterstacks version directories according to changes in versions.yaml. Builds out directoy
[group('Build Manifests')]
build-versions: dependencies
    #!/usr/bin/env bash
    set -euo pipefail
    changedVersions=$(just diff)
    for version in ${changedVersions[@]}; do
      just build-version ${version}
    done

# Generate manifest for all Kubernetes Version regardless of changes to versions.
[group('Build Manifests')]
build-versions-all: dependencies
    #!/usr/bin/env bash
    set -euo pipefail
    versionsPath="providers/openstack/scs/versions.yaml"
    currentVersions=$(cat ${versionsPath})
    kubernetesVersions=$(yq -r '.[].kubernetes' ${versionsPath} | grep -Po "1\.\d+")
    for version in ${kubernetesVersions}; do
      just build-version ${version}
    done

# Generate Manifest for a specific Kubernetes version. Builds out directory
[group('Build Manifests')]
build-version VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    echo -e "\e[33m\e[1mBuild Manifests for {{ VERSION }}\e[0m"
    # check if there is a change in the component versions
    if [[ -e providers/openstack/out/{{ replace(VERSION, ".", "-") }} ]]; then
      versionsFile="providers/openstack/scs/versions.yaml"
      k8sVersion=$(yq -r ".[] | select(.kubernetes | test(\"{{ replace(VERSION, "-", ".") }}\")).kubernetes" ${versionsFile})
      cinder_csiVersion=$(yq -r ".[] | select(.kubernetes | test(\"{{ replace(VERSION, "-", ".") }}\")).cinder_csi" ${versionsFile})
      occmVersion=$(yq -r ".[] | select(.kubernetes | test(\"{{ replace(VERSION, "-", ".") }}\")).occm" ${versionsFile})
      k8sVersionCmp=$(yq -r .config.kubernetesVersion providers/openstack/out/{{ replace(VERSION, ".", "-") }}/csctl.yaml)
      cinder_csiVersionCmp=$(yq -r ".dependencies[] | select(.name | test(\"openstack-cinder-csi\")).version" providers/openstack/out/{{ replace(VERSION, ".", "-") }}/cluster-addon/Chart.yaml)
      occmVersionCmp=$(yq -r ".dependencies[] | select(.name | test(\"openstack-cloud-controller-manager\")).version" providers/openstack/out/{{ replace(VERSION, ".", "-") }}/cluster-addon/Chart.yaml)
      if [[ ${k8sVersion} != ${k8sVersionCmp#v} ]] || [[ ${cinder_csiVersion} != ${cinder_csiVersionCmp} ]] || [[ ${occmVersion} != ${occmVersionCmp} ]]; then
      ./hack/generate_version.py --target-version {{ replace(VERSION, "-", ".") }}
      fi
    else
      ./hack/generate_version.py --target-version {{ replace(VERSION, "-", ".") }}
    fi

# Build assets for a certain Kubernetes Version. Out directory needs to be present.
[group('Building Assets')]
build-assets-local-for VERSION: dependencies
    #!/usr/bin/env bash
    export PATH=${path}
    set -euxo pipefail
# Build assets for a certain Kubernetes Version. Out directory needs to be present.
[group('Build Assets')]
build-assets-local-for VERSION: dependencies
    #!/usr/bin/env bash
    set -euo pipefail
    just build-version {{ VERSION }}
    echo -e "\e[33m\e[1mBuild Assets for {{ VERSION }}\e[0m"
    if ! [[ -e providers/openstack/out/{{ replace(VERSION, ".", "-") }}/cluster-addon/Chart.lock ]]; then
      helm dependency up providers/openstack/out/{{ replace(VERSION, ".", "-") }}/cluster-addon/
    fi
    if ! [[ -e providers/openstack/out/{{ replace(VERSION, ".", "-") }}/cluster-class/Chart.lock ]]; then
      helm dependency up providers/openstack/out/{{ replace(VERSION, ".", "-") }}/cluster-class/
    fi
    csctl create -m hash providers/openstack/out/{{ replace(VERSION, ".", "-") }}/

# Build assets for a certain Kubernetes Version. Out directory needs to be present.
[group('Build Assets')]
build-assets-local: build-versions
    #!/usr/bin/env bash
    set -euo pipefail
    changedVersions=$(just diff)
    for version in ${changedVersions[@]}; do
      just build-assets-local-for ${version}
    done

# Build assets for a certain Kubernetes Version.
[group('Build Assets')]
build-assets-all-local: build-versions-all
    #!/usr/bin/env bash
    set -euo pipefail
    versions="$(cd providers/openstack/out/ && echo *)"
    for version in ${versions[@]}; do
      just build-assets-local-for ${version}
    done

# Publish assets to OCI registry
[group('Release')]
publish-assets VERSION:
    #!/usr/bin/env bash
    if [[ -e providers/openstack/out/{{ replace(VERSION, ".", "-") }} ]]; then
      if [[ -n ${OCI_REGISTRY} && \ 
            -n ${OCI_REPOSITORY} && \
            (( -n ${OCI_USERNAME} && -n ${OCI_PASSWORD} ) || -n ${OCI_ACCESS_TOKEN} ) ]]; then
        csctl create -m hash --publish --remote oci providers/openstack/out/{{ replace(VERSION, ".", "-") }}/
      else
        echo "Please define OCI_* Variables in just.env"
      fi
    else
      echo "Manifest directory for {{ replace(VERSION, ".", "-") }}" does not exist.
    fi

# Publish all available assets to OCI registry
[group('Release')]
publish-assets-all:
    #!/usr/bin/env bash
    set -euo pipefail
    versions="$(cd providers/openstack/out/ && echo *)"
    for version in ${versions[@]}; do
      just publish-assets ${version}
    done

# Publish new release of providers/openstack/scs
[group('Release')]
publish-test-release: dependencies
    csctl create -m hash --publish --remote oci providers/openstack/scs/

# Publish new release of providers/openstack/scs
[confirm('Are you sure to publish a new stable release? (y|n)')]
[group('Release')]
publish-release: dependencies
    csctl create --publish --remote oci providers/openstack/scs/

# Remove old branches that had been merged to main
[group('git')]
git-clean:
    git branch --merged | grep -Ev "(^\*|^\+|^release/\+|main)" | xargs --no-run-if-empty git branch -d

# Create chore branch and PR for specific Kubernetes Version
[group('git')]
git-chore-branch VERSION: && (gh-create-chore-pr VERSION)
    #!/usr/bin/env bash
    set -euo pipefail
    currentBranch=$(git branch --show-current)
    if git show-ref -q  --branches {{ workingBranchPrefix }}{{ replace(VERSION, "-", ".") }}; then
      # Switch to branch if it exists
      git switch {{ workingBranchPrefix }}{{ replace(VERSION, "-", ".") }}
    else
      # Create branch and switch to it
      git switch -c {{ workingBranchPrefix }}{{ replace(VERSION, "-", ".") }}
    fi
    cp -r providers/openstack/out/{{ replace(VERSION, ".", "-") }}/* providers/openstack/scs/
    git add providers/openstack/scs/
    git commit -s -m "chore(versions): Update Release for {{ replace(VERSION, "-", ".") }}"
    git push --set-upstream origin {{ workingBranchPrefix }}{{ replace(VERSION, "-", ".") }}
    git switch ${currentBranch}

# Create chore branches for all available out versions
[group('git')]
git-chore-branches-all:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! [[ -e providers/openstack/out ]]; then
       echo "Error: out directory does not exists."
    else
       pushd providers/openstack/out
       versions=$(echo *)
       popd
       for version in ${versions[@]}; do
         just git-chore-branch $version
       done
    fi
# Login to Github with GitHub CLI
[group('GitHub')]
gh-login GH_TOKEN="${GH_TOKEN}":
    #!/usr/bin/env bash
    set -euo pipefail
    if ! which gh >/dev/null 2>&1; then
      echo "GitHub CLI not installed."
    else
      if ! gh auth status >/dev/null 2>&1; then
        gh config set -h github.com git_protocol https
        # If TOKEN is empty use WebUI Authentication
        if [[ -z $GH_TOKEN ]]; then
          gh auth login --hostname github.com
        else
          echo $GH_TOKEN | gh auth login --hostname github.com --with-token
        fi
      fi
    fi

# Create chore PR for given VERSION against correspondend release branch
[group('GitHub')]
gh-create-chore-pr VERSION: gh-login
    #!/usr/bin/env bash
    set -euo pipefail
    if ! which gh >/dev/null 2>&1; then
      echo "GitHub CLI not installed."
    else
      gh pr --title "chore(versions): Update Release for {{ replace(VERSION, "-", ".") }}" \
            --head {{ workingBranchPrefix }}{{ replace(VERSION, "-", ".") }} \
            --base {{ targetBranchPrefix }}{{ replace(VERSION, "-", ".") }} \
            --dry-run
    fi

# UNTESTED RECIPE: Create Cluster Stack on Cluster for given Version at $PATH in ./release
[group('Test')]
create-clusterstack PATH:
    #!/usr/bin/env bash
    set -euo pipefail
    # Given directory name
    directory_name=".release/$PATH"

    # Extract parts from the directory name
    IFS='/' read -ra PARTS <<<"$directory_name"
    IFS='-' read -ra PARTS <<<"${PARTS[1]}"

    provider="${PARTS[0]}"
    name="${PARTS[1]}"
    kubernetes_major_version="${PARTS[2]}"
    kubernetes_minor_version="${PARTS[3]}"
    version="${PARTS[4]}-${PARTS[5]}.${PARTS[6]}"
    channel="custom"

    if [[ -z ${PARTS[6]} ]]; then
      version="${PARTS[4]}"
      channel="stable"
    fi

    Create the YAML structure
    clusterstack_yaml=$(cat <<-EOF
      ---
      apiVersion: clusterstack.x-k8s.io/v1alpha1
      kind: ClusterStack
      metadata:
        name: ${provider}-${name}-${kubernetes_major_version}-${kubernetes_minor_version}
      spec:
        provider: ${provider}
        name: ${name}
        kubernetesVersion: "${kubernetes_major_version}.${kubernetes_minor_version}"
        channel: ${channel}
        autoSubscribe: false
        providerRef:
          apiVersion: infrastructure.clusterstack.x-k8s.io/v1alpha1
          kind: OpenStackClusterStackReleaseTemplate
          name: cspotemplate
        versions:
        - ${version}
      EOF
    )

    echo "$clusterstack" | kubectl apply -f -

# UNTESTED RECIPE: Check on Cluster Stack creation
[group('Test')]
check-clusterstack NAME:
    #!/usr/bin/env bash
    set -euo pipefail
    declare -i RETRIES
    RETRIES=20
    declare -i INTERVAL
    INTERVAL=5
    # TODO: Refine Status Command
    STATUS_CMD="kubectl get clusterstack -n $ ${NAME} -ojson | jq .status"
    while (( $RETRIES > 0 )); do
      RETRIES-=1
      if ${STATUS_CMD}; then
        STATUS=$(${STATUS_CMD})
        if true; then
          echo "Clusterstack creation successful."
          break
        else
          echo "waiting for Cluster Stack creation"
        fi
      fi
      sleep $INTERVAL
    done

# UNTESTED RECIPE: Create Test Cluster for Kubernetes VERSION and Cluster CLASS
[group('Test')]
create-cluster VERSION CLASS:
    #!/usr/bin/env bash
    set -euo pipefail
    cluster_manifest=$(cat <<-EOF
      ---
      apiVersion: cluster.x-k8s.io/v1beta1
      kind: Cluster
      metadata:
        name: cs-cluster
        labels:
          managed-secret: cloud-config
      spec:
        topology:
          class: {{ CLASS }}
          controlPlane:
            replicas: 1
          version: v{{ VERSION }}
          workers:
            machineDeployments:
              - class: default-worker
                name: md-0
                replicas: 1
      EOF
    )
    echo "${cluster_manifest}" | kubectl apply -f -
