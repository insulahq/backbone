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

## 2. Current State (as of last handoff)

**Last commits:**
```
4d18c0c  Back up MariaDB on admin1; fix prune --group-by "host,paths"
1dc35cb  Add weekly Docker image prune timer to common role
37815fc  Pin NetBird versions; switch docker-compose pull to missing
99cd6df  All work through backup + admin1 deployment
```

**Infrastructure: COMPLETE**

| Server | Public IP | NetBird IP | Role | Status |
|--------|-----------|------------|------|--------|
| ns1.phoenix-host.net (Falkenstein) | 23.88.111.142 | 100.76.182.198 | PowerDNS primary + NetBird management | Healthy |
| ns2.phoenix-host.net (Helsinki) | 89.167.125.29 | 100.76.92.172 | PowerDNS secondary | Healthy |
| admin1.phoenix-host.net | 46.224.122.58 | 100.76.98.87 | Management API + MariaDB | Healthy |
| workstation | — | 100.76.226.120 | Control node | — |

**Confirmed healthy:** `GET https://admin.phoenix-host.net/api/v1/admin/status` → `{"database":"ok","pdns_ns1":"ok","pdns_ns2":"ok"}`

**Backups: OPERATIONAL**
- Tool: Restic → Hetzner Storagebox via SFTP (`u335448-sub9@u335448.your-storagebox.de`)
- ns1: 02:00 UTC — PostgreSQL, NetBird SQLite, Traefik certs, configs
- ns2: 02:15 UTC — PowerDNS SQLite, configs
- admin1: 02:30 UTC — MariaDB dump (all databases), configs
- Weekly Docker image prune: Sunday 04:00 UTC ± 30min jitter on all servers

---

## 3. Immediate Next Task — START HERE

**Phase 1, Week 5–6: Admin Panel MVP**

The infrastructure and backend API are complete. The next milestone is building the admin panel frontend. See `docs/04-deployment/PHASE_1_ROADMAP.md` §Week 5-6 for the full GitHub issue list.

**Prerequisite check before starting frontend work:**
> k3s has NOT been provisioned yet. The roadmap puts k3s in Week 1–2 (infrastructure). Confirm with the user whether to provision k3s first, or proceed with frontend development against the existing Management API (which runs on Docker, not k3s). This is a tradeoff — ask the user.

**Admin panel work (once confirmed):**
1. Scaffold `frontend/admin-panel/` — Vite + React 18 + TypeScript + shadcn/ui + Tailwind
2. Auth flow: JWT login → protected routes (Phase 1 uses static admin credentials via env; full OIDC/Dex is Phase 2)
3. Client list page with search + filters
4. Client detail + edit form
5. Create client wizard
6. Domain list + add domain form
7. Dashboard overview (client count, alerts, storage usage)
8. TanStack Query for API data fetching + Zustand for auth state

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
```

**Rules:**
- Always run from `/config/hosting-platform/` (the repo root)
- Always `git add` only relevant files — never commit `group_vars/all.yml`, `inventory/hosts.yml`, or any `.env` files (they are gitignored for a reason)
- Never force-push to `main` without explicit user approval
- Never skip pre-commit hooks (`--no-verify`)
- Never commit secrets, tokens, or credentials in any form

### 4.2 Documentation Alignment — Ask on Conflicts

Before implementing any feature or making any architectural decision:

1. **Check the relevant spec** — see the Documentation Index in §9 below
2. **If the spec covers it** — implement exactly as documented
3. **If the spec is silent** — choose the most efficient, secure, low-cost option and document your decision
4. **If your implementation idea conflicts with the spec** — STOP. State the conflict explicitly and ask the user to resolve it before writing code

Common conflict situations to watch for:
- Authentication method (Phase 1 uses static JWT, not Dex OIDC — do not introduce Dex prematurely)
- Billing model (admin-only, no customer self-service plan changes)
- Restore UI (do NOT build backup restore UI in Phase 1 — it is explicitly deferred; see `docs/06-features/RESTORE_SPECIFICATION.md`)
- Third-party UI tools for backup/ops (not wanted — the custom management UI handles this)

### 4.3 Efficiency & Security Standards

**Code efficiency:**
- Prefer native platform features over additional dependencies
- Cache aggressively (TanStack Query on frontend, Redis on backend when spec requires it)
- Use cursor-based pagination for all list endpoints (see `docs/API_PAGINATION_STRATEGY.md`)
- All API responses follow the standard error format in `docs/API_ERROR_HANDLING.md`
- Target: all API endpoints < 200ms p50

**Security non-negotiables:**
- All inter-service traffic uses NetBird WireGuard mesh or TLS — never plaintext
- No secrets in code, templates, or git — use env vars; template sensitive files from `group_vars/all.yml` (gitignored)
- MariaDB connections: no SSL for local Docker-to-Docker (loopback); TLS required for any cross-host connection
- JWT validation on every API request — see `docs/03-security/SECURITY_ARCHITECTURE.md`
- Kubernetes: namespace-per-client isolation, NetworkPolicy enforced, ResourceQuota per plan
- Scan all Docker images with Trivy before pushing to Harbor
- RBAC: admin panel routes must verify the `admin` role claim; client panel routes must be scoped to `client_id`

**Infrastructure security:**
- nftables is the firewall — understand the chain ordering before adding rules (see Gotchas §10)
- Docker `0.0.0.0` port bindings bypass the INPUT chain — control access via nftables FORWARD chain
- Secrets for Ansible live only in `ansible/group_vars/all.yml` (gitignored)

### 4.4 Low-Cost Optimization

Every implementation decision must consider cost. The infrastructure budget is **< $200/month**.

**Default to low-cost choices:**
- Prefer single-node or small footprint over HA until scale requires it
- Use scale-to-zero (KEDA) for non-Premium client workloads
- Shared pod model for Starter plan clients (20–50 clients per pod) — see `docs/01-core/HOSTING_PLANS.md`
- Prefer lightweight tools: k3s over full k8s, Loki over Elasticsearch, FileBrowser over complex file managers
- Docker layer caching on nodes reduces image pull costs
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

**Known pending tradeoffs (ask user at session start or when reached):**
- k3s provisioning before or after frontend work?
- Phase 1 auth: keep static JWT credentials or implement Dex OIDC now? (Dex adds complexity but aligns with the spec)
- Admin panel deployment: serve from admin1 (current) or deploy to k3s cluster once provisioned?
- Monitoring: Prometheus + Grafana + Loki all in Week 1–2 scope, or defer Loki to reduce initial complexity?

### 4.6 Keep AGENTS.md Current — Update After Every Session

**AGENTS.md is a living document.** At the end of every session — or immediately after completing any significant unit of work — update it to reflect the new state of the project. A future agent must be able to resume from this file alone without asking the user to recap.

**What to update and when:**

| Trigger | What to update |
|---------|----------------|
| After any `git commit` | §2 "Last commits" block — paste the new commit hash + message |
| After infra changes (Ansible runs, new servers, config changes) | §2 server table, status column, any relevant gotcha in §10 |
| After backend changes (new routes, migrations, schema changes) | §7 Backend API state |
| After a milestone is completed | §13 Roadmap table — mark the row as COMPLETE |
| After a tradeoff is resolved with the user | §4.5 Known pending tradeoffs — remove the resolved item, add any new ones |
| After discovering a new gotcha | §10 Critical Gotchas — append it immediately, before it is forgotten |
| After any new Phase 2+ feature decision | §11 Do NOT — add it if it must be deferred |

**How to update §2 (Current State):**

```bash
# Get the last 4 commits to paste into §2
git -C /config/hosting-platform log --oneline -4
```

Paste the output into the "Last commits" block in §2, replacing the previous entries. Then update the infrastructure table and any status lines that changed.

**Commit the AGENTS.md update as part of the same commit as the work, or as an immediate follow-up:**

```bash
git add AGENTS.md
git commit -m "docs(agents): update current state after <brief description of work done>"
```

Never leave a session with AGENTS.md describing stale state. A future agent that reads outdated "Current State" will waste time re-verifying or re-doing completed work.

---

## 5. Environment Setup (Prerequisites)

### Must be done before any server work

1. **NetBird connected** — your workstation must be on the NetBird mesh. Without this, Ansible cannot reach servers via their private IPs and DNS API calls from admin1 will fail.
   ```bash
   netbird status  # must show "Connected" and see all 3 peers
   ```

2. **SSH key available:**
   ```bash
   ls ~/phoenix-host.key  # must exist
   ssh-add ~/phoenix-host.key
   ```

3. **Ansible — ALWAYS run from `ansible/` subdirectory:**
   ```bash
   cd /config/hosting-platform/ansible
   ansible-playbook -i inventory/hosts.yml site.yml
   # NEVER run from /config/hosting-platform/ — ansible.cfg is not picked up
   ```

4. **Gitignored files must exist** (see §8 for full list and how to populate them):
   - `ansible/group_vars/all.yml` — copy from `all.example.yml`, fill in secrets
   - `ansible/inventory/hosts.yml` — copy from `hosts.example.yml`, fill in IPs

### Key tooling versions (pinned)
- NetBird server + peer: `0.66.3`
- NetBird dashboard: `v2.34.0`
- PowerDNS: `powerdns/pdns-auth-49`
- MariaDB: `mariadb:10.6`
- Node.js: `22`
- Ansible: `2.15+`

---

## 6. Repository Structure

```
hosting-platform/
├── AGENTS.md                  ← YOU ARE HERE
├── README.md                  ← Public-facing overview
├── ansible/                   ← All server config (Ansible)
│   ├── ansible.cfg
│   ├── site.yml               ← Full site playbook
│   ├── management_api.yml     ← Targeted: common → netbird_peer → management_api
│   ├── inventory/
│   │   ├── hosts.yml          ← GITIGNORED (copy from hosts.example.yml)
│   │   └── hosts.example.yml
│   ├── group_vars/
│   │   ├── all.yml            ← GITIGNORED (copy from all.example.yml)
│   │   └── all.example.yml
│   ├── host_vars/
│   │   ├── ns1/backup.yml     ← backup_schedule: "02:00:00"
│   │   ├── ns2/backup.yml     ← backup_schedule: "02:15:00"
│   │   └── admin1/backup.yml  ← backup_schedule: "02:30:00"
│   └── roles/
│       ├── common/            ← OS hardening, nftables, Docker, prune timer
│       ├── powerdns_master/   ← pdns-auth-49 + postgres + pdns-admin (ns1)
│       ├── powerdns_slave/    ← host network mode, api=yes (ns2)
│       ├── netbird_management/ ← netbirdio server + dashboard + Traefik (ns1)
│       ├── netbird_peer/      ← APT-pinned peer enrollment (ns2, admin1)
│       ├── management_api/    ← Docker install + API + MariaDB (admin1)
│       └── backup/            ← Restic → Storagebox SFTP (all servers)
├── backend/                   ← Node.js 22 + Fastify 4 + TypeScript + Knex
│   ├── src/
│   │   ├── routes/            ← API route handlers
│   │   ├── services/          ← Business logic
│   │   ├── db/                ← Knex connection (no SSL for local Docker)
│   │   ├── middleware/        ← Auth, error handling
│   │   └── lib/               ← PowerDNS client (undici-based)
│   └── migrations/            ← Knex migration files (numbered)
├── frontend/
│   ├── admin-panel/           ← React 18 + Vite + shadcn/ui (NEXT TASK)
│   └── client-panel/          ← React 18 + Vite + shadcn/ui (Week 7–8)
├── migration-service/         ← Plesk extractor (Week 9–10)
├── k8s/                       ← Kustomize manifests (base + overlays)
├── helm/                      ← Helm charts for platform services
├── terraform/                 ← Hetzner VPS provisioning (not yet implemented)
├── catalog-images/            ← Dockerfiles for client workload images
├── docs/                      ← ALL project documentation (see §9)
├── ops/                       ← Operational shell scripts (dns/, netbird/)
└── scripts/                   ← One-off utility scripts
```

---

## 7. Backend API — Current State

- **Base URL:** `https://admin.phoenix-host.net/api/v1`
- **Auth:** `POST /api/v1/auth/token` → JWT (static admin credentials via env vars, Phase 1 only)
- **Status:** `GET /api/v1/admin/status` → `{"database":"ok","pdns_ns1":"ok","pdns_ns2":"ok"}`
- **Stack:** Node.js 22 + Fastify 4 + TypeScript + Knex + MariaDB 10.6
- **Migrations:** 4 Knex migrations in `backend/migrations/`
- **Tests:** 8 unit tests passing
- **PowerDNS client:** `undici`-based, zones created as `"kind": "Master"`
- **MariaDB:** Docker container on admin1, no SSL (local Docker-to-Docker)

---

## 8. Gitignored Files — Secrets & Local Config

These files do NOT exist in the repository. You must create them from their `.example` counterparts before running Ansible.

| File | Template | Key values |
|------|----------|------------|
| `ansible/group_vars/all.yml` | `all.example.yml` | `netbird_version`, `netbird_dashboard_version`, `ns1/ns2/admin1_netbird_ip`, `backup_storagebox_host/user`, all passwords |
| `ansible/inventory/hosts.yml` | `hosts.example.yml` | Public IPs for ns1, ns2, admin1; SSH user |

**Key values in `all.yml`:**
- `netbird_version: "0.66.3"`
- `netbird_dashboard_version: "v2.34.0"`
- `ns1_netbird_ip: "100.76.182.198"`
- `ns2_netbird_ip: "100.76.92.172"`
- `admin1_netbird_ip: "100.76.98.87"`
- `backup_storagebox_host: "u335448.your-storagebox.de"`
- `backup_storagebox_user: "u335448-sub9"`

---

## 9. Documentation Index

> All documentation lives in `docs/`. Read the relevant spec BEFORE implementing anything in that area.

### Start here
| Doc | Purpose |
|-----|---------|
| `docs/QUICKSTART.md` | Full documentation index by role and topic |
| `docs/04-deployment/PHASE_1_ROADMAP.md` | Week-by-week implementation plan — the source of truth for what to build and in what order |
| `docs/ARCHITECTURE_DECISION_RECORDS.md` | All architectural decisions and their rationale — check before making any structural choices |

### Architecture & Design
| Doc | Purpose |
|-----|---------|
| `docs/01-core/PLATFORM_ARCHITECTURE.md` | Core platform design, namespace model, workload architecture |
| `docs/01-core/HOSTING_PLANS.md` | Starter/Business/Premium plan definitions, shared vs dedicated pod models |
| `docs/01-core/WORKLOAD_DEPLOYMENT.md` | Deployment models and scaling |
| `docs/01-core/DISPERSED_DNS_ARCHITECTURE.md` | PowerDNS primary/secondary architecture |

### Operations & Infrastructure
| Doc | Purpose |
|-----|---------|
| `docs/02-operations/INFRASTRUCTURE_SIZING.md` | Cluster sizing, node specs, cost breakdown |
| `docs/02-operations/BACKUP_STRATEGY.md` | Three-tier backup strategy (implemented for infra; client-level backup is Phase 2) |
| `docs/02-operations/STORAGE_DATABASES.md` | MariaDB, PostgreSQL, Longhorn, Redis architecture |
| `docs/02-operations/MONITORING_OBSERVABILITY.md` | Prometheus, Grafana, Loki, alerting |
| `docs/02-operations/EMAIL_SERVICES.md` | Docker-Mailserver + Roundcube |
| `docs/INFRASTRUCTURE_PLAN.md` | Full infra narrative (comprehensive) |

### Admin & Client Panels
| Doc | Purpose |
|-----|---------|
| `docs/02-operations/ADMIN_PANEL_REQUIREMENTS.md` | Complete admin panel feature spec (100+ features) — read before building any admin UI |
| `docs/02-operations/CLIENT_PANEL_FEATURES.md` | Client self-service panel spec |
| `docs/08-admin-panel-mockups/` | UI mockups for reference |
| `docs/AUTHORIZATION_MATRIX.md` | Who can do what (admin vs client vs system) |

### API & Backend
| Doc | Purpose |
|-----|---------|
| `docs/DATABASE_SCHEMA.md` | Complete MariaDB schema DDL — migrations must match this |
| `docs/API_PAGINATION_STRATEGY.md` | Cursor-based pagination spec — all list endpoints must follow this |
| `docs/API_ERROR_HANDLING.md` | Standard error response format — all endpoints must follow this |
| `docs/CACHING_STRATEGY.md` | Redis caching patterns |
| `docs/TESTING_STRATEGY.md` | Test coverage targets and patterns |

### Security
| Doc | Purpose |
|-----|---------|
| `docs/03-security/SECURITY_ARCHITECTURE.md` | Auth (OIDC/Dex), JWT, RBAC, secrets, network security |
| `docs/03-security/COMPLIANCE_MATRIX.md` | GDPR, PCI-DSS, SOC 2 requirements |
| `docs/SECRETS_MANAGEMENT.md` | How secrets are stored and rotated |

### Features (Phase 2+)
| Doc | Purpose |
|-----|---------|
| `docs/06-features/RESTORE_SPECIFICATION.md` | Granular backup restore UI — DEFERRED, do not build in Phase 1 |
| `docs/06-features/APPLICATION_CATALOG.md` | Moodle, Gibbon, Keycloak, Nextcloud, etc. |
| `docs/05-advanced/DISASTER_RECOVERY.md` | HA, failover, multi-region |

### Reference
| Doc | Purpose |
|-----|---------|
| `docs/07-reference/TECH_STACK_SUMMARY.md` | All technology choices at a glance |
| `docs/07-reference/MIGRATION_PLAN.md` | Plesk/cPanel migration strategy |
| `docs/07-reference/FAQ.md` | Common questions and answers |
| `docs/07-reference/TERMINOLOGY.md` | Glossary |

---

## 10. Critical Gotchas (Hard-Won Knowledge)

These are the most operationally dangerous issues. Re-learning them costs hours.

| # | Issue | Fix |
|---|-------|-----|
| 1 | **Ansible must run from `ansible/` subdirectory** | `cd /config/hosting-platform/ansible` before any `ansible-playbook` command; `ansible.cfg` is in that directory |
| 2 | **`flush ruleset` in nftables wipes Docker's chains** | The `common` role handler restarts Docker after every nftables change to restore Docker's iptables rules |
| 3 | **Docker `0.0.0.0` port binding bypasses INPUT chain** | Traffic to Docker-bound ports goes through the FORWARD chain, not INPUT; control access via FORWARD rules |
| 4 | **`oifname "br-*" drop` breaks NetBird UI** | Must add `tcp dport { 80, 443 } oifname "br-*" accept` BEFORE the drop rule in nftables |
| 5 | **pdns-admin re-exposed if NetBird fix is added naively** | Use `pre_dnat` chain at priority -150 to drop `eth0` traffic to ports 8081/8082 before Docker's DNAT at -100 |
| 6 | **ns2 PowerDNS uses `network_mode: host`** | Required to avoid NetBird postrouting masquerade rewriting wt0 source IPs; requires `NET_BIND_SERVICE` cap and `net.ipv4.ip_unprivileged_port_start=53` |
| 7 | **Zone type must be `"kind": "Master"`** (not `"native"`) | Management API zone creation must use `"kind": "Master"`; autosecondary only accepts master zone NOTIFYs |
| 8 | **pg_dumpall needs `-U pdns`** | `POSTGRES_USER` is `pdns`, not `postgres`; default role does not exist |
| 9 | **Restic `--group-by "host"` immediately deletes MariaDB snapshots** | MariaDB stdin backup and configs backup compete in the same daily bucket; must use `--group-by "host,paths"` |
| 10 | **MariaDB: no SSL for local Docker-to-Docker connections** | Removed `ssl: { rejectUnauthorized: false }` from both `db/index.ts` and `knexfile.ts`; do not add it back |
| 11 | **`daemon.json` must be consistent across roles** | Missing `"userland-proxy": false` in any role that writes `daemon.json` causes idempotency failures; all roles writing daemon.json must include the same base config |
| 12 | **Stale Ansible SSH control socket** | `ansible.cfg` has `-o ControlPath=none` in `ssh_args` to prevent stale socket errors |
| 13 | **`docker image prune -f` only removes dangling images** | Use `docker image prune -af` to also remove old tagged images after version upgrades; the timer uses `-af` |
| 14 | **Ad-hoc playbooks in `/tmp` cannot reference role templates** | Ansible resolves `src:` in templates relative to the playbook file; put any ad-hoc playbooks inside `ansible/` |
| 15 | **`pdnsutil add-autoprimary` must run on ns2 first** | ns2 will not accept NOTIFYs from ns1 until it has ns1 registered as an autoprimary |

---

## 11. Do NOT

- **Do not add Backrest or any third-party backup UI** — backup restore will be built into the custom management UI; see `docs/06-features/RESTORE_SPECIFICATION.md`
- **Do not implement the backup restore UI in Phase 1** — it is explicitly deferred
- **Do not introduce Dex OIDC in Phase 1** unless the user confirms this tradeoff; Phase 1 uses static JWT credentials
- **Do not run `ansible-playbook` from the repo root** — only from `ansible/`
- **Do not commit `ansible/group_vars/all.yml` or `ansible/inventory/hosts.yml`** — gitignored for security
- **Do not commit any `.env` files, tokens, or passwords**
- **Do not add SSL to local Docker-to-Docker MariaDB connections**
- **Do not push to remote without explicit user instruction**
- **Do not force-push to `main`** — warn the user and require explicit confirmation
- **Do not bypass nftables changes without restarting Docker** — Docker's chains get wiped; the handler handles this automatically
- **Do not build Phase 2 features** (geographic sharding, multi-cloud, app catalog, restore UI, Dex OIDC) without confirming with the user that Phase 1 milestones are complete

---

## 12. Verification Commands

Run these to confirm the current state of the infrastructure before making any changes:

```bash
# 1. NetBird mesh — must show all 3 peers connected
netbird status

# 2. Management API health
curl -s https://admin.phoenix-host.net/api/v1/admin/status | jq .

# 3. Ansible dry-run (check mode, no changes)
cd /config/hosting-platform/ansible
ansible-playbook -i inventory/hosts.yml site.yml --check

# 4. Backup status on admin1 (via NetBird IP)
ssh -i ~/phoenix-host.key root@100.76.98.87 \
  "source /etc/restic/env && restic snapshots --group-by host,paths"

# 5. Backend API — get a token and test
TOKEN=$(curl -s -X POST https://admin.phoenix-host.net/api/v1/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<ADMIN_PASSWORD>"}' | jq -r .token)
curl -s -H "Authorization: Bearer $TOKEN" \
  https://admin.phoenix-host.net/api/v1/admin/clients | jq .
```

---

## 13. Phase 1 Roadmap Summary

| Weeks | Milestone | Status |
|-------|-----------|--------|
| 1–2 | Infrastructure (DNS, NetBird, backups, OS hardening) | **COMPLETE** |
| 3–4 | Management API MVP (Fastify, MariaDB, auth, client/domain CRUD) | **COMPLETE** |
| 5–6 | Admin Panel MVP (React, Vite, shadcn/ui, client + domain management) | **NEXT** |
| 7–8 | Client Panel MVP (file manager, email, databases) | Pending |
| 9–10 | Migration Service (Plesk extractor + importer + validator) | Pending |
| 11–12 | Testing + first Plesk customer migration | Pending |

> k3s cluster provisioning is listed in Week 1–2 but has NOT been done yet. Resolve this tradeoff with the user before or during Week 5–6 work.

Full roadmap: `docs/04-deployment/PHASE_1_ROADMAP.md`
