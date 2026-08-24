#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${OSM_HOST:?OSM_HOST is not set. Did you fill in .env?}"
: "${OSM_HOST_USER:?OSM_HOST_USER is not set. Did you fill in .env?}"
: "${REPO_URL:?REPO_URL is not set. Did you fill in .env?}"

ssh "${OSM_HOST_USER}@${OSM_HOST}" bash -l -s -- "${REPO_URL}" < "${SCRIPT_DIR}/osm/orchestrator.sh"
