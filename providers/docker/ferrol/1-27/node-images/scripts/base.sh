#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

echo '--> Starting Base Installation.'
# Set locale
# localectl set-locale LANG=en_US.UTF-8
# localectl set-locale LANGUAGE=en_US.UTF-8

# Suppress "WARNING: apt does not have a stable CLI interface. Use with caution in scripts."
echo 'Binary::apt::Apt::Cmd::Disable-Script-Warning "true";' >/etc/apt/apt.conf.d/disable-script-warning
export DEBIAN_FRONTEND=noninteractive

# update all packages
apt update -y && apt -y upgrade && apt -y dist-upgrade

# install basic tooling
apt -y install \
    at jq unzip wget socat mtr logrotate apt-transport-https network-manager

# Install yq
YQ_VERSION=v4.30.5 #https://github.com/mikefarah/yq
YQ_BINARY=yq_linux_amd64
wget -q https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY} -O /usr/bin/yq &&
    chmod +x /usr/bin/yq

echo '--> Starting Base Configuration.'

## disable swap
sed -i '/swap/d' /etc/fstab
