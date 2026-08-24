#!/bin/bash
set -euo pipefail

# Watches the k8s cluster directly (no SSH, independent of OSM) to time how
# long it takes for OSM to actually get the p4-switch NF running, once
# ../orchestrator.sh tells OSM to instantiate the p4_iperf_scenario_ns NS.
#
# This is the "cluster" half of the two-step timing experiment: it measures
# ground truth on the cluster OSM deployed to, as opposed to what OSM
# itself reports (../orchestrator.sh). Start this before/alongside
# ../orchestrator.sh so it's already watching when OSM creates the pod.
#
# "Running"/"Ready" isn't a reliable completion signal by itself: the
# container first fetches and compiles the configured P4 program (a
# variable-length step) before starting simple_switch, so the pod can be
# Running well before the switch is actually up. This instead waits for the
# "Starting simple_switch" log line the entrypoint prints right before
# exec'ing it (see
# src/osm/p4_switch_knf/helm-charts/templates/configmap-scripts.yaml).

POD_LABEL="app.kubernetes.io/name=p4-switch" # stable selector label from the p4-switch chart, regardless of OSM's release name
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}" # seconds, used for both `kubectl wait` and log matching

WORKDIR="$(mktemp -d)"
SWITCH_LOG="${WORKDIR}/switch.log"
LOG_PID=""

cleanup() {
    [ -n "$LOG_PID" ] && kill "$LOG_PID" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> Waiting for OSM to deploy the p4-switch pod and starting timer..."

START_TIME=$(date +%s%N)

# OSM picks the pod's namespace/name itself, so discover it by the chart's
# selector label instead of a fixed name.
POD=""
NAMESPACE=""
while [ -z "$POD" ]; do
    read -r NAMESPACE POD <<<"$(kubectl get pods --all-namespaces \
        -l "$POD_LABEL" \
        -o jsonpath='{range .items[0]}{.metadata.namespace} {.metadata.name}{end}')"
    [ -n "$POD" ] || sleep 1
done
echo "Found pod: ${NAMESPACE}/${POD}"

kubectl wait \
    --namespace="$NAMESPACE" \
    --for=condition=Ready \
    "pod/${POD}" \
    --timeout="${WAIT_TIMEOUT}s"

# Start following logs only from this point on (--tail=0): the readiness
# check above ensures the container is already streamable, and happens well
# before the P4 program finishes compiling, so no log lines are missed.
: > "$SWITCH_LOG"
kubectl logs -f --tail=0 --namespace="$NAMESPACE" "$POD" >>"$SWITCH_LOG" 2>&1 &
LOG_PID="$!"

# `tail -F` feeds `grep` via process substitution rather than a literal `|`
# pipe on purpose: `grep -m1` exits as soon as it finds a match, which sends
# `tail -F` a SIGPIPE and makes it exit non-zero. With `pipefail` set, that
# would make the pipeline report failure even though grep matched
# successfully. Process substitution keeps tail's exit status out of the
# `timeout`/`grep` status we actually check.
if ! timeout "$WAIT_TIMEOUT" grep --line-buffered -q -m1 -F "Starting simple_switch" < <(tail -n +1 -F "$SWITCH_LOG"); then
    echo "Error: timed out after ${WAIT_TIMEOUT}s waiting for simple_switch to start." >&2
    exit 1
fi

END_TIME=$(date +%s%N)

ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
ELAPSED_SEC=$(awk "BEGIN { printf \"%.3f\", ${ELAPSED_MS} / 1000 }")

echo "--------------------------------------------------"
echo "simple_switch is running in pod '${NAMESPACE}/${POD}'!"
echo "Cluster-observed deployment time: ${ELAPSED_SEC} seconds (${ELAPSED_MS} ms)"
echo "--------------------------------------------------"
