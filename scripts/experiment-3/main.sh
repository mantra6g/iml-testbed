#!/bin/bash
set -euo pipefail

# Runs the full experiment-3 comparison: first the IML experiment
# (iml/cluster.sh, run over SSH on the control-plane node so it talks to
# the in-cluster IML CRD directly), then the OSM experiment. The OSM side
# is split into SSH stages on OSM_HOST: "create" provisions the NS,
# "reconfigure" times how long OSM itself takes to apply a KDU upgrade to
# it, then "delete" tears it back down. Reports how long each stage took.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/../../terraform" && pwd)"

: "${OSM_HOST:?OSM_HOST is not set. Did you fill in .env?}"
: "${OSM_HOST_USER:?OSM_HOST_USER is not set. Did you fill in .env?}"
: "${REPO_URL:?REPO_URL is not set. Did you fill in .env?}"

IML_LOG="$(mktemp)"
OSM_LOG="$(mktemp)"
trap 'rm -f "$IML_LOG" "$OSM_LOG"' EXIT

# iml/cluster.sh and osm/orchestrator.sh each time themselves precisely
# (nanosecond `date`, on their own remote Linux host) and print a trailing
# "(<N> ms)" on their own elapsed-time line, which is always the first such
# line in the log -- experiment-2's orchestrator.sh also prints a per-stage
# timing breakdown after its own elapsed-time line, whose "(<N> ms)" lines
# would be mismatched by `tail -n1`; `head -n1` is used here too for
# consistency and to stay safe if a breakdown like that is ever added here
# too. Extracting this instead of timing the SSH round trip locally avoids
# attributing SSH connection setup, git clone, etc. to the deployment
# time, and sidesteps the fact that this may run on macOS, where `date`
# doesn't support nanosecond precision at all.
extract_elapsed_ms() {
  local log_file="$1"
  local ms
  ms="$(grep -oE '\([0-9]+ ms\)' "$log_file" | head -n1 | grep -oE '[0-9]+' || true)"
  if [ -z "$ms" ]; then
    echo "Error: could not find an elapsed-time line '(<N> ms)' in the output captured in ${log_file}." >&2
    exit 1
  fi
  echo "$ms"
}

extract_ns_id() {
  local log_file="$1"
  local ns_id
  ns_id="$(grep -oE 'NS_ID: [0-9a-fA-F-]+' "$log_file" | tail -n1 | cut -d' ' -f2)"
  if [ -z "$ns_id" ]; then
    echo "Error: could not find a 'NS_ID: <uuid>' line in the output captured in ${log_file}." >&2
    exit 1
  fi
  echo "$ns_id"
}

delete_ns() {
  local ns_id="$1"
  echo "==> Deleting NS instance on ${OSM_HOST}..."
  if ! "${OSM_HOST_SSH[@]}" delete "$ns_id" < "${SCRIPT_DIR}/osm/orchestrator.sh"; then
    echo "Error: could not delete NS instance '${ns_id}'. Clean it up manually with 'osm ns-delete ${ns_id} --wait'." >&2
    return 1
  fi
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

CONTROL_PLANE_SSH=(ssh -i "${SSH_PRIVATE_KEY_PATH}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "ubuntu@${CONTROL_PLANE_IP}")
OSM_HOST_SSH=(ssh "${OSM_HOST_USER}@${OSM_HOST}" bash -l -s --)

echo "==> Running the IML experiment on the control-plane node..."
if ! "${CONTROL_PLANE_SSH[@]}" bash -s -- "${REPO_URL}" < "${SCRIPT_DIR}/iml/cluster.sh" | tee "$IML_LOG"; then
  echo "Error: the IML experiment failed. See the output above for details." >&2
  exit 1
fi
IML_ELAPSED_MS="$(extract_elapsed_ms "$IML_LOG")"

echo "==> Creating the NS on ${OSM_HOST}..."
if ! "${OSM_HOST_SSH[@]}" create < "${SCRIPT_DIR}/osm/orchestrator.sh" | tee "$OSM_LOG"; then
  echo "Error: the OSM 'create' stage failed. See the output above for details." >&2
  exit 1
fi
NS_ID="$(extract_ns_id "$OSM_LOG")"

echo "==> Reconfiguring the NS on ${OSM_HOST}..."
if ! "${OSM_HOST_SSH[@]}" reconfigure < "${SCRIPT_DIR}/osm/orchestrator.sh" | tee "$OSM_LOG"; then
  delete_ns "$NS_ID" || true
  echo "Error: the OSM 'reconfigure' stage failed. See the output above for details." >&2
  exit 1
fi
OSM_ELAPSED_MS="$(extract_elapsed_ms "$OSM_LOG")"

if ! delete_ns "$NS_ID"; then
  exit 1
fi


echo "--------------------------------------------------"
echo "Experiment-3 timing results:"
echo "IML experiment time:          $(awk "BEGIN { printf \"%.3f\", ${IML_ELAPSED_MS} / 1000 }") seconds (${IML_ELAPSED_MS} ms)"
echo "OSM experiment time:          $(awk "BEGIN { printf \"%.3f\", ${OSM_ELAPSED_MS} / 1000 }") seconds (${OSM_ELAPSED_MS} ms)"
echo "--------------------------------------------------"
