#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

ETCD_VER=v3.5.9 #https://github.com/etcd-io/etcd/releases
mkdir -p /tmp/etcd-download-test
curl -sSL https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz -C /tmp/etcd-download-test --strip-components=1
mv /tmp/etcd-download-test/etcdctl /usr/local/sbin/etcdctl && chmod +x /usr/local/sbin/etcdctl
rm -f /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
rm -rf /tmp/etcd-download-test

mkdir -p /var/lib/etcd
chmod 700 /var/lib/etcd
