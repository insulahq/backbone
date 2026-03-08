#!/usr/bin/env bash
# add-zone.sh — Create a new DNS zone on ns1 via PowerDNS API
# Usage: ./ops/dns/add-zone.sh <zone> <nameserver1> [nameserver2]
# Requires: PDNS_API_KEY env var (or set in .env)
set -euo pipefail

NS1_API="${NS1_API_URL:-http://ns1.phoenix-host.net:8081}"
ZONE="${1:-}"
NS1_HOST="${2:-ns1.phoenix-host.net}"
NS2_HOST="${3:-ns2.phoenix-host.net}"

if [[ -z "$ZONE" ]]; then
  echo "Usage: $0 <zone> [ns1_host] [ns2_host]"
  echo "  Example: $0 acme.com ns1.phoenix-host.net ns2.phoenix-host.net"
  echo ""
  echo "  Requires env: PDNS_API_KEY"
  exit 1
fi

if [[ -z "${PDNS_API_KEY:-}" ]]; then
  echo "ERROR: PDNS_API_KEY environment variable is not set."
  exit 1
fi

# Ensure zone ends with a dot (FQDN)
[[ "$ZONE" != *. ]] && ZONE="${ZONE}."

echo "Creating zone: $ZONE"

curl -s -X POST "${NS1_API}/api/v1/servers/localhost/zones" \
  -H "X-API-Key: ${PDNS_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"${ZONE}\",
    \"kind\": \"Native\",
    \"nameservers\": [\"${NS1_HOST}.\", \"${NS2_HOST}.\"],
    \"dnssec\": false
  }" | jq .

echo ""
echo "Zone $ZONE created. AXFR to ns2 will happen within 60 seconds."
