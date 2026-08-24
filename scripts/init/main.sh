#!/bin/bash
set -euo pipefail

# This script is used to initialize the testbed environment.
# It ensures necessary dependencies, sets up configurations, and prepares the environment for running experiments.
# Dependencies:
# - Terraform
# - Ansible (complete, not just ansible-core)
# - Running terraform init
# - Making sure you can SSH into the OSM_HOST
# - Running terraform apply to create the testbed (this automatically runs ansible to configure the testbed)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "${SCRIPT_DIR}/../../terraform" && pwd)"

echo "==> Checking for Terraform..."
if ! command -v terraform >/dev/null 2>&1; then
  echo "Error: terraform is not installed. See https://developer.hashicorp.com/terraform/install" >&2
  exit 1
fi

echo "==> Checking for Ansible (complete package)..."
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "Error: ansible is not installed. Install the complete 'ansible' package (not just ansible-core): https://docs.ansible.com/ansible/latest/installation_guide/index.html" >&2
  exit 1
fi
if ! ansible-galaxy collection list 2>/dev/null | grep -q '^community\.general'; then
  echo "Error: found ansible-core but not the complete 'ansible' package (missing bundled collections such as community.general). Install the full 'ansible' package, not just ansible-core." >&2
  exit 1
fi

echo "==> Checking SSH access to OSM_HOST..."
: "${OSM_HOST:?OSM_HOST is not set. Did you fill in .env?}"
: "${OSM_HOST_USER:?OSM_HOST_USER is not set. Did you fill in .env?}"
: "${CLUSTER_NAME_IN_OSM:?CLUSTER_NAME_IN_OSM is not set. Did you fill in .env?}"
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${OSM_HOST_USER}@${OSM_HOST}" true 2>/dev/null; then
  echo "Error: cannot SSH into ${OSM_HOST_USER}@${OSM_HOST}. Make sure your SSH key is set up and the host is reachable." >&2
  exit 1
fi

echo "==> Running terraform init..."
if ! terraform -chdir="${TERRAFORM_DIR}" init; then
  echo "Error: terraform init failed. See the output above for details." >&2
  exit 1
fi

echo "==> Running terraform apply..."
if ! terraform -chdir="${TERRAFORM_DIR}" apply; then
  echo "Error: terraform apply failed (this also runs the Ansible playbook). See the output above for details." >&2
  exit 1
fi

echo "==> Reading kubeconfig path from Terraform..."
if ! KUBECONFIG_PATH="$(terraform -chdir="${TERRAFORM_DIR}" output -raw kubeconfig_path 2>/dev/null)"; then
  echo "Error: could not read 'kubeconfig_path' from Terraform output." >&2
  exit 1
fi

echo "==> Reading control-plane connection details from Terraform..."
if ! CONTROL_PLANE_IP="$(terraform -chdir="${TERRAFORM_DIR}" output -raw control_plane_public_ip 2>/dev/null)"; then
  echo "Error: could not read 'control_plane_public_ip' from Terraform output." >&2
  exit 1
fi
if ! SSH_PRIVATE_KEY_PATH="$(terraform -chdir="${TERRAFORM_DIR}" output -raw ssh_private_key_path 2>/dev/null)"; then
  echo "Error: could not read 'ssh_private_key_path' from Terraform output." >&2
  exit 1
fi

echo "==> Determining Kubernetes version..."
if ! K8S_VERSION="$(ssh -i "${SSH_PRIVATE_KEY_PATH}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "ubuntu@${CONTROL_PLANE_IP}" kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null)"; then
  echo "Error: could not determine the Kubernetes version of the cluster." >&2
  exit 1
fi

echo "==> Copying kubeconfig to ${OSM_HOST}..."
if ! REMOTE_KUBECONFIG="$(ssh "${OSM_HOST_USER}@${OSM_HOST}" mktemp)"; then
  echo "Error: could not create a temporary file on ${OSM_HOST}." >&2
  exit 1
fi
if ! scp "${KUBECONFIG_PATH}" "${OSM_HOST_USER}@${OSM_HOST}:${REMOTE_KUBECONFIG}" >/dev/null; then
  echo "Error: could not copy the kubeconfig to ${OSM_HOST}." >&2
  exit 1
fi

echo "==> Registering cluster with OSM..."
if ! ssh "${OSM_HOST_USER}@${OSM_HOST}" bash -l -s -- "${CLUSTER_NAME_IN_OSM}" "${K8S_VERSION}" "${REMOTE_KUBECONFIG}" < "${SCRIPT_DIR}/osm/orchestrator.sh"; then
  echo "Error: failed to register the cluster with OSM. See the output above for details." >&2
  exit 1
fi

echo "==> Testbed initialized successfully."