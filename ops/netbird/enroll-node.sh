#!/usr/bin/env bash
# enroll-node.sh — Enroll a new node into the NetBird mesh
# Run this on the target node after the netbird client is installed.
# Usage: ./ops/netbird/enroll-node.sh <hostname>
# Requires: NETBIRD_SETUP_KEY env var
set -euo pipefail

MANAGEMENT_URL="${NETBIRD_MANAGEMENT_URL:-https://netbird.phoenix-host.net:443}"
HOSTNAME="${1:-$(hostname -f)}"

if [[ -z "${NETBIRD_SETUP_KEY:-}" ]]; then
  echo "ERROR: NETBIRD_SETUP_KEY environment variable is not set."
  echo "  Generate a setup key in the NetBird management UI: ${MANAGEMENT_URL}"
  exit 1
fi

echo "Enrolling ${HOSTNAME} into NetBird mesh..."
netbird up \
  --management-url "$MANAGEMENT_URL" \
  --setup-key "$NETBIRD_SETUP_KEY" \
  --hostname "$HOSTNAME"

echo ""
echo "Enrollment complete. Current status:"
netbird status
