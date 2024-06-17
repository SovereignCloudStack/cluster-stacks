#!/usr/bin/env bash
# ./patch_csx_deployment.sh csx_manifest.yaml HOST_PATH_DIR
#
# Script adjusts CSO or CSPO manifest to use local mode.
# It injects cluster stack release assets via the given HOST_PATH_DIR volume and mount to the CSO or CSPO containers and
# enables local mode for them.

if test -z "$1"; then echo "ERROR: Need CSO or CSPO manifest file arg" 1>&2; exit 1; fi
if test -z "$2"; then echo "ERROR: Need HOST_PATH_DIR arg" 1>&2; exit 1; fi

# Test whether the argument is already present in CSX manager container args
local_mode_exist=$(yq 'select(.kind == "Deployment").spec.template.spec.containers[] | select(.name == "manager").args[] | select(. == "--local=true")' "$1")

if test -z "$local_mode_exist"; then
	echo "Enabling local mode for the CSX manager container"
	yq 'select(.kind == "Deployment").spec.template.spec.containers[] |= select(.name == "manager").args += ["--local=true"]' -i "$1"
else
  echo "Local mode is already enabled in the CSX manager container"
fi

export HOST_PATH_DIR=$2
export VOLUME_SNIPPET=volume_snippet.yaml
export VOLUME_MOUNT_SNIPPET=volume_mount_snippet.yaml

yq --null-input '
  {
    "name": "cluster-stacks-volume",
    "hostPath":
      {
        "path": env(HOST_PATH_DIR),
        "type": "Directory"
      }
  }' > $VOLUME_SNIPPET

yq --null-input '
  {
    "name": "cluster-stacks-volume",
    "mountPath": "/tmp/downloads/cluster-stacks",
    "readOnly": true
  }' > $VOLUME_MOUNT_SNIPPET

# Test whether the mountPath: /tmp/downloads/cluster-stacks is already present in CSX manager container mounts
mount_exist=$(yq 'select(.kind == "Deployment").spec.template.spec.containers[] | select(.name == "manager").volumeMounts[] | select(.mountPath == "/tmp/downloads/cluster-stacks")' "$1")

if test -z "$mount_exist"; then
	echo "Injecting volume and volume mount to the CSX manager container"
	yq 'select(.kind == "Deployment").spec.template.spec.containers[] |= select(.name == "manager").volumeMounts += [load(env(VOLUME_MOUNT_SNIPPET))]' -i "$1"
		yq 'select(.kind == "Deployment").spec.template.spec.volumes += [load(env(VOLUME_SNIPPET))]' -i "$1"
else
  echo "Mount path /tmp/downloads/cluster-stacks is already present in the CSX manager container"
fi

rm $VOLUME_SNIPPET
rm $VOLUME_MOUNT_SNIPPET

exit 0
