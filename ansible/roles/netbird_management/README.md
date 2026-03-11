# NetBird Management Role

> **Status:** COMPLETE — Ready for deployment  
> **Architecture:** Redundant deployment (ADR-021)  
> **Alignment:** `docs/04-deployment/FRESH_INFRASTRUCTURE_PLAN.md`

## Overview

This role deploys NetBird Management + Signal + Relay servers in a redundant configuration on both ns1 and ns2.

**Key features:**
- ✅ Both ns1 and ns2 run full NetBird stack (Management + Signal + Relay)
- ✅ Shared PostgreSQL database on ns1 (both servers connect to it)
- ✅ DNS round-robin for automatic failover (5-10 second delay)
- ✅ Prepared for floating IP migration (Phase 2+)
- ✅ Traefik reverse proxy for HTTPS (Let's Encrypt)
- ✅ Coturn TURN/STUN relay for NAT traversal

## Architecture

```
ns1 (23.88.111.142):
├── PostgreSQL (NetBird state)
├── NetBird Management API
├── NetBird Signal Server
├── NetBird Dashboard (Web UI)
├── Coturn (TURN/STUN relay)
└── Traefik (HTTPS proxy)

ns2 (89.167.125.29):
├── NetBird Management API (connects to ns1 PostgreSQL)
├── NetBird Signal Server
├── NetBird Dashboard (Web UI)
├── Coturn (TURN/STUN relay)
└── Traefik (HTTPS proxy)

DNS:
netbird.phoenix-host.net → 23.88.111.142, 89.167.125.29 (round-robin)
netbird-signal.phoenix-host.net → 23.88.111.142, 89.167.125.29 (round-robin)
```

## Requirements

- Docker CE installed (via `common` role)
- DNS domain configured (`platform_domain` variable)
- Ports 80, 443, 10000, 33071, 33073 available

## Role Variables

### Required Variables

Set in `group_vars/all.yml`:

```yaml
platform_domain: phoenix-host.net
netbird_db_name: netbird
netbird_db_user: netbird
netbird_db_host: "{{ hostvars['ns1']['ansible_host'] }}"
```

### Default Variables

See `defaults/main.yml` for all configurable options.

**Key defaults:**
- `netbird_management_version: "0.28.0"`
- `netbird_install_dir: /opt/netbird`
- `netbird_traefik_enabled: true`
- `netbird_dashboard_domain: netbird.{{ platform_domain }}`

### Sensitive Variables

**Must be set in vault or secrets file:**

```yaml
netbird_postgres_password: <strong-password>
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
# SSH to ns1
ssh -i ~/phoenix-host.key root@23.88.111.142

# Check Docker containers
docker ps

# Expected containers:
# - netbird-postgres (ns1 only)
# - netbird-management
# - netbird-signal
# - netbird-dashboard
# - netbird-coturn
# - netbird-traefik

# Check NetBird Management API health
curl http://localhost:33073/api/health

# Check PostgreSQL (ns1 only)
docker exec netbird-postgres psql -U netbird -d netbird -c "\dt"
```

### 2. Access Dashboard

Open https://netbird.phoenix-host.net in browser (should resolve to either ns1 or ns2 via DNS round-robin).

### 3. Enroll First Peer

```bash
# On admin1 or workstation
curl -sSL https://pkgs.netbird.io/install.sh | sudo bash
netbird up --setup-key <your-setup-key>
```

### 4. Test Failover

```bash
# Stop NetBird on ns1
ssh -i ~/phoenix-host.key root@23.88.111.142
cd /opt/netbird
docker compose down

# Verify Dashboard still accessible (should failover to ns2)
curl -I https://netbird.phoenix-host.net
# Should return 200 OK from ns2

# Restart ns1
docker compose up -d
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
| 5432 | TCP | PostgreSQL | ns1 → ns2 only |

These are configured in the `common` role nftables template.

## Troubleshooting

### PostgreSQL connection fails on ns2

```bash
# On ns2, test PostgreSQL connection
docker exec netbird-management psql "postgres://netbird:PASSWORD@23.88.111.142:5432/netbird" -c "\dt"

# Check PostgreSQL is listening on ns1 public IP
ssh root@23.88.111.142
docker ps | grep postgres
netstat -tlnp | grep 5432
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
