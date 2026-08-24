#!/bin/bash
set -euo pipefail

# Commands:
# - init: downloads dependencies and initializes the testbed (terraform, ansible, terraform providers, etc.)
# - destroy: destroys the testbed
# - package: packages and uploads the OSM knfs and nfs
# - run-experiment-2: runs the experiment 2
# - run-experiment-3: runs the experiment 3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse environment variables from .env
ENV_FILE="${SCRIPT_DIR}/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: ${ENV_FILE} not found. Run 'cp .env.example .env' and fill in your values." >&2
  exit 1
fi
set -a
source "$ENV_FILE"
set +a

COMMAND="${1:-}"
if [ -z "$COMMAND" ]; then
  echo "Usage: $0 <init|destroy|package|run-experiment-2|run-experiment-3> [args...]" >&2
  exit 1
fi
shift

case "$COMMAND" in
  init)             SUBSCRIPT="init/main.sh" ;;
  destroy)          SUBSCRIPT="destroy/main.sh" ;;
  package)          SUBSCRIPT="package/main.sh" ;;
  run-experiment-2) SUBSCRIPT="experiment-2/main.sh" ;;
  run-experiment-3) SUBSCRIPT="experiment-3/main.sh" ;;
  *)
    echo "Error: unknown command '${COMMAND}'" >&2
    echo "Usage: $0 <init|destroy|package|run-experiment-2|run-experiment-3> [args...]" >&2
    exit 1
    ;;
esac

exec bash "${SCRIPT_DIR}/scripts/${SUBSCRIPT}" "$@"
