#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

echo '--> Starting Cleanup.'
# Ensure we don't leave SSH host keys
rm -rf /etc/ssh/ssh_host_*

# Performs cleanup of temporary files for the currently enabled repositories.
export DEBIAN_FRONTEND=noninteractive
apt -y autoremove
apt -y clean all