#!/bin/bash
set -euo pipefail

# Runs on OSM_HOST (piped in over SSH by ../main.sh) to drive OSM through
# the "exp3" NS lifecycle in phases: "create" provisions the NS,
# "reconfigure" times how long OSM itself takes to apply a KDU upgrade to
# it, and "delete" tears the NS back down once ../main.sh is done with it.
#
# Usage: orchestrator.sh create
#        orchestrator.sh reconfigure
#        orchestrator.sh delete <ns_id>

PHASE="${1:?phase not provided (create|reconfigure|delete)}"

NS_NAME="exp3"
NSD_NAME="p4_iperf_scenario_ns"
VIM_ACCOUNT="iml-testbed-vim"
P4_PROGRAM_URL="https://raw.githubusercontent.com/mantra6g/iml-testbed/main/src/p4/v2_logger.p4"
KNF_NAME="p4-switch"
KDU_NAME="p4-switch-kdu"

OSM_NAMESPACE="osm"
LCM_POD_LABEL="app.kubernetes.io/component=lcm"

UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

create() {
    echo "==> Creating NS instance '${NS_NAME}'..."

    NS_ID="$(osm ns-create \
        --ns_name "$NS_NAME" \
        --nsd_name "$NSD_NAME" \
        --vim_account "$VIM_ACCOUNT" \
        --config '{"additionalParamsForVnf": [{"member-vnf-index": "p4-switch","additionalParamsForKdu": [{"kdu_name": "p4-switch-kdu","additionalParams": {"p4ProgramURL": "https://raw.githubusercontent.com/mantra6g/iml-testbed/main/src/p4/v2_logger.p4","tableEntriesURL": "https://raw.githubusercontent.com/mantra6g/iml-testbed/main/src/entries/v1.json"}}]}]}'\
        --wait | grep -Eo "$UUID_RE" | tail -n1)"

    echo "NS instance '${NS_ID}' is running!"
    echo "NS_ID: ${NS_ID}"
}

reconfigure() {
    echo "==> Updating NS instance '${NS_NAME}' and starting timer..."

    START_TIME=$(date +%s%N)
    START_TIME_SEC=$(( START_TIME / 1000000000 ))

    LCM_POD="$(kubectl get pod -n "$OSM_NAMESPACE" -l "$LCM_POD_LABEL" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [[ -z "$LCM_POD" ]]; then
        echo "Error: could not find the OSM LCM pod (namespace '${OSM_NAMESPACE}', label ${LCM_POD_LABEL})." >&2
        exit 1
    fi

    PHASE_TIMES_FILE="$(mktemp)"

    # Tails the LCM pod's logs looking for the exact messages that bound
    # each phase (see ./readme.md). As in
    # ../../experiment-2/osm/orchestrator.sh's create(), phase boundaries
    # use the log line's own embedded timestamp (filtered to
    # >= START_TIME_SEC so a stale line can't be mistaken for this run's),
    # and kubectl is given a few seconds of --since buffer to cover the
    # time it takes to establish the watch before ns-action is even issued
    # below. Phase 1's end additionally has to be correlated by the
    # nslcmop operation id captured out of phase 0's boundary message (via
    # '_admin.nslcmop'), since 'operationState': 'COMPLETED' on its own
    # isn't unique to this operation.
    LCM_FIFO="$(mktemp -u)"
    mkfifo "$LCM_FIFO"
    kubectl logs -f --since=15s -n "$OSM_NAMESPACE" "$LCM_POD" > "$LCM_FIFO" 2>&1 &
    KUBECTL_PID=$!
    exec 4< "$LCM_FIFO"
    rm -f "$LCM_FIFO"

    (
        TS_RE='^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})'
        NSLCMOP_RE="_admin\\.nslcmop': '([0-9a-fA-F-]{36})'"
        current_phase=0
        op_id=""

        while IFS= read -r -u 4 line; do
            [[ "$line" =~ $TS_RE ]] || continue
            log_epoch=$(date -d "${BASH_REMATCH[1]}" +%s) || continue
            (( log_epoch >= START_TIME_SEC )) || continue

            if [[ "$current_phase" == "0" && "$line" == *"_admin.operation-type': 'RUNNING ACTION"* && "$line" =~ $NSLCMOP_RE ]]; then
                op_id="${BASH_REMATCH[1]}"
                echo "1 $log_epoch" >> "$PHASE_TIMES_FILE"
                current_phase=1
            elif [[ "$current_phase" == "1" && -n "$op_id" && "$line" == *"'operationState': 'COMPLETED'"* && "$line" == *"Item: nslcmops _id: ${op_id}"* ]]; then
                echo "done $log_epoch" >> "$PHASE_TIMES_FILE"
                break
            fi
        done
    ) &
    WATCH_PID=$!

    osm ns-action \
      "$NS_NAME" \
      --vnf_name "$KNF_NAME" \
      --kdu_name "$KDU_NAME" \
      --action_name upgrade \
      --params '{"p4ProgramURL": "https://raw.githubusercontent.com/mantra6g/iml-testbed/main/src/p4/v2_logger.p4", "tableEntriesURL": "https://raw.githubusercontent.com/mantra6g/iml-testbed/main/src/entries/v2.json"}' \
      --wait

    END_TIME=$(date +%s%N)
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    ELAPSED_SEC=$(awk "BEGIN { printf \"%.3f\", ${ELAPSED_MS} / 1000 }")

    # ns-action --wait doesn't return until OSM itself reports completion,
    # so the watcher should have already recorded "done" and exited on its
    # own by now; give it a brief grace period, then tear both it and
    # kubectl down regardless.
    for _ in 1 2 3 4 5; do
        kill -0 "$WATCH_PID" 2>/dev/null || break
        sleep 1
    done
    kill "$KUBECTL_PID" "$WATCH_PID" 2>/dev/null || true
    wait "$KUBECTL_PID" "$WATCH_PID" 2>/dev/null || true
    exec 4<&-

    declare -A PHASE_END_EPOCH
    while read -r key epoch; do
        case "$key" in
            1) PHASE_END_EPOCH[0]="$epoch" ;;
            done) PHASE_END_EPOCH[1]="$epoch" ;;
        esac
    done < "$PHASE_TIMES_FILE"
    rm -f "$PHASE_TIMES_FILE"

    declare -A PHASE_START_EPOCH
    PHASE_START_EPOCH[0]=$START_TIME_SEC
    [[ -n "${PHASE_END_EPOCH[0]+x}" ]] && PHASE_START_EPOCH[1]="${PHASE_END_EPOCH[0]}"

    echo "--------------------------------------------------"
    echo "NS instance '${NS_NAME}' reconfigured!"
    echo "OSM-reported reconfiguration time: ${ELAPSED_SEC} seconds (${ELAPSED_MS} ms)"
    echo "--------------------------------------------------"
    echo "Phase timing breakdown (from LCM pod logs, 1s resolution):"
    PHASE_DESCS=("Scheduling action" "Upgrade")
    for i in 0 1; do
        if [[ -n "${PHASE_START_EPOCH[$i]+x}" && -n "${PHASE_END_EPOCH[$i]+x}" ]]; then
            phase_dur=$(( PHASE_END_EPOCH[$i] - PHASE_START_EPOCH[$i] ))
            echo "  Phase ${i} (${PHASE_DESCS[$i]}): ${phase_dur}s"
        else
            echo "  Phase ${i} (${PHASE_DESCS[$i]}): could not be determined from LCM pod logs"
        fi
    done
    echo "--------------------------------------------------"

    # The NS instance is deliberately left running here rather than deleted
    # inline: ../main.sh calls this script again with the "delete" phase
    # once it's done with the instance.
}

delete() {
    local ns_id="${1:?NS id not provided}"
    echo "==> Deleting NS instance '${NS_NAME}' (${ns_id})..."
    osm ns-delete "$ns_id" --wait
}

case "$PHASE" in
    create) create ;;
    reconfigure) reconfigure ;;
    delete) delete "${2:?NS id not provided for delete phase}" ;;
    *) echo "Unknown phase '${PHASE}' (expected create|reconfigure|delete)" >&2; exit 1 ;;
esac
