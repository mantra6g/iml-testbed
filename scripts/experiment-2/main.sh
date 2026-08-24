#!/bin/bash
set -euo pipefail

# Runs the full experiment-2 comparison: first the IML experiment
# (iml/cluster.sh, run over SSH on the control-plane node so it talks to
# the in-cluster IML CRD directly), then the OSM experiment
# (osm/orchestrator.sh, run over SSH on the OSM host). Reports how long
# each stage took.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/../../terraform" && pwd)"

: "${OSM_HOST:?OSM_HOST is not set. Did you fill in .env?}"
: "${OSM_HOST_USER:?OSM_HOST_USER is not set. Did you fill in .env?}"
: "${REPO_URL:?REPO_URL is not set. Did you fill in .env?}"

echo "==> Reading control-plane connection details from Terraform..."
if ! CONTROL_PLANE_IP="$(terraform -chdir="${TERRAFORM_DIR}" output -raw control_plane_public_ip 2>/dev/null)"; then
  echo "Error: could not read 'control_plane_public_ip' from Terraform output." >&2
  exit 1
fi
if ! SSH_PRIVATE_KEY_PATH="$(terraform -chdir="${TERRAFORM_DIR}" output -raw ssh_private_key_path 2>/dev/null)"; then
  echo "Error: could not read 'ssh_private_key_path' from Terraform output." >&2
  exit 1
fi

echo "==> Running the IML experiment on the control-plane node..."
IML_START=$(date +%s%N)
if ! ssh -i "${SSH_PRIVATE_KEY_PATH}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "ubuntu@${CONTROL_PLANE_IP}" bash -s -- "${REPO_URL}" < "${SCRIPT_DIR}/iml/cluster.sh"; then
  echo "Error: the IML experiment failed. See the output above for details." >&2
  exit 1
fi
IML_END=$(date +%s%N)
IML_ELAPSED_MS=$(( (IML_END - IML_START) / 1000000 ))

echo "==> Running the OSM experiment on ${OSM_HOST}..."
OSM_START=$(date +%s%N)
if ! ssh "${OSM_HOST_USER}@${OSM_HOST}" bash -l -s -- < "${SCRIPT_DIR}/osm/orchestrator.sh"; then
  echo "Error: the OSM experiment failed. See the output above for details." >&2
  exit 1
fi
OSM_END=$(date +%s%N)
OSM_ELAPSED_MS=$(( (OSM_END - OSM_START) / 1000000 ))

TOTAL_ELAPSED_MS=$(( IML_ELAPSED_MS + OSM_ELAPSED_MS ))

echo "--------------------------------------------------"
echo "Experiment-2 timing results:"
echo "IML experiment time:   $(awk "BEGIN { printf \"%.3f\", ${IML_ELAPSED_MS} / 1000 }") seconds (${IML_ELAPSED_MS} ms)"
echo "OSM experiment time:   $(awk "BEGIN { printf \"%.3f\", ${OSM_ELAPSED_MS} / 1000 }") seconds (${OSM_ELAPSED_MS} ms)"
echo "Total time:            $(awk "BEGIN { printf \"%.3f\", ${TOTAL_ELAPSED_MS} / 1000 }") seconds (${TOTAL_ELAPSED_MS} ms)"
echo "--------------------------------------------------"
