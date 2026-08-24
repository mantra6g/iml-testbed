#!/bin/bash
set -euo pipefail

# Runs on OSM_HOST (piped in over SSH by ../main.sh) to time how long OSM
# itself takes to instantiate the p4_iperf_scenario_ns NS, from the
# `ns-create` request until OSM reports the NS instance as running.
#
# This is the "orchestrator" half of the two-step timing experiment: OSM is
# a hierarchical orchestrator, so deploying an NF here really means telling
# OSM to deploy it, then separately checking how long the underlying k8s
# resource actually took to come up (../cluster.sh, run directly against
# the cluster OSM deployed to). Comparing the two shows how much overhead
# the orchestration layer adds on top of the raw k8s deployment.

NS_NAME="p4_iperf_scenario_ns"
NSD_NAME="p4_iperf_scenario_ns"
VIM_ACCOUNT="iml-testbed-vim"

UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

echo "==> Creating NS instance '${NS_NAME}' and starting timer..."

START_TIME=$(date +%s%N)

NS_ID="$(osm ns-create \
    --ns_name "$NS_NAME" \
    --nsd_name "$NSD_NAME" \
    --vim_account "$VIM_ACCOUNT" \
    --wait | grep -Eo "$UUID_RE" | tail -n1)"

END_TIME=$(date +%s%N)

ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
ELAPSED_SEC=$(awk "BEGIN { printf \"%.3f\", ${ELAPSED_MS} / 1000 }")

echo "--------------------------------------------------"
echo "NS instance '${NS_ID}' is running!"
echo "OSM-reported deployment time: ${ELAPSED_SEC} seconds (${ELAPSED_MS} ms)"
echo "--------------------------------------------------"

# The NS instance is deliberately left running here: ../cluster.sh (or
# whoever is watching the cluster) still needs it up to observe how long
# the underlying pod takes to actually start simple_switch. Deleting it
# immediately after OSM reports "running" would race with that observation,
# since OSM's own readiness checkpoint can land before the pod's entrypoint
# finishes compiling and starting the switch.
echo "==> NS instance left running for the cluster-side measurement."
echo "    Clean it up afterwards with: osm ns-delete ${NS_ID} --wait"
echo "    (or scripts/destroy/main.sh to tear down the whole testbed)."
