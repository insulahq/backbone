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

## 2. Current State

**Status:** Full HA stack operational and hardened. repmgrd auto-failover now functional (reconnect_attempts=6/reconnect_interval=10/promote_delay=10; stale file cleanup on startup). Both NS1 and NS2 netbird-server now use Docker `postgresql` hostname to avoid boot-time circular dependency. repmgr binary path fixed in `entrypoint-wrapper.sh.j2`. Ready for Management API + Admin Panel deployment.

**PostgreSQL primary/standby swapped (2026-03-13):**
NS1 went down; repmgrd detected failure and attempted auto-promote but the promote_command failed because `/usr/bin/repmgr` does not exist in the container (actual binary is `/usr/lib/postgresql/18/bin/repmgr`) — exit code 127 (gotcha 41). Manual promotion of NS2 succeeded. NS1 rejoined as standby under NS2. Current roles: **NS2=primary (node 2), NS1=standby (node 1)**. `postgresql_primary_node` updated to `ns2` in Ansible defaults. Extra_hosts template made role-agnostic (either node can be primary after failover).

**Boot-time circular dependency fixed on both nodes (2026-03-13):**
NS2 had the same boot-time circular deadlock as NS1 (gotcha 24): netbird-server used WireGuard IPs in its DSN, but WireGuard needs netbird-server running. Fixed by extending the `postgresql_default` Docker network join and `postgresql` hostname DSN to both NS1 and NS2 (removed `{% if inventory_hostname == 'ns1' %}` guard). NS2 DSN is now `host=postgresql,100.75.10.178` (Docker hostname first, NS1 WireGuard as fallback). Temporary iptables DNAT rules on NS2 (`100.75.120.47:5432 → 172.19.0.2:5432`) removed after Ansible redeploy.

**idp.db sync automated (2026-03-13):**
NS2's Dex credential store (`idp.db`) was empty — dashboard login failed with "Invalid Email Address or password". Fixed by copying NS1's `idp.db` to NS2. Ansible `netbird_management` role now syncs `idp.db` NS1→NS2 on every deploy so this never recurs.

**Post-reboot incident (2026-03-12) — resolved:**
NS1 reboot exposed several circular boot dependencies that have now been fixed in the Ansible templates and are documented in §8 (gotchas 22–29). NS1 manual recovery steps: force-recreate pdns, patch netbird DSN to use `postgresql` hostname, force-recreate nginx, restart NS2 Traefik for cert renewal.

**NS2 zone replication fix (2026-03-13):**
NS2 only had one A record for `netbird.phoenix-host.net` because `pdnsutil add-record` does not auto-increment the SOA serial — the second record was added without bumping serial, so NS2 never re-transferred. Fixed by: bumping serial, forcing `pdns_control retrieve` on NS2, and running `pdnsutil change-secondary-zone-primary phoenix-host.net 23.88.111.142 100.75.10.178` to accept NOTIFYs from both NS1 public and NetBird IPs. Ansible template updated with this fix (gotcha 30).

**Server IPs (confirmed):**
- ns1.phoenix-host.net: `23.88.111.142` (Hetzner Falkenstein) — NetBird IP: `100.75.10.178`
- ns2.phoenix-host.net: `89.167.125.29` (Hetzner Helsinki) — NetBird IP: `100.75.120.47`
- admin1.phoenix-host.net: `46.224.122.58` (Hetzner) — NetBird IP: `100.75.46.183`

**IMPORTANT: NetBird IPs changed on re-enrollment (fresh PostgreSQL DB assigns new IPs)**
The previous IPs (`100.83.x.x`) are no longer valid. All configs now use `100.75.x.x`.

**Deployed infrastructure:**
| Component | Status | Server(s) |
|-----------|--------|-----------|
| OS hardening (Debian 13, nftables, fail2ban, Docker) | ✅ DONE | all |
| PowerDNS 4.9.13 Primary + PostgreSQL | ✅ DONE | ns1 |
| PowerDNS 4.9.13 Secondary + SQLite | ✅ DONE | ns2 |
| Standalone Traefik v3.6 (traefik_public network, DNS-01 ACME) | ✅ DONE | ns1, ns2 |
| PostgreSQL 18 + repmgr 5.5 (primary) | ✅ DONE | ns1 |
| PostgreSQL 18 + repmgr 5.5 (standby — REPLICATING) | ✅ DONE | ns2 |
| NetBird v0.66.4 Management (PostgreSQL multi-host DSN, all peers enrolled) | ✅ DONE | ns1, ns2 |
| NetBird peer mesh (all 3 peers connected, round-robin DNS) | ✅ DONE | ns1, ns2, admin1 |
| PowerDNS nginx API (bound to 100.75.10.178:8081) | ✅ DONE | ns1 |
| PowerDNS nginx API (bound to 100.75.120.47:8081) | ✅ DONE | ns2 |
| Restic backup to Hetzner Storagebox | ✅ DONE | all |
| k3s v1.34.5+k3s1 single-node cluster | ✅ DONE | admin1 |
| Management API (Fastify + MariaDB) | ❌ TODO | admin1 (k3s) |
| Admin Panel (React/Vite/shadcn) | ❌ TODO | admin1 (k3s) |
| Client Panel | ❌ TODO | admin1 (k3s) |

**Ansible roles:**
- ✅ `ansible/roles/common/` — OS hardening, simple nftables, Docker CE, fail2ban
- ✅ `ansible/roles/powerdns_master/` — PowerDNS Primary + PostgreSQL
- ✅ `ansible/roles/powerdns_slave/` — PowerDNS Secondary + SQLite
- ✅ `ansible/roles/traefik/` — Standalone Traefik v3.6, shared traefik_public Docker network
- ✅ `ansible/roles/postgresql_repmgr/` — PostgreSQL 18 + repmgr HA, sourcemation image
- ✅ `ansible/roles/netbird_management/` — NetBird v0.66.4 combined server (PostgreSQL backend)
- ✅ `ansible/roles/netbird_peer/` — NetBird peer client
- ✅ `ansible/roles/backup/` — Restic backup to Hetzner Storagebox
- ✅ `ansible/roles/k3s/` — k3s single-node cluster

**NS2 PowerDNS API enabled (2026-03-13):**
NS2 now has PowerDNS API exposed on `100.75.120.47:8081` via nginx proxy (NetBird only), mirroring NS1. Required for Management API to delete zones on NS2 when clients are removed. Public IP `89.167.125.29:8081` confirmed unreachable.

**Architecture / config (current):**
- NetBird PostgreSQL backend: multi-host DSN `host=100.75.10.178,100.75.120.47 port=5432 ... target_session_attrs=read-write` (NS1-first for NS1; NS2-first for NS2 — see gotcha 38)
- **Current PostgreSQL roles: NS2=primary (node 2), NS1=standby (node 1)** — swapped after NS1 failure on 2026-03-13
- NetBird setup key: reusable, no expiry (`ansible-reusable` key in dashboard), stored in `group_vars/all.yml`
- Traefik: shared `traefik_public` network (172.31.0.0/24), Traefik fixed IP 172.31.0.254
- PowerDNS nginx API: `100.75.10.178:8081` (ns1 NetBird IP), `100.75.120.47:8081` (ns2 NetBird IP)
- netbird.phoenix-host.net DNS: round-robin `23.88.111.142` + `89.167.125.29` (both ns1 and ns2)
- PowerDNS postgres password: stored in `/opt/powerdns/.secrets` on ns1 (gitignored)
- repmgrd failover: active on both nodes, 60 s debounce before promotion (reconnect_attempts=6/reconnect_interval=10/promote_delay=10)

**k3s cluster details (admin1):**
- Version: v1.34.5+k3s1
- Node IP: `46.224.122.58`
- Kubeconfig local: `/etc/rancher/k3s/k3s.yaml`
- Kubeconfig remote: `/etc/rancher/k3s/k3s-remote.yaml`
- Disabled: traefik, servicelb (local-path-provisioner kept for Phase 1)
- Secrets encryption: enabled
- kubectl alias: `k3s kubectl` (via `/etc/profile.d/k3s.sh`)

---

## 3. Immediate Next Task — START HERE

**Infrastructure fully operational. Next: Deploy Management API + Admin Panel on k3s (admin1).**

### Next Steps (in order)

1. **Deploy Management API on admin1 (k3s)** ← START HERE
   - MariaDB deployment on k3s
   - Fastify API deployment (from `backend/`)
   - Configure environment variables, secrets via k3s secrets
   - Verify `POST /api/v1/auth/token` and `GET /api/v1/admin/status`

2. **Deploy Admin Panel on admin1 (k3s)**
   - Build React/Vite/shadcn/ui app (from `frontend/admin-panel/`)
   - See `docs/08-admin-panel-mockups/` for UI reference

### How to run Ansible

```bash
cd /config/hosting-platform/ansible
ansible-playbook -i inventory/hosts.yml deploy-k3s.yml          # k3s only
ansible-playbook -i inventory/hosts.yml deploy-backup.yml        # backup only
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml       # NetBird management (ns1+ns2)
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml # NetBird peers (re-enrollment)
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml       # Traefik only
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml    # PostgreSQL HA only
ansible-playbook -i inventory/hosts.yml deploy-netbird-ha.yml    # Traefik + PG + NetBird (full HA stack)
ansible-playbook -i inventory/hosts.yml site.yml                 # Everything
```

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
| 8 | k3s fails with `protect-kernel-defaults: true` if kernel sysctl not set | k3s role sets `vm.overcommit_memory=1`, `kernel.panic=10`, `kernel.panic_on_oops=1` via `/etc/sysctl.d/99-k3s.conf` before starting k3s |
| 9 | NetBird SSH config intercepts ALL SSH connections (not just NetBird peers) | Restic backup script uses `-F /dev/null` in SFTP args to bypass `/etc/ssh/ssh_config.d/99-netbird.conf` |
| 10 | Restic repos on Storagebox corrupted by runs with wrong password | Must wipe ALL files (including data/ subdirs) before re-init. Use `wipe-restic-repos.py` pattern with SFTP batch -rm/-rmdir commands |
| 11 | `bitnami/postgresql-repmgr` image removed from all public registries | Use `sourcemation/postgres-repmgr:latest` instead (PG18 + repmgr 5.5, different env var API) |
| 12 | sourcemation/postgres-repmgr entrypoint crashes on container restart ("already registered") | Mount custom `entrypoint-wrapper.sh` using `--force` flag on repmgr register commands |
| 13 | Docker hairpin NAT: container can't reach its own Docker-forwarded port via host IP | Use `extra_hosts` to map node's own hostname to `127.0.0.1`, peer hostname to real NetBird IP |
| 14 | PostgreSQL pg_hba.conf doesn't allow Docker bridge networks by default | Add `host all all 172.0.0.0/8 scram-sha-256` and `host all all 100.75.0.0/16 scram-sha-256` to pg_hba.conf |
| 15 | NetBird multi-host PostgreSQL DSN fails if any listed host is unreachable | Use single-host DSN until all PG nodes are up and replicating; then switch to multi-host |
| 16 | NetBird management DB is EMPTY after switching to PostgreSQL — old SQLite data not migrated | All peers need re-enrollment with new setup key after switching to PostgreSQL backend |
| 17 | **NetBird IPs change on every re-enrollment (fresh PostgreSQL DB assigns new IPs)** | **After re-enrollment, check actual IPs via `netbird status --json`. Update inventory `netbird_ip`, `group_vars/all.yml` (netbird_pdns_primary_ip, powerdns_api_url, netbird_postgres_dsn), and redeploy all components that reference NetBird IPs.** |
| 18 | NetBird setup key type matters — one-off keys expire after single use | Always create `type: reusable` key with `usage_limit: 0` for Ansible automation |
| 19 | postgresql_repmgr role must detect primary/standby by `inventory_hostname`, not by NetBird IP | Using IP-based detection breaks when IPs change on re-enrollment. Use `inventory_hostname == 'ns1'` |
| 20 | PostgreSQL `postmaster.pid` left behind after unclean container restart causes startup loop | Remove stale PID: `docker run --rm -v postgresql_postgresql_data:/data alpine rm -f /data/postmaster.pid` |
| 21 | PowerDNS postgres `POSTGRES_PASSWORD` env only takes effect on first volume init | If volume exists with old password, must `ALTER USER pdns WITH PASSWORD '...'` inside container to re-sync |
| 22 | Docker port binding silently skipped when container restarts in partial network state | Container only on `internal: true` network loses port forwarding. Fix: `docker compose up -d --force-recreate <service>` to fully reconnect all networks |
| 23 | **powerdns-auth port 53 DNAT rules missing after reboot** — crash-restart loop during startup (PG not ready) leaves container only on `powerdns_internal` network | Fix: `cd /opt/powerdns && docker compose up -d --force-recreate pdns`. The force-recreate connects container to both internal+external networks and restores DNAT rules |
| 24 | **netbird-server circular boot dependency**: needs PostgreSQL via NetBird IPs, but WireGuard needs management server running first — deadlock on either node reboot | Fix: Connect `netbird-server` to `postgresql_default` Docker network on BOTH nodes and use `host=postgresql` as first host in DSN. Template updated — no longer has an `inventory_hostname == 'ns1'` condition (see gotcha 42). |
| 25 | **powerdns-nginx fails to bind `100.75.10.178:8081` on reboot** because NetBird WireGuard interface isn't up yet when Docker starts | Same circular dependency cascade. After fixing gotcha 24, WireGuard comes up, then restart nginx: `docker compose up -d --force-recreate nginx` |
| 26 | **`allow-axfr-ips` uses only NetBird IP** — AXFR from NS2 fails when WireGuard is down (traffic comes from public IP `89.167.125.29`, not NetBird IP) | Fixed in master template: `powerdns_allow_axfr_ips` now includes both NetBird IP AND public IP of NS2 |
| 27 | **NS2 `allow-notify-from` has only public IP** — NOTIFY from NS1's NetBird IP `100.75.10.178` refused | Fixed in slave template: `powerdns_allow_notify_from` now includes both public IP AND NetBird IP of NS1 |
| 28 | **NS2 Traefik loses Let's Encrypt cert on restart** if PowerDNS API unreachable (DNS-01 challenge fails, falls back to self-signed) | After fixing PowerDNS API accessibility, restart NS2 Traefik: `docker restart traefik`. Cert auto-renews via DNS-01 in ~60-90s |
| 29 | `pdns_control ping` is not a valid command in PowerDNS 4.9 — health check always fails, all pdns containers show `(unhealthy)` | Fixed in templates: use `pdns_control uptime > /dev/null 2>&1` instead. Existing live containers will show unhealthy until redeployed via Ansible |
| 30 | **`pdnsutil add-record` does NOT auto-increment the SOA serial** — second record added to zone without bumping serial means NS2 never re-transfers (both show same serial but different records) | Always run `pdnsutil increase-serial <zone>` after any `pdnsutil add-record` or direct DB change, then `pdns_control notify <zone>`. If NS2 still has stale data: `docker exec powerdns-slave pdns_control retrieve phoenix-host.net`. Also: `autosecondary` creates the zone with only the notifying IP as primary — run `pdnsutil change-secondary-zone-primary <zone> <public-ip> <netbird-ip>` on NS2 so NOTIFYs from either IP are accepted. Ansible `powerdns_slave` role now does this automatically. |
| 31 | **NS2 `autosecondary` only registers the FIRST notifying IP as zone primary** — new zones created via API won't auto-replicate if NS1's also-notify only has NS2's NetBird IP | Both NS1 public AND NetBird IP must be in NS2's autoprimaries table. Ansible `powerdns_slave` role now runs `pdnsutil add-autoprimary` for both IPs on every deploy. Live fix: `docker exec powerdns-slave pdnsutil add-autoprimary 100.75.10.178 ns1.phoenix-host.net default` |
| 32 | **Zone deletion on NS1 does NOT propagate to NS2** — DNS protocol has no DELETE notification; NS2 retains stale secondary zones indefinitely | Management API must explicitly delete zones on NS2 when a client zone is removed. NS2 will need its PowerDNS API enabled (bound to NetBird IP) for the Management API to drive zone deletion. Manual cleanup: `docker exec powerdns-slave pdnsutil delete-zone <zone>` |
| 33 | **`soa_edit_api: INCEPTION-INCREMENT` does not auto-set serial when starting from 0** — new zones created via API have serial 0 and the increment never fires | After API zone creation, always call `pdnsutil increase-serial <zone>` then `pdns_control notify <zone>`. Management API must do this in the domain creation flow. Also: `default-soa-content` in pdns.conf now sets the correct primary NS (ns1.phoenix-host.net) instead of `a.misconfigured.dns.server.invalid`. |
| 34 | **PostgreSQL stale `postmaster.pid` AND socket lock file after unclean container stop** — container restart leaves both `/var/lib/postgresql/data/postmaster.pid` (in volume) and `/var/run/postgresql/.s.PGSQL.5432.lock` (in runtime tmpfs). The wrapper loops forever; postgres won't start | Remove both: `docker stop postgresql; docker run --rm -v postgresql_postgresql_data:/data alpine rm -f /data/postmaster.pid; docker exec postgresql rm -f /var/run/postgresql/.s.PGSQL.5432.lock /var/run/postgresql/.s.PGSQL.5432 /tmp/repmgrd.pid` (exec before stop if container is still up), then restart. |
| 35 | **NS2 netbird-server crash-loop after NS1 reboot** — NS2's DSN uses `100.75.10.178` (NS1's NetBird IP) with `target_session_attrs=read-write`; WireGuard to NS1 is down so NS2 falls through to its own read-only standby and fails. Crash-loop poisons DNS round-robin, blocking peer reconnection | Stop NS2 netbird-server immediately. Add temporary `/etc/hosts` override on NS2: `echo '23.88.111.142 netbird.phoenix-host.net' >> /etc/hosts` to force peer daemon to NS1's management server. Once WireGuard tunnel to NS1 is up (`ping 100.75.10.178` succeeds), remove the hosts entry and start NS2's netbird-server. |
| 36 | **Dashboard "Unauthenticated" / client "LoginFailed" after netbird-server restart** — Dex (embedded IdP) re-generates OIDC signing keys on restart; all existing browser sessions and client tokens become invalid | Clear browser cookies/localStorage for `netbird.phoenix-host.net`, log in fresh in incognito. For desktop client: run `netbird login` to trigger a fresh OIDC flow. |
| 37 | **repmgrd auto-failover was non-functional because `conninfo` used `host=${NODE_NAME}` which resolves to `127.0.0.1` via Docker `extra_hosts`** — NS2's repmgrd successfully "connected" to `ns1` but was actually hitting its own localhost, so primary failure was never detected; auto-promotion never triggered | Fixed: `conninfo` keeps `host=${NODE_NAME}` for self-registration (works via extra_hosts→127.0.0.1). The PEER node has `ns1:100.75.10.178` in its own extra_hosts, so from the peer's perspective `ns1` resolves to the real NetBird IP — cross-wire monitoring works. Added `reconnect_attempts=6`, `reconnect_interval=10`, `promote_delay=10` to prevent spurious promotions on transient glitches. Also added stale PID/socket cleanup at container startup (gotcha 34 issue prevented by this). Note: `repmgr cluster show` run from inside the container on NS1 will still time out when connecting to its own conninfo IP — this is a tooling limitation only, not an operational issue. Run it from NS2 instead. |
| 38 | **NS2 `netbird-server` DSN was NS1-first** — when NS1 was down, NS2's driver timed out on NS1 (30 s) before falling back to NS2's local PostgreSQL, which would be primary after repmgr promotion | Fixed: NS2's `NB_STORE_ENGINE_POSTGRES_DSN` now lists `100.75.120.47` (NS2) first, then `100.75.10.178` (NS1). NS1 keeps the original order (NS1/local first). Both are generated from the same `netbird_postgres_dsn` group var via Jinja2 `regex_replace` in `netbird_management/templates/docker-compose.yml.j2`. |
| 39 | **`idp.db` (Dex SQLite credential store) is local to each node's Docker volume — NOT replicated via PostgreSQL** — NS2's `idp.db` starts empty. When NS1 is down and NS2 takes over, dashboard login fails with "Invalid Email Address or password" because NS2's Dex has no users | Manual fix: `scp` NS1's `/tmp/idp.db` (extracted via `docker cp netbird-server:/var/lib/netbird/idp.db`) to NS2, then `docker stop netbird-server && docker cp /tmp/idp.db netbird-server:/var/lib/netbird/idp.db && docker start netbird-server`. The admin user email is `info@phoenix-tech.net`. Long-term fix: add `idp.db` to the restic backup paths and add an Ansible task that syncs it from NS1→NS2 on every netbird deploy. |
| 40 | **repmgrd `promote_command` fails if it cannot get a DB connection at the exact moment of promotion** — repmgrd correctly detects primary failure and attempts to run `repmgr standby promote`, but the subprocess briefly cannot connect to PostgreSQL during the state transition; promotion silently fails and repmgrd does not retry | Manual fallback: `docker exec postgresql repmgr standby promote -f /etc/repmgr/repmgr.conf`. This succeeds immediately when run directly. After promotion, restart netbird-server: `docker restart netbird-server`. |
| 41 | **repmgrd `promote_command` hardcoded `/usr/bin/repmgr` does not exist in container** — `sourcemation/postgres-repmgr` installs repmgr to `/usr/lib/postgresql/18/bin/repmgr`, not `/usr/bin/repmgr`. When NS1 failed and repmgrd on NS2 tried to auto-promote, the promote_command exited with code 127 ("not found") and repmgrd entered degraded state without ever retrying | Fixed in `entrypoint-wrapper.sh.j2`: `promote_command` and `follow_command` now use `$(which repmgr)` which is evaluated at container startup to find the actual binary path. Previously used `/usr/bin/repmgr` which silently fails. Verify live: `docker exec postgresql which repmgr` should return `/usr/lib/postgresql/18/bin/repmgr`. |
| 42 | **NS2 netbird-server boot circular dependency** — same as gotcha 24 for NS1. NS2's DSN used WireGuard IPs (`host=100.75.120.47,100.75.10.178`); on boot WireGuard isn't up yet, so netbird-server can't reach PostgreSQL, and without netbird-server the WireGuard tunnel never comes up | Fixed: `netbird_management/templates/docker-compose.yml.j2` now adds `postgresql_default` network to netbird-server on BOTH nodes (removed `{% if inventory_hostname == 'ns1' %}` guard). NS2 DSN is now `host=postgresql,100.75.10.178` (Docker hostname first via Docker DNS, NS1 WireGuard IP as fallback). The `{% if %}` guard in the bottom `networks:` section was also removed. |

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
| 1–2 | Infrastructure (DNS, VPN, backups, OS hardening) | **DONE** |
| 3–4 | Management API deployment (Fastify, MariaDB, auth) | **NEXT** — infrastructure ready |
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
