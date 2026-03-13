# Phoenix Host — Project Roadmap

> **Supersedes:** `PHASE_1_ROADMAP.md` (retained as historical reference for the original 12-week plan)
>
> **Definitive phasing reference:** [`docs/PHASING_STRATEGY.md`](../PHASING_STRATEGY.md)
>
> Last Updated: March 13, 2026

---

## Roadmap Overview

| Phase | Name | Status | Summary |
|-------|------|--------|---------|
| **1** | Infrastructure Foundation | **COMPLETE** | Fully redundant DNS + NetBird VPN servers |
| **2** | Platform Development | **NEXT** | Management API, panels, hosting features, worker nodes |
| **3** | Multi-Region & Full HA | Future | Geographic scaling, enterprise HA, compliance |

---

## Phase 1: Infrastructure Foundation (COMPLETE)

**Duration:** ~4 weeks (completed March 13, 2026)
**Team:** 1 engineer

### What Was Delivered

All infrastructure for the two DNS/VPN servers plus the k3s control node:

- OS hardening (Debian 13, nftables, fail2ban, Docker CE) on all 3 servers
- PowerDNS Primary (ns1, PostgreSQL backend) + Secondary (ns2, SQLite, AXFR)
- Traefik v3.6 reverse proxy on ns1 + ns2 (DNS-01 ACME)
- PostgreSQL 18 + repmgr 5.5 HA (streaming replication, auto-failover)
- NetBird v0.66.4 WireGuard mesh (management on ns1+ns2, all 3 peers enrolled)
- PowerDNS API proxy on NetBird IPs (ns1 + ns2)
- Restic incremental backups to Hetzner Storagebox
- k3s v1.34.5+k3s1 single-node cluster on admin1 (ready for Phase 2 workloads)
- 9 Ansible roles + 9 playbooks
- 42 operational gotchas documented and resolved

### Key Outcomes

- Infrastructure is battle-tested (NS1 failure, PostgreSQL failover, boot dependency resolution)
- Full automation via Ansible (any server can be rebuilt from scratch)
- No manual configuration required for recovery

---

## Phase 2: Platform Development (NEXT)

**Estimated Duration:** 10-16 weeks
**Team:** 1-2 engineers
**Budget:** < $200/month (admin1 + worker nodes, ns1/ns2 already running)

### Phase 2 Milestones

#### Milestone 2.1: Management API Deployment (Weeks 1-2)

Deploy the existing backend code (`backend/src/`) onto k3s.

| # | Task | Owner |
|---|------|-------|
| 1 | Deploy MariaDB on k3s (StatefulSet, local-path PV) | DevOps |
| 2 | Build Management API container image | DevOps |
| 3 | Deploy Management API on k3s (Deployment + Service) | DevOps |
| 4 | Configure Kubernetes Secrets (DB creds, JWT secret, PowerDNS API keys) | DevOps |
| 5 | Run database migrations | Backend |
| 6 | Verify `POST /api/v1/auth/token` and `GET /api/v1/admin/status` | Backend |
| 7 | Update PowerDNS API URLs to current NetBird IPs (100.75.x.x) | Backend |

#### Milestone 2.2: Admin Panel MVP (Weeks 3-5)

Build the admin dashboard from `docs/08-admin-panel-mockups/`.

| # | Task | Owner |
|---|------|-------|
| 1 | Scaffold React 18 + Vite + TypeScript + shadcn/ui + Tailwind | Frontend |
| 2 | Implement auth flow (JWT, protected routes) | Frontend |
| 3 | Dashboard overview (client count, status, alerts) | Frontend |
| 4 | Client list with search + filters + pagination | Frontend |
| 5 | Client detail page + edit form | Frontend |
| 6 | Create client wizard | Frontend |
| 7 | Domain management (list, add, delete, DNS mode selection) | Frontend |
| 8 | Subscription management views | Frontend |
| 9 | TanStack Query for API data fetching + caching | Frontend |
| 10 | Build and deploy on k3s | DevOps |

#### Milestone 2.3: Extended API (Weeks 4-6)

Build out the remaining Management API endpoints per `MANAGEMENT_API_SPEC.md`.

| # | Task | Owner |
|---|------|-------|
| 1 | DNS zone template engine (auto-provisioning on domain creation) | Backend |
| 2 | Database management endpoints (create, list, delete client databases) | Backend |
| 3 | Cron job management endpoints | Backend |
| 4 | SFTP/FTP user management endpoints | Backend |
| 5 | Protected directories endpoints | Backend |
| 6 | Hosting settings endpoints | Backend |
| 7 | Backup and restore endpoints | Backend |
| 8 | Subscription management + expiry notification CronJob | Backend |
| 9 | Audit logging middleware (write to audit_logs table) | Backend |
| 10 | Replace static JWT auth with Dex OIDC | Backend |

#### Milestone 2.4: Client Panel MVP (Weeks 6-8)

Build the customer-facing self-service panel per `CLIENT_PANEL_FEATURES.md`.

| # | Task | Owner |
|---|------|-------|
| 1 | Scaffold client panel (same stack as admin panel) | Frontend |
| 2 | Client auth flow (OIDC, scoped to client namespace) | Frontend |
| 3 | Domain list + DNS record viewer | Frontend |
| 4 | File manager (FileBrowser integration or custom) | Frontend |
| 5 | Database list + credentials view | Frontend |
| 6 | Email account management (create/delete mailbox) | Frontend |
| 7 | Backup management (view, trigger, restore) | Frontend |
| 8 | Build and deploy on k3s | DevOps |

#### Milestone 2.5: Hosting Infrastructure (Weeks 5-9, parallel)

Deploy the services needed to actually host customer workloads.

| # | Task | Owner |
|---|------|-------|
| 1 | NGINX Ingress Controller (DaemonSet, hostPort 80/443) | DevOps |
| 2 | cert-manager + Let's Encrypt ClusterIssuer (wildcard + HTTP-01) | DevOps |
| 3 | Sealed Secrets controller | DevOps |
| 4 | Docker-Mailserver + Roundcube deployment | DevOps |
| 5 | Redis deployment (caching + sessions) | DevOps |
| 6 | NetworkPolicy templates (default-deny per namespace) | DevOps |
| 7 | Build catalog container images (Apache PHP, NGINX PHP, WordPress, Node.js, Python) | DevOps |
| 8 | Harbor container registry + Trivy scanning | DevOps |
| 9 | Prometheus + Grafana + Loki + Alertmanager stack | DevOps |
| 10 | Additional k3s worker node(s) for client workloads | DevOps |
| 11 | Namespace provisioning automation (per-client namespace, ResourceQuota, NetworkPolicy) | Backend |
| 12 | Shared pod pool for Starter plan clients | Backend |

#### Milestone 2.6: Migration & Testing (Weeks 9-12)

| # | Task | Owner |
|---|------|-------|
| 1 | Plesk migration service (extractor + importer) | Backend |
| 2 | Migration validator (file checksums, DB row counts, DNS records) | Backend |
| 3 | CI/CD pipeline (GitHub Actions: lint, test, build, deploy) | DevOps |
| 4 | End-to-end API tests (full client lifecycle) | Backend |
| 5 | Load test (50 concurrent clients, all endpoints < 200ms p50) | Backend |
| 6 | Admin panel E2E tests (Playwright) | Frontend |
| 7 | Dry-run migration with non-critical Plesk account | All |
| 8 | First production migration (real Plesk customer) | All |
| 9 | 48-hour stability monitoring period | All |
| 10 | Documentation review and update | All |

#### Milestone 2.7: Billing & Operations (Weeks 10-12, parallel)

| # | Task | Owner |
|---|------|-------|
| 1 | Manual billing workflow (admin sets expiry, sends payment links) | Backend |
| 2 | Stripe webhook handler | Backend |
| 3 | PayPal webhook handler | Backend |
| 4 | Subscription expiry notification CronJob (Slack + email + dashboard) | Backend |
| 5 | WAF (ModSecurity + OWASP CRS v4) -- optional per client | DevOps |
| 6 | fail2ban integration (progressive bans) | DevOps |
| 7 | GitOps with Flux v2 | DevOps |

### Phase 2 Success Criteria

- [ ] Management API fully deployed and operational on k3s
- [ ] Admin Panel with full client + domain + subscription management
- [ ] Client Panel with file manager, email, databases, DNS, backups
- [ ] At least 1 real Plesk customer successfully migrated with zero data loss
- [ ] Monitoring stack operational (Prometheus, Grafana, Loki)
- [ ] CI/CD pipeline running for all components
- [ ] 99.5%+ uptime observed over 48-hour monitoring period
- [ ] All API endpoints < 200ms p50
- [ ] 60%+ test coverage on backend

### Dependency Map

```
Weeks 1-2:   [2.1 Management API]──────────────────────────────────────────────
Weeks 3-5:                        [2.2 Admin Panel]────────────────────────────
Weeks 4-6:                        [2.3 Extended API]───────────────────────────
Weeks 5-9:   [2.5 Hosting Infra]──────────────────────────────────────────────
Weeks 6-8:                                          [2.4 Client Panel]─────────
Weeks 9-12:                                                     [2.6 Migration & Testing]
Weeks 10-12:                                                    [2.7 Billing & Ops]──────
```

---

## Phase 3: Multi-Region & Full HA (Future)

**Trigger:** Phase 2 complete + customer count approaching 100+ or revenue justifies investment
**Estimated Duration:** 3-6 months
**Budget:** $500-1000/month infrastructure + compliance costs

### Phase 3 Milestones

#### 3.1 Multi-Region Expansion

- Deploy additional k3s clusters in new Hetzner regions
- Per-region PowerDNS primaries with cross-region AXFR/NOTIFY
- Floating IPs for NetBird HA (Hetzner Cloud Floating IP or keepalived)
- Cross-region database replication

#### 3.2 Full High Availability

- Multi-node k3s control plane (3+ nodes, etcd quorum)
- Longhorn distributed storage (replace local-path-provisioner)
- MetalLB load balancer (replace NodePort)
- Blue-green and canary deployment strategies
- mTLS between platform services

#### 3.3 Advanced Operations

- Multi-region admin panel (region-aware management)
- Data residency controls (per-customer region selection)
- Distributed tracing (Tempo)
- Chaos engineering (automated failure injection)
- FinOps integration (per-client cost tracking)
- 24/7 on-call rotation
- SLO dashboards with burn-rate alerting

#### 3.4 Enterprise Compliance

- Full GDPR compliance (right-to-deletion automation, breach notification, DPA)
- SOC 2 Type II certification (if enterprise demand)
- PCI-DSS compliance (if payment processing internalized)
- Customer-controlled encryption keys
- Falco runtime security

#### 3.5 Advanced Features

- Self-service application catalog (Nextcloud, Gitea, Mattermost, Jitsi, etc.)
- Advanced backup (cross-region replication, point-in-time recovery)
- Webhook management (customer-facing integrations)
- Custom admin dashboards
- API key management

### Phase 3 Success Criteria

- [ ] 300+ clients across multiple regions
- [ ] 99.9%+ uptime SLA
- [ ] Automated cross-region failover tested
- [ ] Compliance certification obtained (if pursued)
- [ ] Geographic data sovereignty options available

---

## Risk Mitigations

### Phase 2 Risks

| Risk | Mitigation |
|------|------------|
| API delays block panel development | Frontend can build with mock API data (MSW) |
| Database schema changes break migrations | All changes through versioned Knex migrations |
| First migration fails, customer loses data | Test with non-critical account first; comprehensive validator |
| Performance issues discovered late | Load test early (milestone 2.6); p50 budgets on all endpoints |
| Worker node capacity insufficient | Monitor resource usage; add nodes incrementally |

### Phase 3 Risks

| Risk | Mitigation |
|------|------------|
| Multi-region adds complexity without enough customers | Only trigger Phase 3 when scale demands it |
| Compliance costs exceed revenue | Target enterprise customers who justify compliance investment |
| Cross-region latency degrades UX | Region-aware routing; CDN for static assets |

---

## Historical Reference

The original 12-week "Phase 1 Roadmap" (`PHASE_1_ROADMAP.md`) was written before infrastructure deployment was complete. It combined infrastructure setup, API development, panel development, and migration into a single phase. That document is retained for historical reference but is **superseded by this roadmap** and the [`PHASING_STRATEGY.md`](../PHASING_STRATEGY.md) document.

Key differences:
- **Old structure:** Phase 1 = everything (infrastructure through first migration)
- **New structure:** Phase 1 = infrastructure only (DONE), Phase 2 = platform development, Phase 3 = scaling
