#!/bin/bash
set -euo pipefail

# Runs on OSM_HOST (piped in over SSH by ../main.sh) to drive OSM through
# the "exp2" NS lifecycle in phases: "create" times how long OSM itself
# takes to instantiate the p4_iperf_scenario_ns NS, broken down into the
# 3 phases documented in ./readme.md (Scheduling, Deployment Pre-steps,
# Deployment at VIM), by tailing the OSM LCM pod's own logs rather than
# osm ns-create's stdout, since that's where each phase boundary is
# actually timestamped; "delete" tears the NS back down once ../main.sh
# is done with it.
#
# Usage: orchestrator.sh create
#        orchestrator.sh delete <ns_id>

PHASE="${1:?phase not provided (create|delete)}"

NS_NAME="exp2"
NSD_NAME="p4_iperf_scenario_ns"
VIM_ACCOUNT="iml-testbed-vim"
P4_PROGRAM_URL="https://raw.githubusercontent.com/mantra6g/iml-testbed/main/src/p4/v2_logger.p4"

OSM_NAMESPACE="osm"
LCM_POD_LABEL="app.kubernetes.io/component=lcm"
NS_MEMBER_COUNT=2 # p4_iperf_scenario_ns's constituent VNF count -- the "<n>/2" in the Stage 2/5 progress messages LCM logs

UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

create() {
    echo "==> Creating NS instance '${NS_NAME}' and starting timer..."

    START_TIME=$(date +%s%N)
    START_TIME_SEC=$(( START_TIME / 1000000000 ))

    LCM_POD="$(kubectl get pod -n "$OSM_NAMESPACE" -l "$LCM_POD_LABEL" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [[ -z "$LCM_POD" ]]; then
        echo "Error: could not find the OSM LCM pod (namespace '${OSM_NAMESPACE}', label ${LCM_POD_LABEL})." >&2
        exit 1
    fi

    NS_ID=""
    PHASE_TIMES_FILE="$(mktemp)"

    # Tails the LCM pod's logs looking for the exact messages that bound
    # each phase (see ./readme.md for the full log lines each regex below
    # is keyed on). Phase boundaries are recorded using the *log line's
    # own* embedded timestamp rather than when we happen to read it, since
    # kubectl/SSH delivery lag would otherwise pollute the timing; lines
    # are also required to be >= START_TIME_SEC so a stale line left over
    # from a previous deployment on this same pod can't be mistaken for
    # this run's. `--since` gives kubectl a few seconds of buffer to cover
    # the time it takes to establish the log watch before ns-create is
    # even issued below.
    #
    # Streamed through a FIFO (rather than `kubectl logs -f | while ...`)
    # for the same reason as the ns-create loop further down: the RHS of a
    # pipe runs in a subshell in bash, and while this particular loop only
    # writes to an external file (so it wouldn't lose in-shell state),
    # keeping both readers structured the same way keeps their PIDs
    # trackable for cleanup below.
    LCM_FIFO="$(mktemp -u)"
    mkfifo "$LCM_FIFO"
    kubectl logs -f --since=15s -n "$OSM_NAMESPACE" "$LCM_POD" > "$LCM_FIFO" 2>&1 &
    KUBECTL_PID=$!
    exec 4< "$LCM_FIFO"
    rm -f "$LCM_FIFO"

    (
        TS_RE='^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})'
        PHASE0_END_RE='Stage 1/[0-9]+: preparation of the environment\. Reading from database\.'
        PHASE1_END_RE="Stage 2/[0-9]+: deployment of KDUs, VMs and execution environments\\. 0/${NS_MEMBER_COUNT}\\. ',"
        DONE_RE='Deploying at VIM: Done'
        current_phase=0

        while IFS= read -r -u 4 line; do
            [[ "$line" =~ $TS_RE ]] || continue
            log_epoch=$(date -d "${BASH_REMATCH[1]}" +%s) || continue
            (( log_epoch >= START_TIME_SEC )) || continue

            if [[ "$current_phase" == "0" && "$line" =~ $PHASE0_END_RE ]]; then
                echo "1 $log_epoch" >> "$PHASE_TIMES_FILE"
                current_phase=1
            elif [[ "$current_phase" == "1" && "$line" =~ $PHASE1_END_RE ]]; then
                echo "2 $log_epoch" >> "$PHASE_TIMES_FILE"
                current_phase=2
            elif [[ "$current_phase" == "2" && "$line" =~ $DONE_RE ]]; then
                echo "done $log_epoch" >> "$PHASE_TIMES_FILE"
                break
            fi
        done
    ) &
    WATCH_PID=$!

    # Streamed through a FIFO (rather than piped through grep) so the raw
    # ns-create output stays visible live while we pull the NS_ID out of it
    # as it arrives. A named pipe + background job is used instead of
    # `cmd | while read ...` because the RHS of a pipe runs in a subshell
    # in bash, which would drop NS_ID on exit; it's used instead of
    # `coproc` because bash can unset the coproc's fd/PID bookkeeping as
    # soon as it reaps the child, racing the loop's final read.
    OSM_FIFO="$(mktemp -u)"
    mkfifo "$OSM_FIFO"

    osm ns-create \
        --ns_name "$NS_NAME" \
        --nsd_name "$NSD_NAME" \
        --vim_account "$VIM_ACCOUNT" \
        --config '{"additionalParamsForVnf": [{"member-vnf-index": "p4-switch","additionalParamsForKdu": [{"kdu_name": "p4-switch-kdu","additionalParams": {"p4ProgramURL": "https://raw.githubusercontent.com/mantra6g/iml-testbed/main/src/p4/v2_logger.p4","tableEntriesURL": "https://raw.githubusercontent.com/mantra6g/iml-testbed/main/src/entries/v1.json"}}]}]}'\
        --wait > "$OSM_FIFO" 2>&1 &
    OSM_PID=$!

    exec 3< "$OSM_FIFO"
    rm -f "$OSM_FIFO"

    while IFS= read -r -u 3 line; do
        echo "$line"
        if [[ "$line" =~ $UUID_RE ]]; then
            NS_ID="${BASH_REMATCH[0]}"
        fi
    done

    exec 3<&-
    wait "$OSM_PID"

    END_TIME=$(date +%s%N)
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    ELAPSED_SEC=$(awk "BEGIN { printf \"%.3f\", ${ELAPSED_MS} / 1000 }")

    # ns-create --wait doesn't return until OSM itself reports completion,
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
            2) PHASE_END_EPOCH[1]="$epoch" ;;
            done) PHASE_END_EPOCH[2]="$epoch" ;;
        esac
    done < "$PHASE_TIMES_FILE"
    rm -f "$PHASE_TIMES_FILE"

    declare -A PHASE_START_EPOCH
    PHASE_START_EPOCH[0]=$START_TIME_SEC
    [[ -n "${PHASE_END_EPOCH[0]+x}" ]] && PHASE_START_EPOCH[1]="${PHASE_END_EPOCH[0]}"
    [[ -n "${PHASE_END_EPOCH[1]+x}" ]] && PHASE_START_EPOCH[2]="${PHASE_END_EPOCH[1]}"

    echo "--------------------------------------------------"
    echo "Deployment started at $(date -d "@${START_TIME_SEC}" '+%Y-%m-%d %H:%M:%S')"
    echo "Deployment ended at $(date -d "@$((END_TIME / 1000000000))" '+%Y-%m-%d %H:%M:%S')"
    echo "NS instance '${NS_ID}' is running!"
    echo "NS_ID: ${NS_ID}"
    echo "OSM-deployment waiting time: ${ELAPSED_SEC} seconds (${ELAPSED_MS} ms)"
    echo "--------------------------------------------------"
    echo "Phase timing breakdown (from LCM pod logs, 1s resolution):"
    PHASE_DESCS=("Scheduling" "Deployment Pre-steps" "Deployment at VIM")
    for i in 0 1 2; do
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
    delete) delete "${2:?NS id not provided for delete phase}" ;;
    *) echo "Unknown phase '${PHASE}' (expected create|delete)" >&2; exit 1 ;;
esac
