# use with https://github.com/casey/just
#
# Cluster Stack Creation automation
#

set export := true
set dotenv-filename := "just.env"
set dotenv-load := true

path := env_var('PATH') + ":" + justfile_directory() + "/bin"
repo := "https://github.com/SovereignCloudStack/cluster-stacks"
mainBranch := "main"
workingBranchPrefix := "chore/update-"
targetBranchPrefix := "release-"

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
    export PATH=${path}
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
    set -euxo pipefail
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
    changedVersions=$(just diff)
    for version in ${changedVersions[@]}; do
      just build-version ${version}
    done

# Generate manifest for all Kubernetes Version regardless of changes to versions.
[group('Building Manifests')]
build-versions-all: dependencies
    #!/usr/bin/env bash
    set -euxo pipefail
    versionsPath="providers/openstack/scs/versions.yaml"
    currentVersions=$(cat ${versionsPath})
    kubernetesVersions=$(yq -r '.[].kubernetes' ${versionsPath} | grep -Po "1\.\d+")
    for version in ${kubernetesVersions}; do
      just build-version ${version}
    done

# Generate Manifest for a specific Kubernetes version. Builds out directory
[group('Building Manifests')]
build-version VERSION:
    #!/usr/bin/env bash
    set -euxo pipefail
    echo -e "\e[33m\e[1mBuild Manifests for {{ VERSION }}\e[0m"
    ## CHECK IF THERE IS A CHANGE IN THE COMPONENT VERSIONS
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
[group('Building Assets')]
build-assets-local: build-versions
    #!/usr/bin/env bash
    export PATH=${path}
    changedVersions=$(just diff)
    for version in ${changedVersions[@]}; do
      just build-assets-local-for ${version}
    done

# Build assets for a certain Kubernetes Version.
[group('Building Assets')]
build-assets-all-local: build-versions-all
    #!/usr/bin/env bash
    export PATH=${path}
    set -euxo pipefail
    versions="$(cd providers/openstack/out/ && echo *)"
    for version in ${versions[@]}; do
      just build-assets-local-for ${version}
    done

# Remove old branches that had been merged to main 
[group('git')]
git-clean:
    git branch --merged | grep -Ev "(^\*|^\+|master|main|dev)" | xargs --no-run-if-empty git branch -d

# Create Chore branch for specific Kubernetes Version
[group('git')]
git-chore-branch VERSION:
    #!/usr/bin/env bash
    currentBranch=$(git branch --show-current)
    git switch -c chore/update-{{replace(VERSION, "-", ".") }}
    cp -r providers/openstack/out/{{replace(VERSION, ".", "-") }}/* providers/openstack/scs/
    git add providers/openstack/scs/
    git commit -s -S -m "chore(versions): Update Release for {{replace(VERSION, "-", ".") }}"
    #git push
    git switch ${currentBranch}

# Create chore branches for all available out versions
[group('git')]
git-chore-branches-all:
    #!/usr/bin/env bash
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
