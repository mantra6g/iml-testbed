#!/usr/bin/env bash
set -euo pipefail

# 1. Configuration
RESOURCE_NAME="pkt-logger"
RESOURCE_TYPE="nf"     # Change to "pod" if monitoring the backing pod directly
NAMESPACE="default"    # Set your targeted namespace if not default

echo "==> Creating network function '${RESOURCE_NAME}'..."

# 2. Trigger resource creation
kubectl apply -f src/iml/target.yaml

sleep 1 # Wait a moment for the target to be created
POD=$(kubectl get pods -l bmv2target.loom.io/name=bmv2-target -o jsonpath='{.items[0].metadata.name}')

# Wait until the BMv2 target has started and is ready to accept NFs
kubectl logs -f "$POD" | grep -m1 "Starting workers	{"controller": "nf-controller", "controllerGroup": "core.loom.io", "controllerKind": "NetworkFunction", "worker count": 1}"

# Deploy the NF
kubectl apply -f src/iml/nf_with_config.yaml
# Wait until the NF has been scheduled and is ready to accept configuration
kubectl logs -f "$POD" -c "bmv2-switch" | grep -m1 "simple_switch target has been notified of a config swap"

# Record start time in epoch nanoseconds
echo "==> Updating NFConfig '${RESOURCE_NAME}' and starting timer..."

# 3. Trigger config update
kubectl apply -f src/iml/config.yaml

# Record start time in epoch nanoseconds
START_TIME=$(date +%s%N)

# 4. Wait until the BMv2 target logs the expected message indicating that the new configuration has been applied
kubectl logs -f "$POD" -c "bmv2-switch" | grep -m1 "* hdr.inner_ipv4.src_addr: EXACT     0a7b0003"

# Record end time in epoch nanoseconds
END_TIME=$(date +%s%N)

# 4. Calculate elapsed time
ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
ELAPSED_SEC=$(awk "BEGIN {print ${ELAPSED_MS}/1000}")

echo "--------------------------------------------------"
echo "Configuration for '${RESOURCE_NAME}' has been applied successfully!"
echo "Total Elapsed Time: ${ELAPSED_SEC} seconds (${ELAPSED_MS} ms)"
echo "--------------------------------------------------"

# Delete the resource after timing
echo "==> Deleting resource '${RESOURCE_NAME}'..."
kubectl delete -f src/iml/nf_with_config.yaml
kubectl delete -f src/iml/config_update.yaml
kubectl delete -f src/iml/target.yaml