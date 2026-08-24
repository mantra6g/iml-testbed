#!/bin/bash
set -euo pipefail

# This script tears down the testbed environment.
# It cleans up OSM resources (NS instances, then their NF/NS packages, then
# the registered k8s cluster) before destroying the underlying infrastructure
# with Terraform. Order matters: NS instances must be deleted before their
# packages can be, and packages must be deleted before the k8s cluster they
# ran on can be deregistered.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/../../terraform" && pwd)"

: "${OSM_HOST:?OSM_HOST is not set. Did you fill in .env?}"
: "${OSM_HOST_USER:?OSM_HOST_USER is not set. Did you fill in .env?}"
: "${CLUSTER_NAME_IN_OSM:?CLUSTER_NAME_IN_OSM is not set. Did you fill in .env?}"

echo "==> Cleaning up OSM resources on ${OSM_HOST}..."
if ! ssh "${OSM_HOST_USER}@${OSM_HOST}" bash -l -s -- "${CLUSTER_NAME_IN_OSM}" < "${SCRIPT_DIR}/osm/orchestrator.sh"; then
  echo "Error: failed to clean up OSM resources. See the output above for details." >&2
  exit 1
fi

echo "==> Running terraform destroy..."
if ! terraform -chdir="${TERRAFORM_DIR}" destroy; then
  echo "Error: terraform destroy failed. See the output above for details." >&2
  exit 1
fi

echo "==> Testbed destroyed successfully."
