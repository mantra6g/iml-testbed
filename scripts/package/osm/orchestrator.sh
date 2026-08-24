#!/bin/bash
set -euo pipefail

# Runs on OSM_HOST (piped in over SSH by ../main.sh) to build and register the
# OSM knf/nsd packages from a fresh clone of the repo.

REPO_URL="${1:?repo URL not provided}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

git clone "$REPO_URL" "$TMP_DIR"
cd "$TMP_DIR"

osm package-build src/osm/p4_switch_knf
osm package-build src/osm/p4_iperf_scenario_ns

osm nfpkg-create src/osm/p4_switch_knf.tar.gz
osm nspkg-create src/osm/p4_iperf_scenario_ns.tar.gz
