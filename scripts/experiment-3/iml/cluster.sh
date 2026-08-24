#!/bin/bash
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
RESOURCE_NAME="pkt-logger"
POD_NAMESPACE="loom-system" # Namespace where the BMv2 target pod is running
DRIVER_CONTAINER="bmv2-driver"
SWITCH_CONTAINER="bmv2-switch"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-120}" # seconds, used for both `kubectl wait` and log matching

WORKDIR="$(mktemp -d)"
DRIVER_LOG="${WORKDIR}/driver.log"
SWITCH_LOG="${WORKDIR}/switch.log"
LOG_PIDS=()

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# Streams a container's logs to a file in the background, starting from the
# moment the pod is Ready. Capturing continuously (rather than starting a
# fresh `kubectl logs -f` right before each wait) avoids a race where a log
# line is emitted between triggering an action and attaching to the stream,
# which would otherwise be silently missed and cause wait_for_log to hang
# forever.
start_log_capture() {
    local container="$1"
    local outfile="$2"

    : > "$outfile"
    kubectl logs -f --tail=0 -n "$POD_NAMESPACE" "$POD" -c "$container" >>"$outfile" 2>&1 &
    LOG_PIDS+=("$!")
}

# Blocks until `message` appears in `file`, or WAIT_TIMEOUT seconds elapse.
# Reads from the beginning of the file, so it also catches messages that
# arrived before this call started waiting.
#
# `tail` feeds `grep` via process substitution rather than a literal `|`
# pipe on purpose: `grep -m1` exits as soon as it finds a match, which sends
# `tail -F` a SIGPIPE and makes it exit non-zero. With `pipefail` set, that
# would make the pipeline report failure even though grep matched
# successfully. Process substitution keeps tail's exit status out of the
# `timeout`/`grep` status we actually check.
wait_for_log() {
    local file="$1"
    local message="$2"

    if ! timeout "$WAIT_TIMEOUT" grep --line-buffered -q -m1 -F "$message" < <(tail -n +1 -F "$file"); then
        echo "ERROR: timed out after ${WAIT_TIMEOUT}s waiting for '${message}' in ${file}" >&2
        return 1
    fi
}

cleanup() {
    local pid
    for pid in "${LOG_PIDS[@]:-}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# 1. Deploy the BMv2 target and wait for it to be ready
# ----------------------------------------------------------------------------
echo "==> Creating network function '${RESOURCE_NAME}'..."
kubectl apply -f src/iml/target.yaml

echo "==> Waiting for target pod to appear..."
POD=""
while [ -z "$POD" ]; do
    POD=$(kubectl get pods \
        -n "$POD_NAMESPACE" \
        -l bmv2target.loom.io/name=bmv2-target \
        -o name | head -n1 | cut -d/ -f2)
    [ -n "$POD" ] || sleep 1
done
echo "Found pod: $POD"

kubectl wait \
    -n "$POD_NAMESPACE" \
    --for=condition=Ready \
    "pod/${POD}" \
    --timeout="${WAIT_TIMEOUT}s"

# Follow both containers' logs from here on, before triggering anything that
# could produce the messages we're about to wait for.
start_log_capture "$DRIVER_CONTAINER" "$DRIVER_LOG"
start_log_capture "$SWITCH_CONTAINER" "$SWITCH_LOG"

# Wait until the BMv2 target has started and is ready to accept NFs
wait_for_log "$DRIVER_LOG" "Starting workers"

# ----------------------------------------------------------------------------
# 2. Deploy the NF and wait for it to be ready to accept configuration
# ----------------------------------------------------------------------------
echo "==> Deploying network function..."
kubectl apply -f src/iml/nf_with_config.yaml
wait_for_log "$SWITCH_LOG" "config swap"

# ----------------------------------------------------------------------------
# 3. Trigger the config update and time how long it takes to apply
# ----------------------------------------------------------------------------
echo "==> Updating NFConfig '${RESOURCE_NAME}' and starting timer..."
kubectl apply -f src/iml/config_update.yaml

# Record start time in epoch nanoseconds
START_TIME=$(date +%s%N)

# Wait until the BMv2 target logs the expected message indicating that the
# new configuration has been applied
wait_for_log "$SWITCH_LOG" "hdr.inner_ipv4.src_addr: EXACT"

# Record end time in epoch nanoseconds
END_TIME=$(date +%s%N)

ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
ELAPSED_SEC=$(awk "BEGIN { printf \"%.3f\", ${ELAPSED_MS} / 1000 }")

echo "--------------------------------------------------"
echo "Configuration for '${RESOURCE_NAME}' has been applied successfully!"
echo "Total Elapsed Time: ${ELAPSED_SEC} seconds (${ELAPSED_MS} ms)"
echo "--------------------------------------------------"

# ----------------------------------------------------------------------------
# 4. Tear down
# ----------------------------------------------------------------------------
echo "==> Deleting resource '${RESOURCE_NAME}'..."
kubectl delete -f src/iml/nf_with_config.yaml
kubectl delete -f src/iml/config_update.yaml
kubectl delete -f src/iml/target.yaml