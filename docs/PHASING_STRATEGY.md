# Phoenix Host — Project Phasing Strategy

> **This is the definitive reference for project-level phases.**
> All other documents should reference this file when discussing phases.
>
> Last Updated: March 13, 2026

---

## Overview

Phoenix Host is developed in three distinct project phases, each with a clear scope boundary. Phases are sequential but may overlap in planning. A phase is not started until the previous phase is operationally stable.

| Phase | Name | Scope | Status |
|-------|------|-------|--------|
| **Phase 1** | Infrastructure Foundation | Fully redundant DNS + VPN mesh servers | **COMPLETE** |
| **Phase 2** | Platform Development | Hosting platform, management API, panels, worker nodes, core features | **NEXT** |
| **Phase 3** | Multi-Region & Full HA | Geographic scaling, multi-region clusters, enterprise-grade HA | Future |

---

## A Note on Internal Feature Phases

Many individual feature specification documents (e.g., `DNS_ZONE_TEMPLATES.md`, `WEB_SERVER_PHP_VERSION_SWITCHING.md`, `TLS_CERTIFICATE_MANAGEMENT.md`) contain their own internal "Phase 1/2/3/4" labels. **These are implementation steps within that feature, not project-level phases.** For example, `DNS_ZONE_TEMPLATES.md` has:

- Feature Phase 1: Template Engine + Default Template
- Feature Phase 2: Per-Domain DNS Editor
- Feature Phase 3: Template Admin UI
- Feature Phase 4: Autodiscovery Endpoints

All of these feature-internal phases fall within **Project Phase 2** (Platform Development). When reading feature docs, treat their internal phasing as a build order for that specific feature, and refer to this document for the project-level phase a feature belongs to.

---

## Phase 1: Infrastructure Foundation (COMPLETE)

### Objective

Deploy and harden two fully redundant DNS/VPN infrastructure servers that form the backbone of the platform. No hosting workloads, no customer-facing panels, no API deployment.

### Scope

| Component | Description | Server(s) |
|-----------|-------------|-----------|
| OS Hardening | Debian 13, nftables, fail2ban, Docker CE, SSH hardening | ns1, ns2, admin1 |
| PowerDNS Primary | v4.9.13, PostgreSQL backend, API on NetBird IP | ns1 |
| PowerDNS Secondary | v4.9.13, SQLite backend, autosecondary AXFR replication | ns2 |
| Traefik Reverse Proxy | v3.6, DNS-01 ACME, shared Docker network | ns1, ns2 |
| PostgreSQL HA | v18 + repmgr 5.5, streaming replication, auto-failover | ns1 (standby), ns2 (primary) |
| NetBird VPN Mesh | v0.66.4, combined management+signal+relay, PostgreSQL backend, round-robin DNS | ns1, ns2 |
| NetBird Peer Enrollment | All servers enrolled in WireGuard mesh | ns1, ns2, admin1 |
| PowerDNS API Proxy | nginx on NetBird IPs only (not public) | ns1, ns2 |
| Restic Backups | Incremental to Hetzner Storagebox, daily schedule | ns1, ns2, admin1 |
| k3s Cluster | v1.34.5+k3s1, single-node, secrets encryption, ready for Phase 2 workloads | admin1 |

### Ansible Roles (9 total)

All roles are written, tested, and operational:

1. `common/` -- OS hardening, nftables, Docker CE, fail2ban
2. `powerdns_master/` -- PowerDNS Primary + PostgreSQL
3. `powerdns_slave/` -- PowerDNS Secondary + SQLite
4. `traefik/` -- Standalone Traefik v3.6
5. `postgresql_repmgr/` -- PostgreSQL 18 + repmgr HA
6. `netbird_management/` -- NetBird combined server (PostgreSQL backend)
7. `netbird_peer/` -- NetBird peer client enrollment
8. `backup/` -- Restic backup to Hetzner Storagebox
9. `k3s/` -- k3s single-node cluster

### Servers

| Server | Location | Public IP | NetBird IP | Spec |
|--------|----------|-----------|------------|------|
| ns1.phoenix-host.net | Hetzner Falkenstein | 23.88.111.142 | 100.75.10.178 | CX22 |
| ns2.phoenix-host.net | Hetzner Helsinki | 89.167.125.29 | 100.75.120.47 | CX22 |
| admin1.phoenix-host.net | Hetzner | 46.224.122.58 | 100.75.46.183 | CX32 |

### Status: COMPLETE

- All infrastructure deployed and operational
- 42 operational gotchas discovered, resolved, and documented
- PostgreSQL auto-failover tested (NS1 failure, NS2 promoted)
- Boot-time circular dependencies resolved on both nodes
- DNS zone replication verified
- Backup system verified
- k3s cluster running and ready for workloads

### Deliverables Produced

- 9 Ansible roles with full template automation
- 8 targeted playbooks + 1 master playbook
- Comprehensive gotcha documentation (42 entries in AGENTS.md)
- Battle-tested HA infrastructure

---

## Phase 2: Platform Development

### Objective

Build and deploy the complete hosting platform: Management API, Admin Panel, Client Panel, migration tooling, monitoring, and all core features needed to onboard and serve hosting customers. This phase transforms the infrastructure foundation into a revenue-generating hosting business.

### Scope

#### 2.1 Core Platform Services

| Component | Description | Server(s) |
|-----------|-------------|-----------|
| MariaDB | Database for Management API (on k3s) | admin1 |
| Management API | Fastify + TypeScript REST API (from `backend/`) | admin1 (k3s) |
| Admin Panel | React/Vite/shadcn/ui admin dashboard | admin1 (k3s) |
| Client Panel | React/Vite/shadcn/ui customer self-service | admin1 (k3s) |
| Dex OIDC | Replace Phase 1 static auth with proper OIDC | admin1 (k3s) |
| cert-manager | TLS certificate automation (Let's Encrypt) | admin1 (k3s) |
| NGINX Ingress | Kubernetes ingress controller | admin1 (k3s) |

#### 2.2 Client Hosting Features

| Feature | Key Docs |
|---------|----------|
| Client onboarding + namespace provisioning | `MANAGEMENT_API_SPEC.md` |
| Domain management (3 DNS modes: primary, CNAME, secondary) | `DNS_MODE_SELECTION.md` |
| DNS zone template engine | `DNS_ZONE_TEMPLATES.md` |
| Web server + PHP version switching | `WEB_SERVER_PHP_VERSION_SWITCHING.md` |
| Workload container catalog (16 images) | `WORKLOAD_DEPLOYMENT.md` |
| Shared pod model (Starter plan) | `SHARED_POD_IMPLEMENTATION.md` |
| Dedicated pod model (Business/Premium plans) | `HOSTING_PLANS.md` |
| Database management (MariaDB/PostgreSQL per client) | `DATABASE_ACCESS_CONTROL.md` |
| Email services (Docker-Mailserver + Roundcube) | `EMAIL_SERVICES.md` |
| SFTP/FTP access | `FILE_TRANSFER_SERVICE.md` |
| File manager (FileBrowser) | `DEPLOYMENT_PROCESS.md` |
| Cron job management | `CRON_JOB_MANAGEMENT.md` |
| Password-protected directories | `PASSWORD_PROTECTED_DIRECTORIES.md` |
| TLS certificate management (wildcard + custom) | `TLS_CERTIFICATE_MANAGEMENT.md` |
| Backup and restore (3-tier strategy) | `BACKUP_STRATEGY.md`, `RESTORE_SPECIFICATION.md` |

#### 2.3 Admin Features

| Feature | Key Docs |
|---------|----------|
| Admin dashboard with metrics | `ADMIN_PANEL_REQUIREMENTS.md` |
| Client management (CRUD, search, filters) | `ADMIN_PANEL_REQUIREMENTS.md` |
| Subscription management (manual-first billing) | `BILLING_MODEL_CHANGES.md` |
| External billing integration (Stripe, PayPal, DPO) | `EXTERNAL_BILLING_INTEGRATION.md` |
| Subscription expiry notifications | `SUBSCRIPTION_EXPIRY_NOTIFICATIONS.md` |
| Hosting settings management | `HOSTING_SETTINGS.md` |
| Audit logging | `MANAGEMENT_API_SPEC.md` |

#### 2.4 Infrastructure Additions

| Component | Description |
|-----------|-------------|
| Additional worker nodes | k3s agent nodes for client workloads |
| Monitoring stack | Prometheus + Grafana + Loki + Alertmanager |
| Harbor container registry | With Trivy scanning |
| Redis caching | For API response caching and sessions |
| NetworkPolicy enforcement | Default-deny per client namespace |
| WAF (ModSecurity) | Optional per-client, OWASP CRS v4 |
| fail2ban integration | Progressive bans across ingress, SFTP, SSH, mail |
| Sealed Secrets | Kubernetes secrets management |

#### 2.5 Migration & Deployment

| Component | Description |
|-----------|-------------|
| Plesk migration service | Extractor + importer for first customer migration |
| CI/CD pipeline | GitHub Actions (lint, test, build, deploy) |
| GitOps (Flux v2) | Automated k8s reconciliation from git |
| Catalog image pipeline | Build, scan, push workload container images |

#### 2.6 Compliance (Foundation)

| Item | Description |
|------|-------------|
| GDPR foundation | Privacy policy, audit logging, data retention |
| Basic security controls | TLS everywhere, RBAC, namespace isolation, backup encryption |

### Target Outcomes

- First Plesk customer successfully migrated
- All core APIs working (client, domain, database, email, backup management)
- Admin Panel with full platform management
- Client Panel with self-service hosting management
- Basic monitoring and alerting operational
- CI/CD pipeline for automated deployments
- Revenue generation from hosting customers

### Estimated Timeline

Flexible, no hard deadline. Estimated 10-16 weeks depending on team capacity.

### Budget

- Infrastructure: < $200/month (admin1 + worker nodes)
- DNS/VPN servers: existing ns1 + ns2 (already running from Phase 1)

---

## Phase 3: Multi-Region & Full High-Availability

### Objective

Scale the platform for geographic distribution, enterprise-grade high availability, and advanced operational capabilities. This phase targets 300+ clients across multiple regions.

### Scope

#### 3.1 Multi-Region Infrastructure

| Component | Description |
|-----------|-------------|
| Additional Hetzner regions | Expand beyond Falkenstein/Helsinki |
| Per-region k3s clusters | Dedicated clusters per geographic region |
| Multi-region DNS | Per-region PowerDNS primaries with cross-region AXFR |
| Floating IPs | Hetzner Cloud Floating IP or keepalived for NetBird HA |
| Cross-region PostgreSQL | Multi-region database replication |

#### 3.2 Full High Availability

| Component | Description |
|-----------|-------------|
| Multi-node k3s control plane | HA control plane with etcd quorum (3+ nodes) |
| Longhorn distributed storage | Replace local-path-provisioner with replicated storage |
| MetalLB | Replace NodePort with proper load balancer |
| Blue-green / canary deployments | Zero-downtime release strategies |
| mTLS between services | Service mesh or manual mTLS for inter-service traffic |

#### 3.3 Advanced Operations

| Component | Description |
|-----------|-------------|
| Multi-region admin panel | Region-aware management UI |
| Data residency controls | Per-customer region selection for GDPR compliance |
| Chaos engineering | Automated failure injection testing |
| FinOps integration | Cost tracking and optimization per client |
| Advanced monitoring | Distributed tracing (Tempo), SLO dashboards |
| 24/7 on-call rotation | When team size and customer base justify it |

#### 3.4 Enterprise Compliance

| Item | Description |
|------|-------------|
| GDPR full compliance | Right-to-deletion automation, breach notification, DPA |
| SOC 2 Type II | Formal certification (if enterprise demand) |
| PCI-DSS | If payment processing is brought in-house |
| HIPAA | If healthcare customers require it |
| Customer-controlled encryption keys | Per-customer key management |

#### 3.5 Advanced Platform Features

| Component | Description |
|-----------|-------------|
| Application catalog | Self-service app deployment (Nextcloud, Gitea, Mattermost, etc.) |
| Falco runtime security | Container runtime threat detection |
| Advanced backup features | Cross-region replication, point-in-time recovery |
| Webhook management | Customer-facing webhook integrations |
| Custom dashboards | Per-admin customizable dashboard views |

### Target Outcomes

- 300+ clients across multiple regions
- 99.9%+ uptime SLA
- Full compliance readiness for enterprise customers
- Self-healing infrastructure with automated failover
- Geographic data sovereignty options

### Estimated Timeline

Dependent on Phase 2 completion and customer growth. Estimated 3-6 months.

### Budget

- Infrastructure: $500-1000/month (multi-region, multi-node clusters)
- Compliance: $50k-200k+ for SOC 2 certification (if pursued)

---

## Phase Boundary Rules

1. **Phase 1 is locked.** No changes to DNS/NetBird infrastructure unless fixing a bug or security issue.
2. **Phase 2 does not require Phase 3 features.** The platform must be fully functional on a single region with single-node k3s.
3. **Phase 3 is triggered by scale.** Do not pre-build multi-region capabilities until customer count or revenue justifies the complexity and cost.
4. **Feature docs with internal phases map to project phases.** All internal feature implementation steps (e.g., "Feature Phase 1: Core engine" through "Feature Phase 4: Admin UI") are sub-tasks within the project phase where that feature is built. Most feature implementation phases fall within Project Phase 2.
5. **Compliance scales with risk.** Phase 2 gets GDPR foundation. Full compliance certifications are Phase 3, driven by enterprise demand.

---

## Cross-Reference: Feature Documents to Project Phases

This table maps every feature specification document to the project phase where it is implemented.

### Phase 2 Features

| Document | Feature |
|----------|---------|
| `01-core/BILLING_MODEL_CHANGES.md` | Manual-first billing model |
| `01-core/DISPERSED_DNS_ARCHITECTURE.md` | Management API DNS integration (two-node setup is Phase 1) |
| `01-core/DNS_MODE_SELECTION.md` | Three DNS mode types for customer domains |
| `01-core/DNS_ZONE_TEMPLATES.md` | All internal phases (template engine through admin UI) |
| `01-core/EXTERNAL_BILLING_INTEGRATION.md` | Manual + basic gateway (Stripe/PayPal/DPO) |
| `01-core/HOSTING_PLANS.md` | Starter/Business/Premium plan implementation |
| `01-core/PLATFORM_ARCHITECTURE.md` | Core platform deployment (workload containers, catalogs) |
| `01-core/POWERDNS_INTEGRATION.md` | Management API integration + testing |
| `01-core/SHARED_POD_IMPLEMENTATION.md` | Shared pod architecture for Starter plan |
| `01-core/WEB_SERVER_PHP_VERSION_SWITCHING.md` | All internal phases (core logic through admin UI) |
| `01-core/WORKLOAD_DEPLOYMENT.md` | Catalog containers and deployment models |
| `02-operations/ADMIN_PANEL_REQUIREMENTS.md` | Full admin panel (100+ features) |
| `02-operations/CLIENT_PANEL_FEATURES.md` | Client self-service panel |
| `02-operations/BACKUP_STRATEGY.md` | Three-tier backup strategy |
| `02-operations/EMAIL_SERVICES.md` | Docker-Mailserver + Roundcube |
| `02-operations/INFRASTRUCTURE_SIZING.md` | Cluster sizing for client workloads |
| `02-operations/MONITORING_OBSERVABILITY.md` | Prometheus + Grafana + Loki stack |
| `02-operations/STORAGE_DATABASES.md` | Longhorn, MariaDB, PostgreSQL, Redis |
| `03-security/DATABASE_ACCESS_CONTROL.md` | Database RBAC and isolation |
| `03-security/SECURITY_ARCHITECTURE.md` | Core security (OIDC, JWT, NetworkPolicy, Sealed Secrets, fail2ban, WAF) |
| `03-security/TLS_CERTIFICATE_MANAGEMENT.md` | Wildcard + DNS-01 certs, custom cert CSR workflow |
| `04-deployment/CICD_PIPELINE_REQUIREMENTS.md` | Basic CI, manual deploys, staging/production |
| `04-deployment/DEPLOYMENT_PROCESS.md` | Platform service + catalog image + client site pipelines |
| `04-deployment/K3S_DEPLOYMENT_GUIDE.md` | Management API on k3s |
| `04-deployment/MANAGEMENT_API_SPEC.md` | Complete REST API (clients, domains, databases, backups, etc.) |
| `04-deployment/SUBSCRIPTION_EXPIRY_NOTIFICATIONS.md` | Admin notification CronJob |
| `04-deployment/INCIDENT_RESPONSE_RUNBOOK.md` | Business-hours incident response |
| `06-features/*` | All feature specs (restore, WAF, FTP, cron, webmail, etc.) |
| `07-reference/MIGRATION_PLAN.md` | Plesk/cPanel migration strategy |
| `08-admin-panel-mockups/*` | All admin panel UI mockups and design system |

### Phase 3 Features

| Document | Feature |
|----------|---------|
| `01-core/DISPERSED_DNS_ARCHITECTURE.md` | Multi-region DNS (per-region primaries) |
| `01-core/EXTERNAL_BILLING_INTEGRATION.md` | Recurring billing + reconciliation |
| `03-security/COMPLIANCE_MATRIX.md` | Full GDPR, SOC 2, HIPAA, PCI-DSS compliance |
| `03-security/SECURITY_ARCHITECTURE.md` | mTLS between services, Falco runtime security |
| `03-security/TLS_CERTIFICATE_MANAGEMENT.md` | Advanced cert monitoring + Prometheus metrics |
| `04-deployment/CICD_PIPELINE_REQUIREMENTS.md` | Canary/blue-green deploys, GitOps, security scanning, chaos engineering |
| `04-deployment/INCIDENT_RESPONSE_RUNBOOK.md` | 24/7 on-call rotation |
| `05-advanced/DISASTER_RECOVERY.md` | Full HA + cross-region DR |
| `05-advanced/GEOGRAPHIC_SHARDING_SUMMARY.md` | Multi-region deployment |
| `05-advanced/MULTI_CLOUD_STRATEGY.md` | Multi-cloud capabilities |
| `05-advanced/CONFLICT_RESOLUTION_MATRIX.md` | Multi-region database conflicts |
| `05-advanced/IPV4_IPV6_REQUIREMENTS.md` | Dual-stack networking |
| `06-features/APPLICATION_CATALOG.md` | Self-service application catalog (Nextcloud, Gitea, etc.) |

---

## Version History

| Date | Change |
|------|--------|
| 2026-03-13 | Initial creation. Restructured from single 12-week "Phase 1" into 3 project phases. Phase 1 (Infrastructure) marked COMPLETE. |
