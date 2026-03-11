# NetBird Management Role

> **Status:** COMPLETE — Ready for deployment  
> **Architecture:** Redundant deployment with SQLite + Litestream (ADR-021)  
> **Alignment:** `docs/04-deployment/FRESH_INFRASTRUCTURE_PLAN.md`

## Overview

This role deploys NetBird Management + Signal + Relay servers in a redundant configuration on both ns1 and ns2 with automatic failover and failback.

**Key features:**
- ✅ Both ns1 and ns2 run full NetBird stack (Management + Signal + Relay)
- ✅ SQLite + Litestream for bidirectional database replication
- ✅ Automatic failover (30s RTO, <1s RPO)
- ✅ Automatic failback with configurable policies (sticky, prefer_ns1, time_based)
- ✅ DNS round-robin for HTTP/HTTPS endpoint failover (5-10 second delay)
- ✅ Health monitoring with automatic promotion/demotion
- ✅ Traefik reverse proxy for HTTPS (Let's Encrypt)
- ✅ Coturn TURN/STUN relay for NAT traversal

## Architecture

```
ns1 (23.88.111.142) — Primary:
├── NetBird Management API (primary)
├── SQLite database (/opt/netbird/data/store.db)
├── Litestream (replicates to ns2 + Storagebox)
├── NetBird Signal Server
├── NetBird Dashboard (Web UI)
├── Coturn (TURN/STUN relay)
├── Traefik (HTTPS proxy)
└── Health Monitor (systemd service)

ns2 (89.167.125.29) — Standby:
├── NetBird Management API (standby, promoted on failure)
├── SQLite database replica (synced via Litestream)
├── Litestream (replicates to ns1 + Storagebox)
├── NetBird Signal Server
├── NetBird Dashboard (Web UI)
├── Coturn (TURN/STUN relay)
├── Traefik (HTTPS proxy)
└── Health Monitor (systemd service)

DNS:
netbird.phoenix-host.net → 23.88.111.142, 89.167.125.29 (round-robin)
netbird-signal.phoenix-host.net → 23.88.111.142, 89.167.125.29 (round-robin)

Backup:
Litestream → Hetzner Storagebox (SFTP, 7-day retention)
```

## Failover Behavior

### Automatic Failover (30s RTO)

1. **Health monitor** on ns2 detects ns1 Management API is down
2. After 30 seconds (configurable `netbird_failover_rto`), ns2 promotes itself:
   - Restores latest database from Litestream replica
   - Starts NetBird Management services
   - Updates state file (ns2 is now primary)
3. Clients automatically connect to ns2 via DNS round-robin (5-10s delay)

### Automatic Failback (20-80s)

Failback behavior depends on `netbird_failback_policy`:

| Policy | Behavior | Use Case |
|--------|----------|----------|
| `sticky` (default) | Current primary stays primary until it fails | Minimize disruption; avoid unnecessary failback |
| `prefer_ns1` | Always failback to ns1 when it recovers | ns1 is preferred primary (better hardware, etc.) |
| `time_based` | Failback after configurable delay (default 20s) | Balance between stability and consistency |

**Sticky policy (default):**
- ns1 fails → ns2 becomes primary
- ns1 recovers → ns2 stays primary (no failback)
- ns2 fails → ns1 becomes primary again

**Prefer ns1 policy:**
- ns1 fails → ns2 becomes primary
- ns1 recovers → automatic failback to ns1 after 20s

**Time-based policy:**
- ns1 fails → ns2 becomes primary
- ns1 recovers → wait 20s → failback to ns1

## Requirements

- Docker CE installed (via `common` role)
- DNS domain configured (`platform_domain` variable)
- Ports 80, 443, 10000, 33071, 33073 available

## Role Variables

### Required Variables

Set in `group_vars/all.yml`:

```yaml
platform_domain: phoenix-host.net
```

### Default Variables

See `defaults/main.yml` for all configurable options.

**Key defaults:**
- `netbird_management_version: "0.28.0"`
- `netbird_install_dir: /opt/netbird`
- `netbird_database: sqlite`
- `netbird_traefik_enabled: true`
- `netbird_dashboard_domain: netbird.{{ platform_domain }}`

**Failover/failback configuration:**
- `netbird_auto_failover: true` — Enable automatic failover
- `netbird_auto_failback: true` — Enable automatic failback
- `netbird_failback_policy: sticky` — Options: sticky, prefer_ns1, time_based
- `netbird_health_check_interval: 10` — Seconds between health checks
- `netbird_failover_rto: 30` — Recovery Time Objective (seconds)
- `netbird_failback_delay: 20` — Delay before failback (seconds)
- `netbird_primary_host: ns1` — Preferred primary server
- `netbird_standby_host: ns2` — Standby server

### Sensitive Variables

**Must be set in vault or secrets file:**

```yaml
netbird_setup_key: <64-char-random-string>
netbird_coturn_secret: <32-char-random-string>
```

If not set, the role generates random values automatically.

## Dependencies

- `common` role (Docker CE, nftables firewall)
- `community.docker.docker_compose_v2` Ansible module

Install dependencies:
```bash
ansible-galaxy collection install community.docker
```

## Example Playbook

```yaml
- name: Deploy NetBird Management on ns1 and ns2
  hosts: netbird_management
  roles:
    - netbird_management
```

## Deployment

```bash
cd /config/hosting-platform/ansible

# Deploy to both ns1 and ns2
ansible-playbook site.yml --tags netbird_management

# Or deploy to specific host
ansible-playbook site.yml --limit ns1 --tags netbird_management
```

## Post-Deployment

### 1. Verify Services

```bash
# SSH to ns1 (primary)
ssh -i ~/phoenix-host.key root@23.88.111.142

# Check Docker containers
docker ps

# Expected containers on ns1 (primary):
# - netbird-management (running)
# - netbird-litestream (running)
# - netbird-signal (running)
# - netbird-dashboard (running)
# - netbird-coturn (running)
# - netbird-traefik (running)

# Check NetBird Management API health
curl http://localhost:33073/api/health

# Check SQLite database
ls -lh /opt/netbird/data/store.db

# Check Litestream replication status
docker logs netbird-litestream

# Check health monitor
systemctl status netbird-health-monitor
tail -f /opt/netbird/logs/health-monitor.log

# Check current state
cat /opt/netbird/state/netbird-state.json
```

On ns2 (standby):

```bash
# SSH to ns2
ssh -i ~/phoenix-host.key root@89.167.125.29

# Expected containers on ns2 (standby):
# - netbird-management (NOT running, only starts on failover)
# - netbird-litestream (NOT running until promoted)
# - netbird-signal (running)
# - netbird-dashboard (running)
# - netbird-coturn (running)
# - netbird-traefik (running)

# Check health monitor
systemctl status netbird-health-monitor
tail -f /opt/netbird/logs/health-monitor.log
```

### 2. Access Dashboard

Open https://netbird.phoenix-host.net in browser (should resolve to either ns1 or ns2 via DNS round-robin).

### 3. Enroll First Peer

```bash
# On admin1 or workstation
curl -sSL https://pkgs.netbird.io/install.sh | sudo bash
netbird up --setup-key <your-setup-key>
```

### 4. Test Failover and Failback

**Test automatic failover (ns1 → ns2):**

```bash
# Stop NetBird Management on ns1
ssh -i ~/phoenix-host.key root@23.88.111.142
cd /opt/netbird
docker compose stop management litestream

# Watch health monitor on ns2 (should detect failure and promote)
ssh -i ~/phoenix-host.key root@89.167.125.29
tail -f /opt/netbird/logs/health-monitor.log

# After 30 seconds, ns2 should promote itself:
# - Restores database from Litestream
# - Starts NetBird Management
# - Updates state to primary

# Verify ns2 is now primary
cat /opt/netbird/state/netbird-state.json
docker ps | grep netbird-management  # Should be running

# Verify Dashboard still accessible (via ns2)
curl -I https://netbird.phoenix-host.net
# Should return 200 OK from ns2
```

**Test automatic failback (depends on policy):**

If `netbird_failback_policy: prefer_ns1`:

```bash
# Restart ns1
ssh -i ~/phoenix-host.key root@23.88.111.142
cd /opt/netbird
docker compose up -d

# Watch health monitor on ns1 (should detect ns2 is healthy and take over)
tail -f /opt/netbird/logs/health-monitor.log

# After 20 seconds (netbird_failback_delay), ns1 should promote itself
# ns2 health monitor should detect this and demote itself

# Verify ns1 is primary again
cat /opt/netbird/state/netbird-state.json
```

If `netbird_failback_policy: sticky` (default):

```bash
# Restart ns1
ssh -i ~/phoenix-host.key root@23.88.111.142
cd /opt/netbird
docker compose up -d

# ns2 stays primary (no automatic failback)
# ns1 stays standby until ns2 fails
```

## DNS Configuration

The role creates these DNS records via PowerDNS API (if `netbird_setup_dns: true`):

```
netbird.phoenix-host.net.          IN  A  23.88.111.142
netbird.phoenix-host.net.          IN  A  89.167.125.29
netbird-signal.phoenix-host.net.   IN  A  23.88.111.142
netbird-signal.phoenix-host.net.   IN  A  89.167.125.29
```

## Firewall Ports

The following ports must be accessible:

| Port | Protocol | Service | Access |
|------|----------|---------|--------|
| 80 | TCP | HTTP (redirect to HTTPS) | Public |
| 443 | TCP | HTTPS (Dashboard, Management API) | Public |
| 10000 | UDP | TURN/STUN relay | Public |
| 33071 | TCP | Management gRPC | Internal (via NetBird mesh) |
| 33073 | TCP | Management API | Internal (via NetBird mesh) |

These are configured in the `common` role nftables template.

## Troubleshooting

### Failover not happening

```bash
# Check health monitor logs on standby
tail -f /opt/netbird/logs/health-monitor.log

# Check if auto-failover is enabled
grep auto_failover /opt/netbird/netbird-health-monitor.sh

# Manually trigger failover test
/opt/netbird/netbird-promote.sh
```

### Database replication issues

```bash
# Check Litestream logs
docker logs netbird-litestream

# Check database file size on both servers
ls -lh /opt/netbird/data/store.db

# Check Litestream replica directory
ls -lh /opt/netbird/litestream/

# Test Litestream restore manually
docker run --rm \
  -v /opt/netbird/data:/var/lib/netbird \
  -v /opt/netbird/litestream.yml:/etc/litestream.yml \
  litestream/litestream:0.3.13 \
  restore -v /var/lib/netbird/store.db
```

### Split-brain scenario

```bash
# Both servers think they are primary (both running Management)
# Health monitor should detect and resolve automatically

# Check state file on both servers
cat /opt/netbird/state/netbird-state.json

# Manually demote one server
/opt/netbird/netbird-demote.sh
```

### Dashboard not accessible

```bash
# Check Traefik logs
docker logs netbird-traefik

# Check Let's Encrypt certificate
docker exec netbird-traefik cat /acme.json | jq .
```

### Clients cannot connect

```bash
# Check Signal server
docker logs netbird-signal

# Check Coturn relay
docker logs netbird-coturn

# Verify DNS records
dig netbird.phoenix-host.net
dig netbird-signal.phoenix-host.net
```

## Upgrading to Floating IP (Phase 2+)

See `docs/04-deployment/FRESH_INFRASTRUCTURE_PLAN.md` §Future Upgrade Path for detailed migration procedure.

**Summary:**
1. Provision floating IP (keepalived or Hetzner Cloud)
2. Update DNS to single A record pointing to floating IP
3. Update `group_vars/all.yml`:
   ```yaml
   netbird_redundancy: floating_ip
   netbird_floating_ip: 100.76.100.100
   ```
4. Re-run Ansible playbook

No application changes required.

## License

Proprietary — Phoenix Host internal infrastructure

## Author

Phoenix Host Platform Team
