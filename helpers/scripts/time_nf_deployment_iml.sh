#!/usr/bin/env bash
set -euo pipefail

# 1. Configuration
RESOURCE_NAME="pkt-logger"
RESOURCE_TYPE="nf"     # Change to "pod" if monitoring the backing pod directly
NAMESPACE="default"    # Set your targeted namespace if not default

echo "==> Creating resource '${RESOURCE_NAME}' and starting timer..."

# Record start time in epoch nanoseconds
START_TIME=$(date +%s%N)

# 2. Trigger your resource creation here (uncomment & adapt to your command)
kubectl apply -f src/iml/nf.yaml

# 3. Wait for the condition/status to hit Running
# Using kubectl wait to block until status is reached
kubectl wait --namespace="${NAMESPACE}" \
  --for=jsonpath='{.status.phase}'=Running \
  "${RESOURCE_TYPE}/${RESOURCE_NAME}" \
  --timeout=300s

# Record end time in epoch nanoseconds
END_TIME=$(date +%s%N)

# 4. Calculate elapsed time
ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
ELAPSED_SEC=$(awk "BEGIN {print ${ELAPSED_MS}/1000}")

echo "--------------------------------------------------"
echo "Resource '${RESOURCE_NAME}' switched to Running state!"
echo "Total Elapsed Time: ${ELAPSED_SEC} seconds (${ELAPSED_MS} ms)"
echo "--------------------------------------------------"

# Delete the resource after timing
echo "==> Deleting resource '${RESOURCE_NAME}'..."
kubectl delete -f src/iml/nf.yaml