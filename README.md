# Hosting Platform Backbone

Ansible automation for deploying two fully redundant DNS + VPN mesh servers on VPS or bare metal servers.

## What It Deploys

Two Debian 13 servers (`ns1` and `ns2`) with:

| Component | Description |
|-----------|-------------|
| **WireGuard** | Infrastructure backbone tunnel (zero-dependency private network) |
| **PowerDNS 4.9** | Both nodes Native (read-write), shared PostgreSQL HA backend |
| **Traefik 3.6** | Reverse proxy with automatic TLS via DNS-01 ACME |
| **PostgreSQL 18** | Streaming replication with repmgr 5.5 and auto-failover |
| **NetBird** | WireGuard VPN mesh with management, signal, and relay on both nodes |
| **Zitadel** | Central IAM (OIDC/OAuth2) for all service authentication |
| **Gatus** | HA monitoring dashboard and alert receiver |
| **Portainer** | Docker management UI (WireGuard-only access) |
| **Restic** | Incremental encrypted backups to SFTP backup server |
| **OS hardening** | nftables firewall, fail2ban, Docker CE, SSH hardening |

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
   │ Traefik         │  │ Traefik          │
   │ PostgreSQL (HA) │  │ PostgreSQL (HA)  │
   │ NetBird mgmt    │  │ NetBird mgmt     │
   │ Restic backup   │  │ Restic backup    │
   └────────┬────────┘  └─────────┬────────┘
            │    WireGuard mesh   │
            └─────────────────────┘
```

Both PowerDNS nodes run in **Native mode** (read-write). Zone data replicates via PostgreSQL streaming replication, not AXFR. DNS API writes succeed on both nodes — each PowerDNS connects via pgproxy which always routes to the current PostgreSQL primary.

## Prerequisites

- Ansible 2.15+
- Two VPS running Debian 13
- SSH root access to both servers
- SFTP backup server for backups

## Quick Start

```bash
# 1. Run interactive setup (generates inventory + config with secrets)
cd ansible
bash setup.sh

# 2. Install Ansible collections
ansible-galaxy install -r requirements.yml

# 3. Deploy everything
ansible-playbook -i inventory/hosts.yml site.yml
```

> **Note:** Fresh deployment requires multiple runs due to circular dependencies
> between components. See [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) for the
> step-by-step bootstrap procedure.

## Targeted Deployments

```bash
ansible-playbook -i inventory/hosts.yml deploy-wireguard.yml     # WireGuard tunnel
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml       # Traefik only
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml    # PostgreSQL HA
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml      # PowerDNS (both nodes)
ansible-playbook -i inventory/hosts.yml deploy-zitadel.yml       # Zitadel IAM
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml       # NetBird management
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml # NetBird peers
ansible-playbook -i inventory/hosts.yml deploy-gatus.yml         # Gatus monitoring
ansible-playbook -i inventory/hosts.yml deploy-portainer.yml     # Portainer Docker UI
ansible-playbook -i inventory/hosts.yml deploy-backup.yml        # Backup only
```

## Repository Structure

```
ansible/
├── site.yml                 # Main playbook (all roles in dependency order)
├── deploy-*.yml             # Targeted playbooks for individual components
├── inventory/hosts.yml      # Server inventory (gitignored)
├── group_vars/all.yml       # Global variables (gitignored)
├── host_vars/               # Per-host overrides
└── roles/
    ├── common/              # OS hardening, nftables, Docker, fail2ban
    ├── wireguard/           # WireGuard infrastructure tunnel (zero-dep backbone)
    ├── traefik/             # Traefik v3.6, DNS-01 ACME via local PowerDNS
    ├── postgresql_repmgr/   # PostgreSQL 18 + repmgr 5.5 HA
    ├── powerdns/            # PowerDNS 4.9 (both nodes, shared PostgreSQL HA backend)
    ├── zitadel/             # Zitadel IAM (OIDC/OAuth2, multi-tenant)
    ├── netbird_management/  # NetBird combined server (Zitadel auth)
    ├── netbird_peer/        # NetBird peer enrollment
    ├── gatus/               # Gatus monitoring (HA dashboard + alert receiver)
    ├── portainer/           # Portainer CE Docker management (WireGuard-only)
    └── backup/              # Restic to SFTP backup server
docs/                        # Architecture and operations documentation
```

## Documentation

| Document | Description |
|----------|-------------|
| [AGENTS.md](AGENTS.md) | Agent/developer handoff with gotchas and instructions |
| [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) | Step-by-step fresh deployment procedure |
| [docs/RECOVERY.md](docs/RECOVERY.md) | Disaster recovery runbook |
| [docs/DISPERSED_DNS_ARCHITECTURE.md](docs/DISPERSED_DNS_ARCHITECTURE.md) | PowerDNS dual-primary Native mode architecture |

## Configuration

Sensitive configuration is kept in gitignored files. Example files are provided:

| File | Purpose |
|------|---------|
| `ansible/inventory/hosts.example.yml` | Server IPs, hostnames, WireGuard IPs |
| `ansible/group_vars/all.example.yml` | Domain, API keys, passwords, backup config |

Copy these to their non-example counterparts and fill in your values.

## License

Private repository. All rights reserved.
