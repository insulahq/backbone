# Phoenix Host Infrastructure

Ansible automation for deploying two fully redundant DNS + VPN mesh servers on Hetzner Cloud.

## What It Deploys

Two Debian 13 servers (`ns1` and `ns2`) with:

| Component | Description |
|-----------|-------------|
| **PowerDNS 4.9** | Primary (ns1, PostgreSQL backend) + Secondary (ns2, SQLite, AXFR replication) |
| **Traefik 3.6** | Reverse proxy with automatic TLS via DNS-01 ACME |
| **PostgreSQL 18** | Streaming replication with repmgr 5.5 and auto-failover |
| **NetBird** | WireGuard VPN mesh with management, signal, and relay on both nodes |
| **Restic** | Incremental encrypted backups to Hetzner Storagebox |
| **OS hardening** | nftables firewall, fail2ban, Docker CE, SSH hardening |

## Architecture

```
                    Internet
                       │
            ┌──────────┴──────────┐
            │                     │
   ┌────────┴────────┐  ┌────────┴────────┐
   │      ns1        │  │      ns2        │
   │  Falkenstein    │  │   Helsinki      │
   ├─────────────────┤  ├─────────────────┤
   │ PowerDNS (pri)  │  │ PowerDNS (sec)  │
   │ Traefik         │  │ Traefik         │
   │ PostgreSQL (sb) │  │ PostgreSQL (pri)│
   │ NetBird mgmt    │  │ NetBird mgmt    │
   │ Restic backup   │  │ Restic backup   │
   └────────┬────────┘  └────────┬────────┘
            │    WireGuard mesh   │
            └─────────────────────┘
```

## Prerequisites

- Ansible 2.15+
- Two Hetzner VPS running Debian 13
- SSH root access to both servers
- Hetzner Storagebox for backups

## Quick Start

```bash
# 1. Configure inventory
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
# Edit with your server IPs and hostnames

# 2. Configure variables
cp ansible/group_vars/all.example.yml ansible/group_vars/all.yml
# Edit with your domain, API keys, and passwords

# 3. Deploy everything
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml
```

> **Note:** Fresh deployment requires multiple runs due to circular dependencies
> between components. See [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) for the
> step-by-step bootstrap procedure.

## Targeted Deployments

```bash
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml       # Traefik only
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml    # PostgreSQL HA
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml       # NetBird management
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml # NetBird peers
ansible-playbook -i inventory/hosts.yml deploy-netbird-ha.yml    # Traefik + PG + NetBird
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
    ├── powerdns_master/     # PowerDNS primary + PostgreSQL backend
    ├── powerdns_slave/      # PowerDNS secondary + SQLite
    ├── traefik/             # Traefik v3.6, DNS-01 ACME
    ├── postgresql_repmgr/   # PostgreSQL 18 + repmgr 5.5 HA
    ├── netbird_management/  # NetBird combined server
    ├── netbird_peer/        # NetBird peer enrollment
    └── backup/              # Restic to Hetzner Storagebox
docs/                        # Architecture and operations documentation
```

## Documentation

| Document | Description |
|----------|-------------|
| [AGENTS.md](AGENTS.md) | Agent/developer handoff with gotchas and instructions |
| [docs/BOOTSTRAP.md](docs/BOOTSTRAP.md) | Step-by-step fresh deployment procedure |
| [docs/DISPERSED_DNS_ARCHITECTURE.md](docs/DISPERSED_DNS_ARCHITECTURE.md) | PowerDNS primary/secondary architecture |
| [docs/NETBIRD_CERTIFICATE_BOOTSTRAP.md](docs/NETBIRD_CERTIFICATE_BOOTSTRAP.md) | NetBird TLS certificate bootstrap procedure |
| [docs/NETBIRD_SIGNAL_CORRECTION.md](docs/NETBIRD_SIGNAL_CORRECTION.md) | NetBird signal server configuration fix |

## Configuration

Sensitive configuration is kept in gitignored files. Example files are provided:

| File | Purpose |
|------|---------|
| `ansible/inventory/hosts.example.yml` | Server IPs, hostnames, NetBird IPs |
| `ansible/group_vars/all.example.yml` | Domain, API keys, passwords, backup config |

Copy these to their non-example counterparts and fill in your values.

## License

Private repository. All rights reserved.
