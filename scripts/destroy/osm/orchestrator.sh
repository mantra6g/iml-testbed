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

echo "==> Looking for running NS instances..."
mapfile -t NS_IDS < <(osm ns-list 2>/dev/null | grep -Eo "$UUID_RE" | sort -u)

if [ "${#NS_IDS[@]}" -eq 0 ]; then
  echo "No NS instances found."
else
  for ns_id in "${NS_IDS[@]}"; do
    echo "==> Deleting NS instance '${ns_id}'..."
    osm ns-delete "$ns_id"
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
  if osm nspkg-list 2>/dev/null | grep -q "$nspkg"; then
    echo "==> Deleting NS package '${nspkg}'..."
    osm nspkg-delete "$nspkg"
  else
    echo "NS package '${nspkg}' not found, skipping."
  fi
done

echo "==> Deleting NF packages..."
for nfpkg in "${NFPKG_NAMES[@]}"; do
  if osm nfpkg-list 2>/dev/null | grep -q "$nfpkg"; then
    echo "==> Deleting NF package '${nfpkg}'..."
    osm nfpkg-delete "$nfpkg"
  else
    echo "NF package '${nfpkg}' not found, skipping."
  fi
done

echo "==> Deleting k8s cluster '${CLUSTER_NAME}' from OSM..."
if osm k8scluster-list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  osm k8scluster-delete "$CLUSTER_NAME" --wait
else
  echo "k8s cluster '${CLUSTER_NAME}' not registered in OSM, skipping."
fi

echo "==> Deleting VIM 'iml-testbed-vim' from OSM..."
if osm vim-list 2>/dev/null | grep -q "iml-testbed-vim"; then
  osm vim-delete iml-testbed-vim --wait
else
  echo "VIM 'iml-testbed-vim' not found, skipping."
fi

echo "==> OSM cleanup complete."
