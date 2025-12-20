#!/usr/bin/env bash

# Usage: Just list the version as arguments
# Example: ./generate_openstack_image_manager_yaml.sh 1.33.5 1.32.0 1.32.2

BASE_URL="https://nbg1.your-objectstorage.com/osism/openstack-k8s-capi-images/ubuntu-2404-kube"

get_checksum() {
    local version=$1
    local checksum_url="${BASE_URL}-v${version%.*}/ubuntu-2404-kube-v${version}.qcow2.CHECKSUM"
    curl -s "$checksum_url" | awk '{print $1}'
}

generate_version_entry() {
    local version=$1
    local checksum=$2
    local build_date=$3

    cat <<EOF
      - version: 'v${version}'
        url: ${BASE_URL}-v${version%.*}/ubuntu-2404-kube-v${version}.qcow2
        checksum: "sha256:${checksum}"
        build_date: ${build_date}
EOF
}

echo "---
images:
  - name: ubuntu-capi-image
    enable: true
    format: raw
    login: ubuntu
    min_disk: 20
    min_ram: 1024
    status: active
    visibility: public
    multi: false
    separator: \"-\"
    meta:
      architecture: x86_64
      hw_disk_bus: virtio
      hw_rng_model: virtio
      hw_scsi_model: virtio-scsi
      hw_watchdog_action: reset
      hypervisor_type: qemu
      os_distro: ubuntu
      replace_frequency: never
      uuid_validity: none
      provided_until: none
    tags:
      - clusterstacks
    versions:"

for version in "$@"; do
    checksum=$(get_checksum "$version")
    build_date=$(date +%Y-%m-%d)
    generate_version_entry "$version" "$checksum" "$build_date"
done
