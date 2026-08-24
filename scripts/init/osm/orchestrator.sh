#!/bin/bash
set -euo pipefail

# Runs on OSM_HOST (piped in over SSH by ../main.sh) to register the newly
# provisioned k8s cluster with OSM. The kubeconfig has already been copied to
# REMOTE_KUBECONFIG by ../main.sh; it is removed after use since it contains
# cluster credentials.

CLUSTER_NAME="${1:?cluster name not provided}"
K8S_VERSION="${2:?k8s version not provided}"
REMOTE_KUBECONFIG="${3:?remote kubeconfig path not provided}"

trap 'rm -f "$REMOTE_KUBECONFIG"' EXIT

echo "==> Creating dummy VIM 'iml-testbed-vim' in OSM..."
osm vim-create \
  --name iml-testbed-vim \
  --user u \
  --password p \
  --tenant p \
  --account_type dummy \
  --auth_url http://localhost/dummy

echo "==> Registering k8s cluster '${CLUSTER_NAME}' with OSM..."
osm k8scluster-add "$CLUSTER_NAME" \
  --creds "$REMOTE_KUBECONFIG" \
  --version "$K8S_VERSION" \
  --vim iml-testbed-vim \
  --k8s-nets '{"k8s_net1":null}' \
  --wait
