
KUBERNETES_VERSION=$(basename $(pwd))
KUBERNETES_VERSION_DOT=$(echo $KUBERNETES_VERSION | sed 's/-/\./')
CLUSTER_STACK_NAME=$(basename $(dirname $(pwd)))
PROVIDER=$(basename $(dirname $(dirname $(pwd))))
VERSION=v$1

cat -  > metadata.yaml <<EOT
apiVersion: metadata.clusterstack.x-k8s.io/v1alpha1
versions:
  clusterStack: $VERSION
  kubernetes: v1.27.3
  components:
    clusterAddon: $VERSION
    nodeImage: $VERSION
EOT

yq -i '.version=env(VERSION)' cluster-class/Chart.yaml
yq -i '.version=env(VERSION)' cluster-addon/Chart.yaml
mkdir -p cluster-stacks/$PROVIDER-$CLUSTER_STACK_NAME-$KUBERNETES_VERSION-$VERSION
tar czf cluster-stacks/$PROVIDER-$CLUSTER_STACK_NAME-$KUBERNETES_VERSION-$VERSION/$PROVIDER-$CLUSTER_STACK_NAME-$KUBERNETES_VERSION-cluster-addon-$VERSION.tgz cluster-addon
cp cluster-addon-values.yaml cluster-stacks/$PROVIDER-$CLUSTER_STACK_NAME-$KUBERNETES_VERSION-$VERSION/
tar czf cluster-stacks/$PROVIDER-$CLUSTER_STACK_NAME-$KUBERNETES_VERSION-$VERSION/$PROVIDER-$CLUSTER_STACK_NAME-$KUBERNETES_VERSION-cluster-class-$VERSION.tgz cluster-class
cp metadata.yaml cluster-stacks/$PROVIDER-$CLUSTER_STACK_NAME-$KUBERNETES_VERSION-$VERSION/


POD_NAME=$(kubectl get pod -n cso-system --no-headers -o custom-columns=name:.metadata.name)
kubectl cp cluster-stacks -n cso-system $POD_NAME:/tmp
kubectl delete pod -n cso-system $POD_NAME

kubectl apply -f  - <<EOT
apiVersion: clusterstack.x-k8s.io/v1alpha1
kind: ClusterStack
metadata:
  name: $CLUSTER_STACK_NAME
  namespace: my-tenant
spec:
  provider: $PROVIDER
  name: $CLUSTER_STACK_NAME
  kubernetesVersion: "$KUBERNETES_VERSION_DOT"
  channel: stable
  autoSubscribe: false
  noProvider: true
  versions:
    - $VERSION
EOT
