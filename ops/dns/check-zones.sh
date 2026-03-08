#!/usr/bin/env bash
# check-zones.sh — Verify zone replication from ns1 to ns2
# Usage: ./ops/dns/check-zones.sh [zone]
set -euo pipefail

NS1="${NS1_IP:-ns1.phoenix-host.net}"
NS2="${NS2_IP:-ns2.phoenix-host.net}"
ZONE="${1:-}"

if [[ -z "$ZONE" ]]; then
  echo "Usage: $0 <zone>"
  echo "  Example: $0 acme.com"
  exit 1
fi

echo "=== Checking zone: $ZONE ==="
echo ""
echo "--- ns1 (master) ---"
dig @"$NS1" SOA "$ZONE" +short

echo ""
echo "--- ns2 (slave) ---"
dig @"$NS2" SOA "$ZONE" +short

echo ""
echo "--- Comparing serial numbers ---"
SERIAL_NS1=$(dig @"$NS1" SOA "$ZONE" +short | awk '{print $3}')
SERIAL_NS2=$(dig @"$NS2" SOA "$ZONE" +short | awk '{print $3}')

if [[ "$SERIAL_NS1" == "$SERIAL_NS2" ]]; then
  echo "OK — Both nameservers are in sync (serial: $SERIAL_NS1)"
else
  echo "WARNING — Serial mismatch!"
  echo "  ns1 serial: $SERIAL_NS1"
  echo "  ns2 serial: $SERIAL_NS2"
  exit 1
fi
