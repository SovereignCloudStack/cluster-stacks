#!/usr/bin/env bash

# Make sure we are operating in the correct directory, exit otherwise

ls ./../../../../providers/ > /dev/null 2>&1|| ( echo "Are you in the correct directory? This script has to be executed in cluster-stacks/providers/x/y/z where x is the provider, y is the name of the cluster-stack and z the kubernetes version." && exit 1 )

# Check metadata.yaml, all versions have to be the same (guess, see also https://github.com/SovereignCloudStack/cluster-stacks/issues/10)

CLUSTER_STACK_VERSION=$(yq '.versions.clusterStack' metadata.yaml)
CLUSTER_ADDON_VERSION=$(yq '.versions.components.clusterAddon' metadata.yaml)
NODE_IMAGE_VERSION=$(yq '.versions.components.nodeImage' metadata.yaml)

if [[ ! ( "$CLUSTER_STACK_VERSION" == "$CLUSTER_ADDON_VERSION" && "$CLUSTER_STACK_VERSION" == "$NODE_IMAGE_VERSION" ) ]]
then
    echo "Error in metadata.yaml, .versions.clusterStack, .versions.components.clusterAddon and .versions.components.nodeImage have to be equal."
    exit 2
fi



# Make sure that node-images, cluster-addons, cluster-class and metadata.yaml are commited, exit otherwise

for i in cluster-addon cluster-class metadata.yaml node-images.yaml
do
    git status --porcelain .| grep $i > /dev/null 2>&1 && echo "Please make sure that all relevant files are commited before running this script. $i is not commited yet" && exit 3
done





# Get relevant strings and construct release name
KUBERNETES_VERSION=$(basename $(pwd))
CLUSTER_STACK_NAME=$(basename $(dirname $(pwd)))
PROVIDER=$(basename $(dirname $(dirname $(pwd))))
RELEASE_NAME=$PROVIDER-$CLUSTER_STACK_NAME-$KUBERNETES_VERSION-$CLUSTER_STACK_VERSION

# Check if release already exists
if gh release view $RELEASE_NAME > /dev/null 2>&1
then
    echo "It seems that release $RELEASE_NAME already exists, please create a new one by increasing the version number in metadata.yaml."
    exit 4
fi

# Create temporary local assets (cluster-class.tgz, cluster-addon.tgz)
CLUSTER_ADDON_ASSET=$PROVIDER-$CLUSTER_STACK_NAME-$KUBERNETES_VERSION-cluster-addon-$CLUSTER_STACK_VERSION.tgz
CLUSTER_CLASS_ASSET=$PROVIDER-$CLUSTER_STACK_NAME-$KUBERNETES_VERSION-cluster-class-$CLUSTER_STACK_VERSION.tgz
tar czf $CLUSTER_ADDON_ASSET cluster-addon
tar czf $CLUSTER_CLASS_ASSET cluster-class

# Generate release with mandatory assets
if ! gh release create $RELEASE_NAME --generate-notes metadata.yaml --target $(git rev-parse HEAD) $CLUSTER_ADDON_ASSET $CLUSTER_CLASS_ASSET
then 
    echo "Error while creating release, have you already pushed your state?"
    rm $CLUSTER_ADDON_ASSET $CLUSTER_CLASS_ASSET
    exit 5
fi
# Remove temporary local assets
rm $CLUSTER_ADDON_ASSET $CLUSTER_CLASS_ASSET

# Add optional assets
if test -f node-images.yaml
then
    gh release upload $RELEASE_NAME node-images.yaml
fi
if test -f cluster-addon-values.yaml
then
    gh release upload $RELEASE_NAME cluster-addon-values.yaml
fi
