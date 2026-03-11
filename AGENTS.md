# AGENTS.md — Phoenix Host: Agent Handoff & Project Instructions

> **Read this file first. It is the single entry point for any agent or developer resuming work on this project.**
>
> All decisions must align to the documentation in `docs/`. When conflicts arise between implementation ideas and the documented vision, flag the conflict and ask the user before proceeding.

---

## 1. Project Identity & Vision

**Phoenix Host** (`phoenix-host.net`) is a self-managed Kubernetes web hosting platform replacing Plesk with:

- Automated client onboarding and resource provisioning
- Multi-tenant isolation per Kubernetes namespace
- Full admin + client control panels (React/Vite/shadcn/ui)
- Plesk/cPanel/Virtualmin migration tooling
- Integrated backup, monitoring, and DNS management

**Target:** $0–5k/month revenue, 50–100 initial clients, single Hetzner region, scale to 300+ at maturity.
**Timeline:** 12-week Phase 1 roadmap targeting first Plesk customer migration.
**Team:** 1–2 engineers. No 24/7 on-call. Business hours only.

### Vision Principles (non-negotiable)

- **Security first** — defense-in-depth, namespace isolation, no plaintext secrets, all traffic over NetBird mesh or TLS
- **Low operational cost** — infrastructure budget < $200/month; optimize every decision for cost efficiency
- **Admin-only billing model** — no customer self-service plan changes; customers manage their own hosting, admins manage subscriptions
- **Documented decisions** — every architectural choice must be traceable to an ADR or spec; if no doc exists, create one before implementing

---

## 2. Current State (Fresh Deployment Start)

**Status:** Ansible roles complete and ready for deployment.

**Last commits:**
```
2fa6e64 feat(ansible): create powerdns_slave role with NetBird mesh replication
6679591 feat(ansible): create powerdns_master role with Docker internal networks and PowerDNS-Admin
d1abfd7 feat(ansible): implement DNS-01 ACME challenge for NetBird SSL certificates
90a02b1 feat(ansible): update netbird_management role to use SQLite + Litestream with automatic failover/failback
8907566 feat(ansible): create netbird_peer role for mesh connectivity
```

**What has been preserved:**
- ✅ Management API source code (`backend/src/`)
- ✅ Admin panel source code placeholders (`frontend/admin-panel/`, `frontend/client-panel/`)
- ✅ Complete project documentation (`docs/`)
- ✅ Configuration templates (`.env.example`, `package.json`, `tsconfig.json`)

**What has been removed:**
- ❌ All Ansible roles and playbooks
- ❌ All infrastructure configuration (k8s, helm, terraform, ops, scripts)
- ❌ Docker files and build configurations
- ❌ node_modules and build artifacts
- ❌ Catalog images and migration service scaffolds

**Servers:** ns1, ns2, and admin1 will be **re-imaged**. Fresh infrastructure deployment required.

**Server IPs (confirmed):**
- ns1.phoenix-host.net: `23.88.111.142` (Hetzner Falkenstein)
- ns2.phoenix-host.net: `89.167.125.29` (Hetzner Helsinki)
- admin1.phoenix-host.net: `46.224.122.58` (Hetzner)

**Architecture Confirmed (2026-03-11):**
- ✅ OS: Debian 13 (trixie) — Official stable
- ✅ DNS: PowerDNS 4.9 (not BIND) — Aligned with ADR-016
- ✅ NetBird: Fresh deployment, **redundant** (both ns1 and ns2) — Aligned with ADR-021
- ✅ NetBird failover: DNS round-robin (now) with floating IP preparation (future)
- ✅ Firewall: Simple nftables only (NO advanced pre/post-routing)
- ✅ SSH: Break-glass access (stays open on all servers)
- ✅ Ansible: `ansible_user=root`, `ansible_ssh_private_key_file=~/phoenix-host.key`

**Ansible infrastructure created:**
- ✅ `ansible/ansible.cfg`, `ansible/site.yml`
- ✅ `ansible/inventory/hosts.yml` — Server inventory
- ✅ `ansible/group_vars/all.yml` — Global variables
- ✅ `ansible/roles/common/` — OS hardening, simple nftables, Docker CE, fail2ban
- ✅ `ansible/roles/netbird_management/` — NetBird Management + Signal + Relay (SQLite + Litestream, DNS-01 ACME)
- ✅ `ansible/roles/netbird_peer/` — NetBird peer client for mesh connectivity
- ✅ `ansible/roles/powerdns_master/` — PowerDNS Primary + PostgreSQL + PowerDNS-Admin (Docker internal networks)
- ✅ `ansible/roles/powerdns_slave/` — PowerDNS Secondary + SQLite (NetBird mesh replication)

**All Phase 1 DNS roles complete.** Ready for user confirmation and deployment.

---

## 3. Immediate Next Task — START HERE

**Infrastructure Architecture Confirmed — Ready to Deploy**

The infrastructure architecture has been confirmed by the user and documented in `docs/04-deployment/FRESH_INFRASTRUCTURE_PLAN.md`.

**Architecture Summary:**

**Servers:**
- **ns1** (`23.88.111.142`): PowerDNS Primary + NetBird Management/Signal/Relay (primary, Docker Compose)
- **ns2** (`89.167.125.29`): PowerDNS Secondary + NetBird Management/Signal/Relay (standby, Docker Compose)
- **admin1** (`46.224.122.58`): k3s cluster + Management API + Admin/Client Panels + Phase 1 workloads

**Key Decisions (Confirmed 2026-03-11):**
- ✅ **DNS Server:** PowerDNS 4.9 (not BIND) — REST API, database-backed, aligned with ADR-016
- ✅ **OS:** Debian 13 (trixie) — Official Debian stable
- ✅ **Deployment:** Ansible roles (rebuilt from scratch, aligned with Phase 1 roadmap)
- ✅ **Firewall:** Simple nftables rules only — **NO advanced pre/post-routing** (lesson from previous deployment: complex NAT rules broke ns1 access after NetBird changes)
- ✅ **VPN:** Fresh NetBird mesh (new management server on ns1)
- ✅ **SSH:** Break-glass access (SSH stays open on all servers for emergency access)
- ✅ **Backup:** Restic → Hetzner Storagebox `u335448-sub9@u335448.your-storagebox.de`
- ✅ **Ansible:** `ansible_user=root`, `ansible_ssh_private_key_file=~/phoenix-host.key`

**Ansible Infrastructure Created:**
- ✅ `ansible/site.yml` — Main playbook
- ✅ `ansible/inventory/hosts.yml` — Server inventory with IPs and groups (ns1 + ns2 both in `netbird_management`)
- ✅ `ansible/group_vars/all.yml` — Global variables (NetBird redundancy, DNS round-robin config)
- ✅ `ansible/roles/common/` — OS hardening, simple nftables firewall, Docker CE, fail2ban
- ✅ `ansible/roles/netbird_management/` — NetBird Management + Signal + Relay (SQLite + Litestream, automatic failover/failback)
- ✅ `ansible/roles/netbird_peer/` — NetBird peer client for mesh connectivity

**Next Deployment Steps:**
1. Deploy `common` role to all servers (OS hardening + Docker + simple firewall)
2. Create and deploy `powerdns_master` role (ns1 + PostgreSQL) **— MUST BE FIRST**
3. Create and deploy `powerdns_slave` role (ns2 + SQLite)
4. Verify DNS replication (< 5 seconds propagation)
5. Configure DNS records for NetBird (dual A records for `netbird.phoenix-host.net`)
6. Deploy `netbird_management` role (ns1 + ns2, redundant deployment with SQLite + Litestream, DNS-01 ACME challenge)
7. Deploy `netbird_peer` role (admin1, workstation)
8. Verify NetBird mesh connectivity
9. Create and deploy `backup` role (Restic to Storagebox, includes NetBird SQLite database via Litestream)
10. Create and deploy `k3s` role (admin1 single-node cluster)

**CRITICAL:** PowerDNS must be deployed before NetBird because NetBird's Traefik uses DNS-01 ACME challenge for SSL certificates (required for round-robin DNS compatibility). Traefik needs PowerDNS API access to create/delete ACME challenge TXT records.

**See:** `ansible/README.md` for deployment instructions.

---

## 4. Agent Behavioral Instructions

### 4.1 Git — Commit All Changes Automatically

**Commit every meaningful unit of work immediately after completion.** Do not batch multiple features into one commit. Follow the project's commit message convention:

```
type(scope): short imperative summary

Optional body explaining why, not what.
Closes #<issue> (if applicable)
```

Types: `feat`, `fix`, `infra`, `refactor`, `test`, `docs`, `chore`
Scopes: `backend`, `frontend`, `ansible`, `k8s`, `backup`, `dns`, `auth`

Examples:
```
feat(frontend): scaffold admin panel with Vite + React + shadcn/ui
feat(backend): add GET /api/v1/admin/clients with cursor pagination
fix(ansible): restart Docker after nftables change in common role
infra(reset): remove all infrastructure config and start fresh deployment
```

**Rules:**
- Always run from `/config/hosting-platform/` (the repo root)
- Never commit secrets, tokens, or credentials in any form
- Never force-push to `main` without explicit user approval
- Never skip pre-commit hooks (`--no-verify`)

### 4.2 Documentation Alignment — Ask on Conflicts

Before implementing any feature or making any architectural decision:

1. **Check the relevant spec** — see the Documentation Index in §7 below
2. **If the spec covers it** — implement exactly as documented
3. **If the spec is silent** — choose the most efficient, secure, low-cost option and document your decision
4. **If your implementation idea conflicts with the spec** — STOP. State the conflict explicitly and ask the user to resolve it before writing code

### 4.3 Efficiency & Security Standards

**Code efficiency:**
- Prefer native platform features over additional dependencies
- Cache aggressively (TanStack Query on frontend, Redis on backend when spec requires it)
- Use cursor-based pagination for all list endpoints (see `docs/API_PAGINATION_STRATEGY.md`)
- All API responses follow the standard error format in `docs/API_ERROR_HANDLING.md`)
- Target: all API endpoints < 200ms p50

**Security non-negotiables:**
- All inter-service traffic uses VPN mesh or TLS — never plaintext
- No secrets in code, templates, or git — use env vars
- JWT validation on every API request — see `docs/03-security/SECURITY_ARCHITECTURE.md`
- Kubernetes: namespace-per-client isolation, NetworkPolicy enforced, ResourceQuota per plan
- Scan all Docker images with Trivy before pushing to Harbor (when Harbor is deployed)
- RBAC: admin panel routes must verify the `admin` role claim; client panel routes must be scoped to `client_id`

### 4.4 Low-Cost Optimization

Every implementation decision must consider cost. The infrastructure budget is **< $200/month**.

**Default to low-cost choices:**
- Prefer single-node or small footprint over HA until scale requires it
- Use scale-to-zero (KEDA) for non-Premium client workloads
- Shared pod model for Starter plan clients (20–50 clients per pod) — see `docs/01-core/HOSTING_PLANS.md`
- Prefer lightweight tools: k3s over full k8s, Loki over Elasticsearch
- Restic incremental backups to Storagebox — no full-backup duplication

**Before adding any new service or dependency, ask:**
1. Does this add recurring cost (cloud service, SaaS)?
2. Can an already-deployed component handle this?
3. Is this in scope for Phase 1, or is it Phase 2+?

### 4.5 Tradeoffs — Always Ask the User

When a decision involves a meaningful tradeoff, do not decide unilaterally. Present the options clearly and ask:

**Tradeoff template:**
```
TRADEOFF: [short description]

Option A: [name]
  - Pro: ...
  - Con: ...
  - Cost impact: ...

Option B: [name]
  - Pro: ...
  - Con: ...
  - Cost impact: ...

Recommendation: Option [X] because [brief reason]. Confirm?
```

### 4.6 Keep AGENTS.md Current — Update After Every Session

**AGENTS.md is a living document.** At the end of every session — or immediately after completing any significant unit of work — update it to reflect the new state of the project.

**What to update:**
- §2 "Current State" — server status, last commits, infrastructure health
- §3 "Immediate Next Task" — what comes next
- §8 "Critical Gotchas" — any new issues discovered
- §9 "Do NOT" — any new anti-patterns or deferred features

**Commit the AGENTS.md update as part of the same commit as the work, or as an immediate follow-up.**

---

## 5. Repository Structure (Current)

```
hosting-platform/
├── AGENTS.md                  ← YOU ARE HERE
├── README.md                  ← Public-facing overview
├── backend/                   ← Management API source code
│   ├── src/
│   │   ├── routes/            ← API route handlers
│   │   ├── services/          ← Business logic (PowerDNS client, etc.)
│   │   ├── db/                ← Knex connection + migrations
│   │   ├── middleware/        ← Auth, error handling
│   │   ├── lib/               ← Utilities (ID generation, errors, pagination)
│   │   ├── app.ts             ← Fastify app setup
│   │   ├── server.ts          ← Server entry point
│   │   └── config.ts          ← Environment config
│   ├── package.json
│   ├── tsconfig.json
│   ├── .env.example
│   ├── .gitignore
│   └── README.md
├── frontend/
│   ├── admin-panel/           ← Admin UI (placeholder only)
│   │   └── README.md
│   └── client-panel/          ← Client UI (placeholder only)
│       ├── README.md
│       └── src/
├── docs/                      ← ALL project documentation
│   ├── QUICKSTART.md          ← Documentation index
│   ├── 01-core/               ← Architecture, plans, deployment models
│   ├── 02-operations/         ← Infrastructure, monitoring, admin/client panels
│   ├── 03-security/           ← Security architecture, compliance
│   ├── 04-deployment/         ← Phase 1 roadmap, deployment guides
│   ├── 05-advanced/           ← Disaster recovery, HA
│   ├── 06-features/           ← Backup restore, app catalog
│   ├── 07-reference/          ← Tech stack, migration, FAQ
│   └── 08-admin-panel-mockups/ ← UI mockups
├── .git/
├── .github/
├── .gitignore
└── opencode.json
```

**Note:** No infrastructure code exists yet. Ansible, k8s, helm, terraform, ops, and scripts directories have been removed.

---

## 6. Backend API — Current State

**Source code preserved in `backend/src/`:**

- **Stack:** Node.js 22 + Fastify 4 + TypeScript + Knex
- **Routes:**
  - `POST /api/v1/auth/token` — JWT authentication
  - `GET /api/v1/admin/status` — Health check (database + PowerDNS)
  - `GET /api/v1/admin/clients` — List clients with cursor pagination
  - `POST /api/v1/admin/clients` — Create client
  - `PATCH /api/v1/admin/clients/:id` — Update client
  - `DELETE /api/v1/admin/clients/:id` — Delete client
  - Domain management routes (similar CRUD)
- **Database migrations:** 4 Knex migrations in `backend/src/db/migrations/`
  - 001: clients table
  - 002: domains table
  - 003: databases table
  - 004: audit_logs table
- **PowerDNS client:** `undici`-based HTTP client in `backend/src/services/powerdns/`
- **Middleware:** JWT auth, error handling
- **Utilities:** ID generation, pagination helpers, error classes

**Not deployed yet.** Requires:
- MariaDB database
- Environment variables configured
- PowerDNS servers accessible

---

## 7. Documentation Index

> All documentation lives in `docs/`. Read the relevant spec BEFORE implementing anything in that area.

### Start here
| Doc | Purpose |
|-----|---------|
| `docs/QUICKSTART.md` | Full documentation index by role and topic |
| `docs/04-deployment/PHASE_1_ROADMAP.md` | Week-by-week implementation plan |
| `docs/ARCHITECTURE_DECISION_RECORDS.md` | All architectural decisions and their rationale |

### Architecture & Design
| Doc | Purpose |
|-----|---------|
| `docs/01-core/PLATFORM_ARCHITECTURE.md` | Core platform design, namespace model, workload architecture |
| `docs/01-core/HOSTING_PLANS.md` | Starter/Business/Premium plan definitions |
| `docs/01-core/DISPERSED_DNS_ARCHITECTURE.md` | PowerDNS primary/secondary architecture |

### Operations & Infrastructure
| Doc | Purpose |
|-----|---------|
| `docs/02-operations/INFRASTRUCTURE_SIZING.md` | Cluster sizing, node specs, cost breakdown |
| `docs/02-operations/BACKUP_STRATEGY.md` | Three-tier backup strategy |
| `docs/02-operations/MONITORING_OBSERVABILITY.md` | Prometheus, Grafana, Loki, alerting |
| `docs/INFRASTRUCTURE_PLAN.md` | Full infra narrative (comprehensive) |

### Admin & Client Panels
| Doc | Purpose |
|-----|---------|
| `docs/02-operations/ADMIN_PANEL_REQUIREMENTS.md` | Complete admin panel feature spec (100+ features) |
| `docs/02-operations/CLIENT_PANEL_FEATURES.md` | Client self-service panel spec |
| `docs/08-admin-panel-mockups/` | UI mockups for reference |
| `docs/AUTHORIZATION_MATRIX.md` | Who can do what (admin vs client vs system) |

### API & Backend
| Doc | Purpose |
|-----|---------|
| `docs/DATABASE_SCHEMA.md` | Complete MariaDB schema DDL |
| `docs/API_PAGINATION_STRATEGY.md` | Cursor-based pagination spec |
| `docs/API_ERROR_HANDLING.md` | Standard error response format |
| `docs/CACHING_STRATEGY.md` | Redis caching patterns |
| `docs/TESTING_STRATEGY.md` | Test coverage targets and patterns |

### Security
| Doc | Purpose |
|-----|---------|
| `docs/03-security/SECURITY_ARCHITECTURE.md` | Auth (OIDC/Dex), JWT, RBAC, secrets, network security |
| `docs/03-security/COMPLIANCE_MATRIX.md` | GDPR, PCI-DSS, SOC 2 requirements |
| `docs/SECRETS_MANAGEMENT.md` | How secrets are stored and rotated |

---

## 8. Critical Gotchas (Lessons from Previous Deployment)

These gotchas are from the previous infrastructure deployment. They may be relevant when re-implementing infrastructure:

| # | Issue | Solution |
|---|-------|----------|
| 1 | Docker `0.0.0.0` port binding bypasses firewall INPUT chain | Traffic goes through FORWARD chain; control access via FORWARD rules |
| 2 | `flush ruleset` in nftables wipes Docker's chains | Must restart Docker after nftables changes to restore Docker's rules |
| 3 | Zone type must be `"kind": "Master"` (not `"native"`) for PowerDNS autosecondary | API zone creation must use `"kind": "Master"` |
| 4 | MariaDB: no SSL for local Docker-to-Docker connections | Do not add SSL config to local database connections |
| 5 | Restic `--group-by "host"` causes snapshot conflicts | Must use `--group-by "host,paths"` for multiple backup jobs on same host |
| 6 | Ansible must run from `ansible/` subdirectory | `ansible.cfg` is in that directory; running from repo root fails |
| 7 | **Advanced nftables pre/post-routing rules broke ns1 access** | **DO NOT use complex DNAT, SNAT, or custom NAT chains. Keep firewall rules simple. Let Docker and NetBird manage their own NAT. See `FRESH_INFRASTRUCTURE_PLAN.md` §Firewall for simple baseline.** |

---

## 9. Do NOT

- **Do not start infrastructure work without user confirmation of architecture**
- **Do not commit secrets, tokens, passwords, or IP addresses** — use templates and gitignored files
- **Do not implement Phase 2 features** (geographic sharding, multi-cloud, app catalog) — Phase 1 only
- **Do not add Backrest or third-party backup UI** — backup restore will be built into the custom management UI
- **Do not force-push to `main`** — warn the user and require explicit confirmation
- **Do not bypass git hooks** (`--no-verify`)

---

## 10. Phase 1 Roadmap Summary

| Weeks | Milestone | Status |
|-------|-----------|--------|
| 1–2 | Infrastructure (DNS, VPN, backups, OS hardening) | **PENDING** — needs design confirmation |
| 3–4 | Management API deployment (Fastify, MariaDB, auth) | **CODE READY** — needs infrastructure |
| 5–6 | Admin Panel MVP (React, Vite, shadcn/ui) | **PENDING** |
| 7–8 | Client Panel MVP (file manager, email, databases) | **PENDING** |
| 9–10 | Migration Service (Plesk extractor + importer) | **PENDING** |
| 11–12 | Testing + first Plesk customer migration | **PENDING** |

Full roadmap: `docs/04-deployment/PHASE_1_ROADMAP.md`

---

## 11. Next Session Checklist

Before starting infrastructure work, the user must provide:

1. ✅ Server details (IPs, hostnames, SSH access)
2. ✅ Confirmation of infrastructure architecture
3. ✅ Decision on automation tooling (Ansible, Terraform, etc.)
4. ✅ Secrets and credentials (DNS API keys, database passwords, etc.)
5. ✅ NetBird or VPN mesh configuration (if reusing previous approach)

**Do not proceed until these are confirmed.**
