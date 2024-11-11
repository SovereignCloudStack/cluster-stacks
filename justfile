# use with https://github.com/casey/just
#
# Cluster Stack Creation automation
#

set export
set dotenv-filename := "just.env"
set dotenv-load

path := env_var('PATH') + ":" + justfile_directory() + "/bin"

default:
  @just --list --justfile {{justfile()}}

# Check if csctl and clusterstack-provider-openstack are available and build them if neccessary
[no-cd]
ensure-dependencies:
  #!/usr/bin/env bash
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

  if [[ -d bin ]]; then
    export PATH="${PATH}:$(pwd)/bin"
  fi

# Clean temporary files and binaries
clean:
  #!/usr/bin/env bash
  rm -rf bin

# Build Clusterstacks version
build: ensure-dependencies
  ./hack/generate_version.py --build
