# Phoenix Host — Kubernetes Web Hosting Platform

> **Domain:** phoenix-host.net  
> **Status:** Phase 1 — Active development  
> **Infrastructure:** k3s on Hetzner (Falkenstein + Helsinki)  
> **Team:** 1-2 engineers

A self-managed Kubernetes hosting platform replacing Plesk with automated client provisioning, multi-tenant isolation, and a full admin + client control panel.

---

## Repository Structure

```
hosting-platform/
├── docs/                     # All planning and architecture documentation
│   ├── 01-core/              # Platform architecture, hosting plans, DNS
│   ├── 02-operations/        # Admin panel, backup, monitoring, sizing
│   ├── 03-security/          # Security architecture, compliance, TLS
│   ├── 04-deployment/        # CI/CD, roadmap, GitHub setup, API spec
│   ├── 05-advanced/          # Geographic sharding, DR, multi-cloud
│   ├── 06-features/          # Feature specs (WAF, FTP, webmail, cron, etc.)
│   └── 07-reference/         # Tech stack, migration plan, FAQ, glossary
│
├── ansible/                  # Server configuration (DNS + NetBird VPS)
│   ├── inventory/            # Host inventory (ns1, ns2)
│   ├── roles/
│   │   ├── common/           # Base OS hardening for all servers
│   │   ├── powerdns-master/  # PowerDNS authoritative master (ns1, Falkenstein)
│   │   ├── powerdns-slave/   # PowerDNS AXFR slave (ns2, Helsinki)
│   │   ├── netbird-management/ # NetBird management server (ns1)
│   │   └── netbird-peer/     # NetBird peer enrollment (ns2 + future nodes)
│   ├── group_vars/           # Shared variables per group
│   ├── host_vars/            # Per-host variable overrides
│   ├── site.yml              # Master playbook
│   ├── dns.yml               # DNS-only playbook
│   └── netbird.yml           # NetBird-only playbook
│
├── terraform/
│   ├── dns-netbird/          # Future: reprovisioning DNS/NetBird VPS
│   └── k8s-cluster/          # Hetzner k3s cluster provisioning (Phase 1)
│
├── backend/                  # Node.js + Fastify management API
├── frontend/
│   ├── admin-panel/          # React 18 + Vite + shadcn/ui
│   └── client-panel/         # React 18 + Vite + shadcn/ui
├── migration-service/        # Plesk / cPanel / Virtualmin extractor
├── k8s/                      # Kubernetes manifests (Kustomize)
│   ├── base/
│   └── overlays/
│       ├── staging/
│       └── production/
├── helm/                     # Helm charts for platform services
├── catalog-images/           # Dockerfiles for workload catalog images
├── ops/                      # Operational shell scripts
│   ├── dns/                  # DNS management scripts
│   └── netbird/              # NetBird peer management scripts
└── scripts/                  # One-off utility scripts
```

---

## Quick Start

### Prerequisites

- Ansible 2.15+
- Two Hetzner VPS already provisioned (Debian 12):
  - `ns1.phoenix-host.net` — Falkenstein (primary DNS + NetBird management)
  - `ns2.phoenix-host.net` — Helsinki (secondary DNS + NetBird peer)
- SSH access to both servers

### 1. Configure inventory

```bash
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
# Edit hosts.yml with your actual server IPs
```

### 2. Configure variables

```bash
cp ansible/group_vars/all.example.yml ansible/group_vars/all.yml
# Edit all.yml — set domain, IPs, AXFR allow-list
```

### 3. Deploy DNS + NetBird

```bash
# Full setup (both servers)
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml

# DNS only
ansible-playbook -i inventory/hosts.yml dns.yml

# NetBird only
ansible-playbook -i inventory/hosts.yml netbird.yml
```

---

## Infrastructure Overview

| Server | Location | Role | IP |
|--------|----------|------|----|
| `ns1.phoenix-host.net` | Hetzner Falkenstein (nbg1) | PowerDNS master + NetBird management | TBD |
| `ns2.phoenix-host.net` | Hetzner Helsinki (hel1) | PowerDNS slave + NetBird peer | TBD |
| k3s control plane | Hetzner Falkenstein | Kubernetes control plane (Phase 1) | TBD |
| k3s worker(s) | Hetzner Falkenstein | Kubernetes workers | TBD |

---

## Documentation

Start with [`docs/QUICKSTART.md`](docs/QUICKSTART.md) for a full documentation index.

Key documents:
- **Architecture:** [`docs/01-core/PLATFORM_ARCHITECTURE.md`](docs/01-core/PLATFORM_ARCHITECTURE.md)
- **Phase 1 Roadmap:** [`docs/04-deployment/PHASE_1_ROADMAP.md`](docs/04-deployment/PHASE_1_ROADMAP.md)
- **DNS Architecture:** [`docs/01-core/DISPERSED_DNS_ARCHITECTURE.md`](docs/01-core/DISPERSED_DNS_ARCHITECTURE.md)
- **Admin Panel Spec:** [`docs/02-operations/ADMIN_PANEL_REQUIREMENTS.md`](docs/02-operations/ADMIN_PANEL_REQUIREMENTS.md)

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Kubernetes | k3s on Debian 13 |
| Ingress | NGINX Ingress Controller |
| DNS | PowerDNS (self-hosted) |
| Admin VPN | NetBird (WireGuard mesh) |
| Storage | Longhorn |
| Databases | Percona MariaDB + CloudNativePG |
| Cache | Redis |
| Auth | Dex (OIDC) |
| Secrets | Sealed Secrets |
| Monitoring | Prometheus + Grafana + Loki |
| Email | Docker-Mailserver + Roundcube |
| Registry | Harbor + Trivy |
| GitOps | Flux v2 |
| IaC | Terraform + Ansible |

See [`docs/07-reference/TECH_STACK_SUMMARY.md`](docs/07-reference/TECH_STACK_SUMMARY.md) for the full list.

---

## Hosting Plans

| Plan | Price | Model |
|------|-------|-------|
| Starter | $5.99/mo | Shared pod (20-50 clients/pod) |
| Business | $19.99/mo | Dedicated pod |
| Premium | $49.99/mo | Dedicated pod + resources + WAF |

See [`docs/01-core/HOSTING_PLANS.md`](docs/01-core/HOSTING_PLANS.md) for full details.
