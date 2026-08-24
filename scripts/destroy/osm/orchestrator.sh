#!/bin/bash
set -euo pipefail

# Runs on OSM_HOST (piped in over SSH by ../main.sh) to tear down the OSM
# resources created by scripts/package/osm/orchestrator.sh, in dependency
# order: NS instances, then their NF/NS packages, then the k8s cluster they
# ran on.

CLUSTER_NAME="${1:?cluster name not provided}"

NFPKG_NAMES=("p4_switch_knf")
NSPKG_NAMES=("p4_iperf_scenario_ns")

UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# OSM's list commands can report resources that are already gone (eventual
# consistency / stale cache), so every delete below tolerates the delete
# itself failing with "not found" rather than relying on the list check alone.
delete_tolerant() {
  local description="$1"
  shift
  if ! OUTPUT="$("$@" 2>&1)"; then
    if echo "$OUTPUT" | grep -qi "not found"; then
      echo "${description} already deleted, skipping."
    else
      echo "$OUTPUT" >&2
      exit 1
    fi
  fi
}

echo "==> Looking for running NS instances..."
mapfile -t NS_IDS < <(osm ns-list 2>/dev/null | grep -Eo "$UUID_RE" | sort -u)

if [ "${#NS_IDS[@]}" -eq 0 ]; then
  echo "No NS instances found."
else
  for ns_id in "${NS_IDS[@]}"; do
    echo "==> Deleting NS instance '${ns_id}'..."
    delete_tolerant "NS instance '${ns_id}'" osm ns-delete "$ns_id"
  done

  echo "==> Waiting for NS instances to be fully deleted..."
  REMAINING=1
  for _ in $(seq 1 60); do
    REMAINING="$(osm ns-list 2>/dev/null | grep -Eco "$UUID_RE" || true)"
    [ "$REMAINING" -eq 0 ] && break
    sleep 10
  done
  if [ "$REMAINING" -ne 0 ]; then
    echo "Error: timed out waiting for NS instances to be deleted." >&2
    exit 1
  fi
fi

echo "==> Deleting NS packages..."
for nspkg in "${NSPKG_NAMES[@]}"; do
  echo "==> Deleting NS package '${nspkg}'..."
  delete_tolerant "NS package '${nspkg}'" osm nspkg-delete "$nspkg"
done

echo "==> Deleting NF packages..."
for nfpkg in "${NFPKG_NAMES[@]}"; do
  echo "==> Deleting NF package '${nfpkg}'..."
  delete_tolerant "NF package '${nfpkg}'" osm nfpkg-delete "$nfpkg"
done

echo "==> Deleting k8s cluster '${CLUSTER_NAME}' from OSM..."
delete_tolerant "k8s cluster '${CLUSTER_NAME}'" osm k8scluster-delete "$CLUSTER_NAME" --wait

echo "==> Deleting VIM 'iml-testbed-vim' from OSM..."
delete_tolerant "VIM 'iml-testbed-vim'" osm vim-delete iml-testbed-vim --wait

echo "==> OSM cleanup complete."
