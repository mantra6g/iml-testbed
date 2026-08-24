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

IML_LOG="$(mktemp)"
OSM_LOG="$(mktemp)"
trap 'rm -f "$IML_LOG" "$OSM_LOG"' EXIT

# cluster.sh and orchestrator.sh each time themselves precisely (nanosecond
# `date`, on the remote Linux host) and print a trailing "(<N> ms)" on their
# own elapsed-time line. Extracting that instead of timing the SSH round
# trip locally avoids attributing SSH connection setup, git clone, etc. to
# the deployment time, and sidesteps the fact that this may run on macOS,
# where `date` doesn't support nanosecond precision at all.
extract_elapsed_ms() {
  local log_file="$1"
  local ms
  ms="$(grep -oE '\([0-9]+ ms\)' "$log_file" | tail -n1 | grep -oE '[0-9]+' || true)"
  if [ -z "$ms" ]; then
    echo "Error: could not find an elapsed-time line '(<N> ms)' in the output captured in ${log_file}." >&2
    exit 1
  fi
  echo "$ms"
}

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
if ! ssh -i "${SSH_PRIVATE_KEY_PATH}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "ubuntu@${CONTROL_PLANE_IP}" bash -s -- "${REPO_URL}" < "${SCRIPT_DIR}/iml/cluster.sh" | tee "$IML_LOG"; then
  echo "Error: the IML experiment failed. See the output above for details." >&2
  exit 1
fi
IML_ELAPSED_MS="$(extract_elapsed_ms "$IML_LOG")"

echo "==> Running the OSM experiment on ${OSM_HOST}..."
if ! ssh "${OSM_HOST_USER}@${OSM_HOST}" bash -l -s -- < "${SCRIPT_DIR}/osm/orchestrator.sh" | tee "$OSM_LOG"; then
  echo "Error: the OSM experiment failed. See the output above for details." >&2
  exit 1
fi
OSM_ELAPSED_MS="$(extract_elapsed_ms "$OSM_LOG")"

TOTAL_ELAPSED_MS=$(( IML_ELAPSED_MS + OSM_ELAPSED_MS ))

echo "--------------------------------------------------"
echo "Experiment-2 timing results:"
echo "IML experiment time:   $(awk "BEGIN { printf \"%.3f\", ${IML_ELAPSED_MS} / 1000 }") seconds (${IML_ELAPSED_MS} ms)"
echo "OSM experiment time:   $(awk "BEGIN { printf \"%.3f\", ${OSM_ELAPSED_MS} / 1000 }") seconds (${OSM_ELAPSED_MS} ms)"
echo "Total time:            $(awk "BEGIN { printf \"%.3f\", ${TOTAL_ELAPSED_MS} / 1000 }") seconds (${TOTAL_ELAPSED_MS} ms)"
echo "--------------------------------------------------"
