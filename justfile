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

# Show available commands
default:
    @just --list --justfile {{ justfile() }}

# Show available commands
help: default

# Check if csctl and clusterstack-provider-openstack are available and build them if neccessary
[no-cd]
ensure-dependencies:
    #!/usr/bin/env bash
    set -euxo pipefail
    export PATH=${path}
    if ! which csctl >/dev/null 2>&1;then
      echo "csctl not found, building it from source."
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
      echo "csctl-plugin-openstack not found, building it from source."
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
      mkdir -p bin
      wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O bin/yq &&\
    chmod +x bin/yq
    fi

# Clean temporary files and binaries
[no-cd]
clean:
    rm -rf bin

# Build Clusterstacks version directories according to changes in versions.yaml. Builds out directoy
[no-cd]
build-versions: ensure-dependencies
    #!/usr/bin/env bash
    changedVersions=$(just diff)
    for version in ${changedVersions[@]}; do
      ./hack/generate_version.py --target-version ${version}
    done

# Generate manifest for all Kubernetes Version regardless of changes to versions.
[no-cd]
build-versions-all: ensure-dependencies
    ./hack/generate_version.py --build

# Generate Manifest for a specific Kubernetes version. Builds out directory
[no-cd]
build-version VERSION:
    ./hack/generate_version.py --target-version {{VERSION}}

# Build assets for a certain Kubernetes Version. Out directory needs to be present.
[no-cd]
build-assets-local-for VERSION: ensure-dependencies
    csctl create -m hash providers/openstack/out/{{replace(VERSION, ".", "-")}}/

# Build assets for a certain Kubernetes Version. Out directory needs to be present.
[no-cd]
build-assets-local: ensure-dependencies
    #!/usr/bin/env bash
    export PATH=${path}
    changedVersions=$(just diff)
    for version in ${changedVersions[@]}; do
      csctl create -m hash providers/openstack/out/${version//./-}/
    done

# Calculate the diff in the versions.yaml files to get relevant versions
[no-cd]
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
