#!/usr/bin/env bash
# list-peers.sh — List all NetBird peers in the mesh
# Usage: ./ops/netbird/list-peers.sh
# Must be run on a host that is enrolled in the NetBird mesh (or ns1)
set -euo pipefail

echo "=== NetBird Peer Status ==="
netbird status --detail
