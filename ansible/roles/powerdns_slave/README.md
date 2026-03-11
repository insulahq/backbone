# PowerDNS Slave Role

> **Status:** COMPLETE — Ready for deployment  
> **Architecture:** Secondary DNS server with NetBird mesh replication  
> **Alignment:** `docs/01-core/DISPERSED_DNS_ARCHITECTURE.md`

## Overview

This role deploys PowerDNS Authoritative Server as a secondary DNS server on ns2 with:
- SQLite backend for zone storage (lightweight)
- Zone replication via AXFR/NOTIFY from ns1
- **NetBird mesh only replication** (no public zone transfers)
- Autosecondary mode (auto-create zones on NOTIFY)

**Key features:**
- ✅ DNS publicly accessible (port 53)
- ✅ AXFR/NOTIFY via NetBird mesh ONLY (encrypted, private)
- ✅ No API, no web server (read-only secondary)
- ✅ Autosecondary mode (zones auto-created on first NOTIFY)
- ✅ DNSSEC support enabled
- ✅ Lightweight SQLite backend

## Architecture

```
ns2 (PowerDNS Secondary):

Docker Network:
└── powerdns_internal (allows outbound to NetBird mesh)
    └── pdns (PowerDNS Auth 4.9)
        └── Backend: SQLite

Host Network:
└── 0.0.0.0:53 → pdns (DNS public)

Zone Replication (NetBird Mesh Only):
ns1 ({{ hostvars['ns1']['netbird_ip'] }})
  ↓ NOTIFY (zone changed)
ns2 ({{ netbird_ip }})
  ↓ AXFR (pull full zone)
ns1 ({{ hostvars['ns1']['netbird_ip'] }})
  ↓ Zone data transfer
ns2 SQLite database updated

Propagation: < 5 seconds
```

## Security Design — NetBird Mesh Replication

### Why NetBird Mesh for AXFR?

**Problem with public AXFR:**
- Zone transfers contain full DNS database (all domains, all records)
- Public AXFR exposes customer data to internet reconnaissance
- Attackers can enumerate all hosted domains and subdomains

**Solution: NetBird mesh replication**
- ✅ NOTIFY accepted ONLY from ns1 NetBird IP
- ✅ AXFR pulled ONLY from ns1 NetBird IP
- ✅ Traffic encrypted via WireGuard (NetBird mesh)
- ✅ No public AXFR serving (disabled on secondary)

### Configuration

**ns1 (primary) sends NOTIFY to:**
```yaml
# From powerdns_master role
powerdns_also_notify:
  - "{{ hostvars['ns2']['netbird_ip'] }}"  # ns2 NetBird IP, NOT public IP
```

**ns2 (secondary) accepts NOTIFY from:**
```yaml
# From powerdns_slave role
powerdns_allow_notify_from:
  - "{{ hostvars['ns1']['netbird_ip'] }}"  # ns1 NetBird IP, NOT public IP
```

**ns2 (secondary) fetches AXFR from:**
```yaml
# From powerdns_slave role
powerdns_primary_server: "{{ hostvars['ns1']['netbird_ip'] }}"  # ns1 NetBird IP
```

### Network Traffic Flow

```
Public Internet:
  → ns2:53 (DNS queries) ✅ ALLOWED
  → ns2:* (AXFR, NOTIFY) ❌ BLOCKED

NetBird Mesh:
  ns1 NetBird IP → ns2 NetBird IP (NOTIFY) ✅ ALLOWED
  ns2 NetBird IP → ns1 NetBird IP (AXFR) ✅ ALLOWED
```

## Requirements

### Infrastructure Dependencies

**Must be deployed first:**
1. `common` role — Docker CE, nftables firewall, fail2ban
2. `netbird_management` role — NetBird Management on ns1 + ns2
3. `netbird_peer` role — NetBird peer on ns1 + ns2 (to get NetBird IPs)
4. `powerdns_master` role — PowerDNS Primary on ns1 (must be deployed first)

**Deployment order:**
```
common → netbird_management → netbird_peer → powerdns_master → powerdns_slave
```

**Critical:** 
- `netbird_ip` variable must be set on ns2 before deploying this role
- `hostvars['ns1']['netbird_ip']` must be available

### System Requirements

- Docker CE 20.10+
- Docker Compose v2.24+
- 512MB RAM minimum (SQLite is lightweight)
- 5GB disk space (zone data, logs)

## Role Variables

### Required Variables

Set in `host_vars/ns1.yml` and `host_vars/ns2.yml`:

```yaml
# ns1 NetBird IP (obtained from netbird_peer role on ns1)
netbird_ip: "100.64.0.1"

# ns2 NetBird IP (obtained from netbird_peer role on ns2)
netbird_ip: "100.64.0.2"
```

Also set in `group_vars/all.yml`:

```yaml
platform_domain: phoenix-host.net
```

### Default Variables

See `defaults/main.yml` for all configurable options.

**Key defaults:**
- `powerdns_version: "4.9"`
- `powerdns_install_dir: /opt/powerdns`
- `powerdns_primary: no`
- `powerdns_secondary: yes`
- `powerdns_autosecondary: yes`
- `powerdns_api_enabled: no`
- `powerdns_db_path: /var/lib/powerdns/pdns.sqlite3`

### Zone Replication (NetBird Mesh)

```yaml
# Accept NOTIFY only from ns1 NetBird IP
powerdns_allow_notify_from:
  - "{{ hostvars['ns1']['netbird_ip'] }}"

# Fetch AXFR from ns1 NetBird IP
powerdns_primary_server: "{{ hostvars['ns1']['netbird_ip'] }}"

# AXFR settings
powerdns_xfr_cycle_interval: 60      # Check every 60 seconds
powerdns_axfr_fetch_timeout: 10      # 10 second timeout
```

## Dependencies

### Ansible Collections

```bash
ansible-galaxy collection install community.docker
```

### Ansible Roles

- `common` — OS hardening, Docker CE, firewall
- `netbird_management` — NetBird Management server
- `netbird_peer` — NetBird peer client (provides `netbird_ip`)
- `powerdns_master` — PowerDNS Primary on ns1 (must exist first)

## Example Playbook

```yaml
- name: Deploy PowerDNS Slave on ns2
  hosts: ns2
  roles:
    - powerdns_slave
```

## Deployment

**Prerequisites:**
1. ✅ Common role deployed (Docker, firewall)
2. ✅ NetBird Management deployed (ns1 + ns2)
3. ✅ NetBird peer deployed (ns1 + ns2)
4. ✅ NetBird IPs captured and set in host_vars
5. ✅ PowerDNS Master deployed on ns1

**Get NetBird IPs:**

```bash
# SSH to ns1
ssh -i ~/phoenix-host.key root@23.88.111.142
ip -4 addr show wt0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
# Example output: 100.64.0.1

# SSH to ns2
ssh -i ~/phoenix-host.key root@89.167.125.29
ip -4 addr show wt0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
# Example output: 100.64.0.2

# Add to host_vars/ns1.yml:
# netbird_ip: "100.64.0.1"

# Add to host_vars/ns2.yml:
# netbird_ip: "100.64.0.2"
```

**Update ns1 PowerDNS to use ns2 NetBird IP:**

Before deploying ns2, update ns1 `powerdns_master` configuration:

```yaml
# In powerdns_master/defaults/main.yml or override in host_vars/ns1.yml
powerdns_also_notify:
  - "{{ hostvars['ns2']['netbird_ip'] }}"  # ns2 NetBird IP
```

Re-run `powerdns_master` role on ns1 to update configuration:

```bash
ansible-playbook site.yml --limit ns1 --tags powerdns_master
```

**Deploy PowerDNS Slave:**

```bash
cd /config/hosting-platform/ansible

# Deploy to ns2
ansible-playbook site.yml --limit ns2 --tags powerdns_slave
```

**First deployment:**
- PowerDNS starts with empty SQLite database
- Waits for NOTIFY from ns1
- Autosecondary mode auto-creates zones on first NOTIFY
- AXFR fetches full zone data from ns1 NetBird IP

## Post-Deployment

### 1. Verify Services

```bash
# SSH to ns2
ssh -i ~/phoenix-host.key root@89.167.125.29

# Check Docker container
docker ps

# Expected container:
# - powerdns-slave (running)

# Check DNS server (public)
dig @89.167.125.29 phoenix-host.net SOA
# Should return SOA record (same as ns1)

# Check PowerDNS control
docker exec powerdns-slave pdns_control ping
# Should return "Pong"
```

### 2. Test Zone Replication

**Create zone on ns1:**

```bash
# SSH to ns1 or use NetBird mesh access
curl -X POST http://100.64.0.1:8081/api/v1/servers/localhost/zones \
  -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-replication.com.",
    "kind": "Master",
    "nameservers": ["ns1.phoenix-host.net.", "ns2.phoenix-host.net."]
  }'
```

**Verify replication to ns2 (< 5 seconds):**

```bash
# Wait 5 seconds, then check ns2
sleep 5

# Check zone exists on ns2
docker exec powerdns-slave pdns_control list-zones | grep test-replication
# Should show: test-replication.com

# Query DNS on ns2
dig @89.167.125.29 test-replication.com SOA
# Should return SOA record
```

### 3. Monitor Replication

```bash
# On ns2, watch logs for NOTIFY and AXFR
docker logs -f powerdns-slave

# Expected log entries:
# - Received NOTIFY for zone test-replication.com from 100.64.0.1
# - AXFR started for test-replication.com
# - AXFR of zone test-replication.com completed
```

### 4. Verify NetBird Mesh Replication

**Test that public IP NOTIFY is rejected:**

```bash
# From external server or workstation (not on NetBird mesh)
# Attempt to send fake NOTIFY to ns2
dig @89.167.125.29 phoenix-host.net SOA

# This should work (DNS queries allowed)

# But NOTIFY packets from public internet should be dropped
# (no way to test this directly without packet crafting)
```

**Verify AXFR only works from NetBird:**

```bash
# From ns1 (via NetBird IP)
dig @100.64.0.2 phoenix-host.net AXFR
# Should FAIL (AXFR disabled on secondary)

# From public internet
dig @89.167.125.29 phoenix-host.net AXFR
# Should FAIL (AXFR disabled on secondary)

# Secondary never serves AXFR (security hardening)
```

## DNS Configuration

**Nameservers for customer domains:**
```
ns1.phoenix-host.net. (23.88.111.142)  — Primary
ns2.phoenix-host.net. (89.167.125.29)  — Secondary
```

**Both servers serve identical zones:**
- ns1 is authoritative (accepts writes via API)
- ns2 is read-only replica (AXFR from ns1)

## Firewall Ports

The following ports are used:

| Port | Protocol | Service | Binding | Access |
|------|----------|---------|---------|--------|
| 53 | TCP/UDP | DNS queries | `0.0.0.0` | Public |

**No other ports exposed** (no API, no web server).

**Replication ports (NetBird mesh only):**
- NOTIFY: ns1 NetBird IP → ns2 NetBird IP (UDP 53)
- AXFR: ns2 NetBird IP → ns1 NetBird IP (TCP 53)

## Troubleshooting

### PowerDNS not starting

```bash
# Check logs
docker logs powerdns-slave

# Common issues:
# - Invalid pdns.conf syntax
# - SQLite database permissions
# - Cannot resolve ns1 NetBird IP

# Check SQLite database
docker exec powerdns-slave ls -lh /var/lib/powerdns/
```

### Zone replication not working

```bash
# Check if ns2 received NOTIFY
docker logs powerdns-slave | grep NOTIFY

# Expected:
# Received NOTIFY for zone example.com from 100.64.0.1

# If no NOTIFY received, check ns1 configuration
# Verify ns1 is sending NOTIFY to ns2 NetBird IP (not public IP)

# On ns1:
docker exec powerdns-auth pdns_control show also-notify
# Should show ns2 NetBird IP
```

### AXFR not working

```bash
# Check AXFR logs on ns2
docker logs powerdns-slave | grep AXFR

# Expected:
# AXFR started for example.com
# AXFR of zone example.com completed

# Common issues:
# - ns1 NetBird IP not reachable
# - AXFR blocked by firewall on ns1
# - AXFR timeout (increase powerdns_axfr_fetch_timeout)

# Test NetBird connectivity from ns2 to ns1
docker exec powerdns-slave ping -c 3 {{ hostvars['ns1']['netbird_ip'] }}
```

### Zone data not matching ns1

```bash
# Compare SOA serial on both servers
dig @23.88.111.142 example.com SOA  # ns1
dig @89.167.125.29 example.com SOA  # ns2

# Serials should match (after replication completes)

# Force AXFR refresh
docker exec powerdns-slave pdns_control retrieve example.com
```

### NetBird IP not found

```bash
# Verify NetBird peer is running on ns2
systemctl status netbird

# Check NetBird interface
ip -4 addr show wt0

# If no wt0 interface, NetBird peer not connected
# Deploy netbird_peer role first
```

## Backup and Restore

### Backup SQLite Data

```bash
# Backup using Docker volume
docker run --rm \
  -v powerdns_pdns_data:/data \
  -v /backups:/backup \
  alpine tar czf /backup/powerdns-slave-$(date +%Y%m%d).tar.gz /data

# Or copy SQLite file directly
docker exec powerdns-slave sqlite3 /var/lib/powerdns/pdns.sqlite3 ".backup /tmp/pdns-backup.db"
docker cp powerdns-slave:/tmp/pdns-backup.db /backups/
```

### Restore SQLite Data

```bash
# Stop PowerDNS
cd /opt/powerdns
docker compose down

# Restore volume
docker run --rm \
  -v powerdns_pdns_data:/data \
  -v /backups:/backup \
  alpine sh -c "cd / && tar xzf /backup/powerdns-slave-20260311.tar.gz"

# Restart
docker compose up -d
```

### Rebuild from ns1 (No Backup Needed)

```bash
# Secondary can always rebuild from primary
cd /opt/powerdns
docker compose down

# Remove SQLite database
docker volume rm powerdns_pdns_data

# Restart (will auto-create empty database)
docker compose up -d

# Zones will auto-replicate via AXFR from ns1
# (autosecondary mode creates zones on first NOTIFY)
```

## Monitoring

### Key Metrics

```yaml
PowerDNS Metrics:
  - DNS query response time (target: < 10ms)
  - Zone count (should match ns1)
  - AXFR transfer count (from ns1)
  - AXFR transfer lag (target: < 5 seconds)
  - SQLite database size

Container Health:
  - powerdns-slave (must be running)
```

### Health Checks

```bash
# DNS health
dig @localhost phoenix-host.net SOA

# Zone list
docker exec powerdns-slave pdns_control list-zones

# Compare with ns1 zone count
ssh root@23.88.111.142 "docker exec powerdns-nginx curl -s -H 'X-API-Key: KEY' http://pdns:8081/api/v1/servers/localhost/zones | jq length"
docker exec powerdns-slave pdns_control list-zones | wc -l
# Should match
```

## Upgrading

### Upgrade PowerDNS

```bash
# Update image version in defaults/main.yml
powerdns_version: "4.10"

# Re-run Ansible
ansible-playbook site.yml --limit ns2 --tags powerdns_slave

# Or manually
cd /opt/powerdns
docker compose pull
docker compose up -d
```

## Security Notes

1. **NetBird Mesh Only:** NOTIFY and AXFR only via NetBird encrypted mesh
2. **No Public AXFR:** Zone transfers never served to public internet
3. **No API:** Secondary has no management API (read-only)
4. **Autosecondary:** Zones auto-created on NOTIFY (no manual configuration)
5. **DNSSEC:** Signatures replicated via AXFR (signed by ns1)

## Performance Notes

**SQLite vs PostgreSQL:**
- SQLite is sufficient for secondary (read-only workload)
- Lower memory footprint (~50MB vs ~200MB)
- Simpler backup (single file)
- No complex replication (AXFR handles zone sync)

**Zone replication speed:**
- Target: < 5 seconds from ns1 change to ns2 propagation
- NOTIFY is near-instant (UDP packet)
- AXFR depends on zone size (small zones < 1 second, large zones 2-5 seconds)

## License

Proprietary — Phoenix Host internal infrastructure

## Author

Phoenix Host Platform Team
