# PowerDNS Master Role

> **Status:** COMPLETE — Ready for deployment  
> **Architecture:** Primary DNS server with Docker internal networks  
> **Alignment:** `docs/01-core/DISPERSED_DNS_ARCHITECTURE.md`

## Overview

This role deploys PowerDNS Authoritative Server as the primary DNS server on ns1 with:
- PostgreSQL backend for zone storage
- PowerDNS-Admin web UI for internal management
- Nginx proxy exposing API + Admin UI on NetBird interface only
- Docker internal network for service isolation

**Key features:**
- ✅ DNS publicly accessible (port 53)
- ✅ API and Admin UI only accessible via NetBird mesh
- ✅ No advanced NAT rules (lesson learned from previous deployment)
- ✅ Docker internal network prevents public exposure
- ✅ AXFR/NOTIFY to ns2 for zone replication
- ✅ DNSSEC support enabled

## Architecture

```
ns1 (PowerDNS Primary):

Docker Networks:
├── powerdns_internal (isolated, no external access)
│   ├── postgres (PostgreSQL 16)
│   │   └── Databases: powerdns, pdnsadmin
│   ├── pdns (PowerDNS Auth 4.9)
│   │   └── Backend: PostgreSQL
│   ├── pdns-admin (PowerDNS-Admin 0.4.1)
│   │   └── Backend: PostgreSQL
│   └── nginx (Nginx reverse proxy)
│       ├── Port 8081 → PowerDNS API
│       └── Port 8080 → PowerDNS-Admin UI

Host Network:
├── 0.0.0.0:53 → pdns (DNS public)
└── {{ netbird_ip }}:8081 → nginx → pdns API (NetBird only)
└── {{ netbird_ip }}:8080 → nginx → pdns-admin (NetBird only)

Zone Replication:
ns1 → NOTIFY → ns2 AXFR (< 5 seconds propagation)
```

## Security Design

### Why Docker Internal Networks?

From **Critical Gotchas §7** in AGENTS.md:
> "Advanced nftables pre/post-routing rules broke ns1 access"

**Problem with previous approach:**
- Docker `0.0.0.0` port bindings bypass firewall INPUT chain
- Traffic goes through FORWARD chain instead
- Advanced DNAT/SNAT rules attempted to bind to NetBird interface
- **Result:** ns1 became inaccessible

**Solution:**
1. **Docker internal network:** Services isolated, no host access by default
2. **Nginx proxy:** Single entry point, bound to NetBird interface
3. **Simple firewall:** No advanced NAT rules needed
4. **DNS public:** Only port 53 exposed to `0.0.0.0`

### Access Control

| Service | Port | Binding | Access |
|---------|------|---------|--------|
| DNS (PowerDNS) | 53 | `0.0.0.0` | Public (all networks) |
| PowerDNS API | 8081 | `{{ netbird_ip }}` | NetBird mesh only |
| PowerDNS-Admin UI | 8080 | `{{ netbird_ip }}` | NetBird mesh only |
| PostgreSQL | 5432 | (internal network) | Docker containers only |

**Public cannot access:**
- ❌ PowerDNS API (no zone manipulation)
- ❌ PowerDNS-Admin UI (no web access)
- ❌ PostgreSQL (no database access)

**NetBird mesh can access:**
- ✅ PowerDNS API (Management API on admin1)
- ✅ PowerDNS-Admin UI (browser from workstation)
- ✅ DNS queries (via public interface)

## Requirements

### Infrastructure Dependencies

**Must be deployed first:**
1. `common` role — Docker CE, nftables firewall, fail2ban
2. `netbird_management` role — NetBird Management on ns1 + ns2
3. `netbird_peer` role — NetBird peer on ns1 (to get NetBird IP)

**Deployment order:**
```
common → netbird_management → netbird_peer → powerdns_master
```

**Critical:** `netbird_ip` variable must be set before deploying this role.

### System Requirements

- Docker CE 20.10+
- Docker Compose v2.24+
- 2GB RAM minimum (PostgreSQL + PowerDNS + nginx)
- 10GB disk space (zone data, logs)

## Role Variables

### Required Variables

Set in `group_vars/all.yml`:

```yaml
platform_domain: phoenix-host.net
netbird_ip: "100.64.0.1"  # NetBird mesh IP (obtained from netbird_peer role)

# Secrets (store in vault)
powerdns_api_key: "<64-char-random-string>"
powerdns_db_password: "<32-char-random-string>"
powerdns_admin_sqla_db_password: "<32-char-random-string>"
powerdns_admin_secret_key: "<64-char-random-string>"
```

### Default Variables

See `defaults/main.yml` for all configurable options.

**Key defaults:**
- `powerdns_version: "4.9"`
- `powerdns_install_dir: /opt/powerdns`
- `powerdns_primary: yes`
- `powerdns_api_enabled: yes`
- `powerdns_admin_enabled: yes`
- `powerdns_dnssec_enabled: yes`
- `powerdns_nginx_api_port: 8081`
- `powerdns_nginx_admin_port: 8080`

### Zone Replication

```yaml
powerdns_allow_axfr_ips:
  - "{{ hostvars['ns2']['ansible_host'] }}"  # ns2 can pull zones

powerdns_also_notify:
  - "{{ hostvars['ns2']['ansible_host'] }}"  # Notify ns2 on changes
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

## Example Playbook

```yaml
- name: Deploy PowerDNS Master on ns1
  hosts: ns1
  roles:
    - powerdns_master
```

## Deployment

**Prerequisites:**
1. ✅ Common role deployed (Docker, firewall)
2. ✅ NetBird Management deployed (ns1 + ns2)
3. ✅ NetBird peer deployed (ns1, ns2, admin1)
4. ✅ NetBird IP captured: `netbird_ip` variable set
5. ✅ Secrets configured in vault or group_vars

**Get NetBird IP:**

```bash
# SSH to ns1
ssh -i ~/phoenix-host.key root@23.88.111.142

# Get NetBird interface IP
ip -4 addr show wt0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
# Example output: 100.64.0.1

# Add to group_vars/all.yml or host_vars/ns1.yml
# netbird_ip: "100.64.0.1"
```

**Deploy PowerDNS:**

```bash
cd /config/hosting-platform/ansible

# Deploy to ns1
ansible-playbook site.yml --limit ns1 --tags powerdns_master
```

**First deployment:**
- PostgreSQL initialized with `powerdns` and `pdnsadmin` databases
- PowerDNS starts and auto-creates schema
- PowerDNS-Admin starts and auto-creates tables
- Platform zone (`phoenix-host.net`) created automatically
- Services bound to NetBird interface only

## Post-Deployment

### 1. Verify Services

```bash
# SSH to ns1
ssh -i ~/phoenix-host.key root@23.88.111.142

# Check Docker containers
docker ps

# Expected containers:
# - powerdns-postgres (running)
# - powerdns-auth (running)
# - powerdns-admin (running)
# - powerdns-nginx (running)

# Check DNS server (public)
dig @23.88.111.142 phoenix-host.net SOA
# Should return SOA record

# Check PowerDNS API (from NetBird mesh only)
curl -H "X-API-Key: YOUR_API_KEY" http://100.64.0.1:8081/api/v1/servers/localhost
# Should return server info JSON
```

### 2. Access PowerDNS-Admin UI

**From workstation (connected to NetBird mesh):**

1. Open browser to `http://100.64.0.1:8080` (NetBird IP)
2. First visit will show setup wizard
3. Create admin account
4. Configure PowerDNS API connection (already pre-configured)

**PowerDNS-Admin configuration:**
- PowerDNS API URL: `http://pdns:8081` (internal Docker network)
- PowerDNS API Key: (already configured via environment variables)
- PowerDNS Version: `4.9`

### 3. Create First Zone

**Via PowerDNS-Admin UI:**
1. Login to PowerDNS-Admin
2. Dashboard → New Domain
3. Enter domain name (e.g., `example.com`)
4. Select "Master" type
5. Click Create

**Via PowerDNS API:**

```bash
# Create zone via API (from NetBird mesh)
curl -X POST http://100.64.0.1:8081/api/v1/servers/localhost/zones \
  -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "example.com.",
    "kind": "Master",
    "nameservers": [
      "ns1.phoenix-host.net.",
      "ns2.phoenix-host.net."
    ]
  }'

# Add A record
curl -X PATCH http://100.64.0.1:8081/api/v1/servers/localhost/zones/example.com. \
  -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "rrsets": [
      {
        "name": "www.example.com.",
        "type": "A",
        "changetype": "REPLACE",
        "records": [
          {
            "content": "192.0.2.1",
            "disabled": false
          }
        ]
      }
    ]
  }'
```

### 4. Test Zone Replication (after deploying powerdns_slave on ns2)

```bash
# Create test record on ns1
dig @23.88.111.142 test.phoenix-host.net A

# Wait 5 seconds for NOTIFY + AXFR

# Check on ns2
dig @89.167.125.29 test.phoenix-host.net A

# Should match ns1 record (< 5 seconds propagation)
```

## DNS Configuration

The role automatically creates the platform zone (`phoenix-host.net`) with SOA record.

**Nameservers:**
- `ns1.phoenix-host.net` (23.88.111.142) — Primary
- `ns2.phoenix-host.net` (89.167.125.29) — Secondary (after deploying powerdns_slave)

**SOA Record:**
```
phoenix-host.net.  IN  SOA  ns1.phoenix-host.net. admin.phoenix-host.net. (
    2026031101  ; Serial (auto-incremented)
    10800       ; Refresh (3 hours)
    3600        ; Retry (1 hour)
    604800      ; Expire (1 week)
    3600        ; Minimum TTL (1 hour)
)
```

## Firewall Ports

The following ports are used:

| Port | Protocol | Service | Binding | Access |
|------|----------|---------|---------|--------|
| 53 | TCP/UDP | DNS queries | `0.0.0.0` | Public |
| 8081 | TCP | PowerDNS API | `{{ netbird_ip }}` | NetBird only |
| 8080 | TCP | PowerDNS-Admin UI | `{{ netbird_ip }}` | NetBird only |

**No firewall rules needed** (Docker handles network isolation).

## Troubleshooting

### PowerDNS not starting

```bash
# Check logs
docker logs powerdns-auth

# Common issues:
# - PostgreSQL not ready (wait for healthcheck)
# - Invalid pdns.conf syntax
# - Database connection failed

# Check PostgreSQL
docker logs powerdns-postgres
docker exec powerdns-postgres psql -U pdns -d powerdns -c "\dt"
```

### PowerDNS API not accessible

```bash
# Check nginx proxy
docker logs powerdns-nginx

# Test API directly (inside Docker network)
docker exec powerdns-nginx curl http://pdns:8081/api/v1/servers/localhost

# Check binding (should be NetBird IP)
netstat -tlnp | grep 8081

# Verify NetBird IP is correct
ip -4 addr show wt0
```

### PowerDNS-Admin not accessible

```bash
# Check PowerDNS-Admin logs
docker logs powerdns-admin

# Common issues:
# - Database not initialized (PowerDNS-Admin auto-creates tables on first start)
# - SECRET_KEY not set
# - Cannot connect to PowerDNS API

# Test PowerDNS-Admin directly
docker exec powerdns-nginx curl http://pdns-admin:9191
```

### Zone not created

```bash
# Check PowerDNS API response
curl -H "X-API-Key: YOUR_API_KEY" \
  http://100.64.0.1:8081/api/v1/servers/localhost/zones

# Check zone creation error
docker logs powerdns-auth | grep -i error

# Manually create zone
curl -X POST http://100.64.0.1:8081/api/v1/servers/localhost/zones \
  -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"phoenix-host.net.","kind":"Master"}'
```

### AXFR not working (ns2 cannot pull zones)

```bash
# Check PowerDNS logs
docker logs powerdns-auth | grep -i axfr

# Verify ns2 IP is allowed
docker exec powerdns-auth pdns_control list-zones

# Test AXFR manually from ns2
dig @23.88.111.142 phoenix-host.net AXFR

# Check also-notify setting
docker exec powerdns-auth pdns_control show also-notify
```

## Backup and Restore

### Backup PostgreSQL Data

```bash
# Backup using Docker volume
docker run --rm \
  -v powerdns_postgres_data:/data \
  -v /backups:/backup \
  alpine tar czf /backup/powerdns-postgres-$(date +%Y%m%d).tar.gz /data

# Or use pg_dump
docker exec powerdns-postgres pg_dump -U pdns powerdns > /backups/powerdns-$(date +%Y%m%d).sql
```

### Restore PostgreSQL Data

```bash
# Stop PowerDNS services
cd /opt/powerdns
docker compose down

# Restore volume
docker run --rm \
  -v powerdns_postgres_data:/data \
  -v /backups:/backup \
  alpine sh -c "cd / && tar xzf /backup/powerdns-postgres-20260311.tar.gz"

# Restart services
docker compose up -d
```

### Automated Backup (Restic)

The `backup` role (deployed later) will automatically backup:
- PostgreSQL volume: `/var/lib/docker/volumes/powerdns_postgres_data`
- Configuration: `/opt/powerdns/*.conf`
- Secrets: `/opt/powerdns/.secrets`

## Monitoring

### Key Metrics

```yaml
PowerDNS Metrics:
  - DNS query response time (target: < 10ms)
  - PowerDNS API response time (target: < 100ms)
  - PostgreSQL connection count
  - Zone count
  - Record count
  - AXFR transfer count (to ns2)

Container Health:
  - powerdns-postgres (must be healthy)
  - powerdns-auth (must be running)
  - powerdns-nginx (must be running)
```

### Health Checks

```bash
# DNS health
dig @localhost phoenix-host.net SOA

# API health
curl -H "X-API-Key: YOUR_API_KEY" \
  http://100.64.0.1:8081/api/v1/servers/localhost

# Database health
docker exec powerdns-postgres pg_isready -U pdns
```

## Upgrading

### Upgrade PowerDNS

```bash
# Update image version in defaults/main.yml
powerdns_version: "4.10"

# Re-run Ansible
ansible-playbook site.yml --limit ns1 --tags powerdns_master

# Or manually
cd /opt/powerdns
docker compose pull
docker compose up -d
```

### Upgrade PowerDNS-Admin

```bash
# Update image version in defaults/main.yml
powerdns_admin_version: "0.4.2"

# Re-run Ansible
ansible-playbook site.yml --limit ns1 --tags powerdns_master
```

## Security Notes

1. **API Key:** Store `powerdns_api_key` in Ansible vault, never commit to git
2. **Database Passwords:** Store in vault, never in plain text
3. **NetBird Access Only:** API and Admin UI are only accessible via NetBird mesh
4. **AXFR Restriction:** Only ns2 IP can pull zone transfers
5. **No Public API:** PowerDNS API is never exposed to `0.0.0.0`

## License

Proprietary — Phoenix Host internal infrastructure

## Author

Phoenix Host Platform Team
