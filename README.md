# Backbone

Provider-agnostic Ansible automation for deploying a fully redundant, self-healing infrastructure backbone on two geographically separated servers.

Project home: https://github.com/insulahq/backbone (formerly `hosting-platform-backbone`)

## What It Deploys

Two Debian 13 servers (`ns1` and `ns2`) with automatic failover, encrypted backups, and comprehensive monitoring:

| Component | Description |
|-----------|-------------|
| **WireGuard** | Infrastructure backbone tunnel (zero-dependency private network) |
| **PowerDNS 5.0** | Authoritative DNS, Native mode (read-write on both nodes), PostgreSQL HA backend |
| **Traefik 3.7** | Reverse proxy with automatic TLS via DNS-01 ACME, rate limiting |
| **PostgreSQL 18** | Streaming replication with repmgr 5.5, auto-failover (~60s), split-brain prevention |
| **NetBird 0.67.0** | WireGuard VPN mesh (management + signal + relay), embedded Dex IdP |
| **Zitadel** | Central IAM (OIDC/OAuth2) for service authentication |
| **Gatus** | HA monitoring dashboard, active health checks, multi-channel alerting |
| **Portainer** | Docker management UI (VPN-only access) |
| **OpenZiti 1.4.1** | Zero-trust network overlay, active-standby controller, active-active edge routers |
| **Uptime Kuma** | Optional UI-based monitoring for user-managed checks (supplements Gatus) |
| **Restic** | Encrypted incremental backups to SFTP or S3-compatible storage |
| **OS hardening** | nftables firewall, fail2ban, SSH hardening, Docker CE |

## Architecture

```
                    Internet
                       │
            ┌──────────┴──────────┐
            │                     │
   ┌────────┴────────┐  ┌────────┴─────────┐
   │      ns1        │  │      ns2         │
   │  Location A     │  │   Location B     │
   ├─────────────────┤  ├──────────────────┤
   │ PowerDNS (r/w)  │  │ PowerDNS (r/w)   │
   │ Traefik (TLS)   │  │ Traefik (TLS)    │
   │ PostgreSQL (HA) │  │ PostgreSQL (HA)  │
   │ NetBird mgmt    │  │ NetBird mgmt     │
   │ Zitadel IAM     │  │ Zitadel IAM      │
   │ OpenZiti overlay │  │ OpenZiti overlay  │
   │ Gatus monitor   │  │ Gatus monitor    │
   │ Restic backup   │  │ Restic backup    │
   └────────┬────────┘  └─────────┬────────┘
            │  WireGuard tunnel   │
            │  (10.100.0.1/2)     │
            └─────────────────────┘
```

**Active-passive DNS failover:** The `pg-role-watchdog` detects PostgreSQL role changes every 10s and automatically switches DNS records, restarts dependent services, and updates the write proxy — all within ~80s of a node failure.

**Write routing:** Services connect to PostgreSQL via `pgproxy`, a self-updating TCP proxy that always routes to the current primary. After failover, pgproxy re-targets within 5s.

## High Availability

| Scenario | Recovery | Data Loss |
|----------|----------|-----------|
| Single node failure | Automatic (~80s) | None (streaming replication) |
| OpenZiti controller failure | Automatic (~90s, watchdog) | None (DB synced to standby) |
| PostgreSQL crash | Automatic (Docker restart + repmgr) | None |
| Both nodes down, one reboots | Automatic (self-promotion after 300s) | None |
| Full disaster (both nodes lost) | Manual rebuild from backup | Up to 24h (daily backup RPO) |

Split-brain prevention uses 4 layers: startup role detection, external connectivity validation, runtime watchdog, and demotion markers.

## Backup & Restore

Restic backs up to **SFTP** or **S3-compatible storage** (AWS, MinIO, Wasabi, Backblaze B2):

- **Database:** `pg_dumpall` piped directly to restic (no plaintext on disk)
- **Files:** All service configs + data under `/opt` (Traefik certs, NetBird state, etc.)
- **Schedule:** Daily at 02:00 UTC, 7 daily / 4 weekly / 12 monthly / 2 yearly retention
- **Integrity:** Weekly 5% data verification
- **Alerting:** Failures pushed to Gatus dashboard + optional webhook/email

```bash
# On-server restore helper
/etc/restic/restore.sh list              # List snapshots
/etc/restic/restore.sh database --load   # Restore database
/etc/restic/restore.sh files             # Restore all files

# Ansible restore playbook
ansible-playbook -i inventory/hosts.yml restore.yml --limit ns1
```

See [docs/RECOVERY.md](docs/RECOVERY.md) for 13 detailed disaster recovery scenarios.

> **CRITICAL:** Back up `ansible/.generated_secrets/` offline — it contains the restic password and Zitadel masterkey (both irrecoverable if lost). See the [Offline Secrets Procedure](docs/RECOVERY.md#offline-secrets-procedure).

## Testing

Automated assertions validate the entire infrastructure:

```bash
# Non-destructive tests (DNS, TLS, PostgreSQL, NetBird, services)
ansible-playbook -i inventory/hosts.yml test-suite.yml

# Destructive failover tests (promotion, DNS switch, recovery)
ansible-playbook -i inventory/hosts.yml test-suite.yml --tags failover
```

Failover tests include pre-flight health gates and post-flight verification on both nodes.

## Monitoring & Alerting

Gatus provides active monitoring with multi-channel alerts:

- **Active probes:** DNS resolution, TLS certificates, Traefik, Zitadel, NetBird, OpenZiti Edge API + console
- **External endpoints:** Backup status, disk space, Docker health, PostgreSQL, repmgr, write-health
- **Alert channels:** Slack, Discord, ntfy, Email, Telegram, PagerDuty, custom webhooks
- **Dashboard:** HTTPS at `status.<domain>` behind Traefik

## Prerequisites

- Ansible 2.15+ with `community.docker` collection
- Two VPS/bare-metal servers running Debian 13 (geographically separated)
- SSH root access to both servers
- Domain with NS glue records pointing to both server IPs
- Backup storage: SFTP server or S3-compatible bucket

## Quick Start

```bash
# 1. Run interactive setup (generates inventory + secrets)
cd ansible
bash setup.sh

# 2. Install Ansible collections
ansible-galaxy install -r requirements.yml

# 3. Deploy everything
ansible-playbook -i inventory/hosts.yml site.yml
```

> See [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) for the detailed step-by-step bootstrap procedure including manual post-deployment steps (Zitadel setup, NetBird enrollment).

## Targeted Deployments

```bash
ansible-playbook -i inventory/hosts.yml deploy-wireguard.yml     # WireGuard tunnel
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml    # PostgreSQL HA
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml      # PowerDNS (both nodes)
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml       # Traefik reverse proxy
ansible-playbook -i inventory/hosts.yml deploy-zitadel.yml       # Zitadel IAM
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml       # NetBird management
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml # NetBird peers
ansible-playbook -i inventory/hosts.yml deploy-gatus.yml         # Gatus monitoring
ansible-playbook -i inventory/hosts.yml deploy-portainer.yml     # Portainer UI
ansible-playbook -i inventory/hosts.yml deploy-openziti.yml       # OpenZiti overlay
ansible-playbook -i inventory/hosts.yml deploy-backup.yml        # Backup (SFTP or S3)

# Zero-downtime container updates
ansible-playbook -i inventory/hosts.yml rolling-update.yml
```

## Repository Structure

```
ansible/
├── site.yml                 # Main playbook (phased: backbone → primary → secondary)
├── deploy-*.yml             # Targeted playbooks for individual components
├── rolling-update.yml       # Zero-downtime container updates
├── test-suite.yml           # 87 automated infrastructure tests
├── restore.yml              # Backup restore playbook
├── inventory/hosts.yml      # Server inventory (gitignored)
├── group_vars/all.yml       # Global configuration (gitignored)
└── roles/
    ├── common/              # OS hardening, nftables, Docker, fail2ban, monitoring scripts
    ├── wireguard/           # WireGuard infrastructure tunnel
    ├── postgresql_repmgr/   # PostgreSQL 18 + repmgr 5.5 HA + pgproxy + watchdog
    ├── powerdns/            # PowerDNS 5.0 (Native mode, shared PG backend)
    ├── traefik/             # Traefik v3.6, DNS-01 ACME, rate limiting
    ├── zitadel/             # Zitadel IAM (OIDC/OAuth2)
    ├── netbird_management/  # NetBird server (mgmt + signal + relay + embedded Dex)
    ├── netbird_peer/        # NetBird peer enrollment
    ├── gatus/               # Gatus HA monitoring + alerting
    ├── openziti/            # OpenZiti zero-trust overlay (active-standby controller + routers)
    ├── portainer/           # Portainer CE (VPN-only)
    └── backup/              # Restic backup (SFTP or S3)
docs/
├── BOOTSTRAP.md             # Fresh deployment procedure
├── RECOVERY.md              # Disaster recovery runbook (13 scenarios)
└── DISPERSED_DNS_ARCHITECTURE.md  # PowerDNS architecture
```

## Configuration

Sensitive configuration is kept in gitignored files. Examples provided:

| File | Purpose |
|------|---------|
| `ansible/inventory/hosts.example.yml` | Server IPs, hostnames, WireGuard IPs |
| `ansible/group_vars/all.example.yml` | Domain, passwords, backup config (SFTP/S3) |

Copy to non-example counterparts and fill in your values, or run `setup.sh` for interactive setup.

## Documentation

| Document | Description |
|----------|-------------|
| [AGENTS.md](AGENTS.md) | Developer handoff guide with 135+ gotchas and decision log |
| [ROADMAP.md](ROADMAP.md) | v1.0 status and 5 future phases (CDN, edge nodes, geo-DNS) |
| [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) | Step-by-step fresh deployment |
| [docs/RECOVERY.md](docs/RECOVERY.md) | Disaster recovery (13 scenarios + offline secrets) |
| [docs/DISPERSED_DNS_ARCHITECTURE.md](docs/DISPERSED_DNS_ARCHITECTURE.md) | PowerDNS dual-primary Native mode |

## License

Private repository. All rights reserved.
