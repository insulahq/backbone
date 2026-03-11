# Fresh Infrastructure Deployment Plan

**Document Version:** 1.0  
**Created:** 2026-03-11  
**Status:** ACTIVE — Fresh deployment from scratch  
**Audience:** DevOps engineers, infrastructure architects

---

## Overview

This document defines the infrastructure architecture for the fresh deployment of Phoenix Host, replacing the previous Ansible-based infrastructure that has been removed.

**Key changes from previous deployment:**
- Servers ns1, ns2, and admin1 will be **re-imaged** with fresh OS
- No complex firewall rules or advanced pre/post-routing configurations
- Simplified nftables rules to avoid access issues
- All previous Ansible roles, k8s manifests, and infrastructure config removed

---

## Server Layout

### Server Inventory

| Server | Public IP | Role | Location | Specs |
|--------|-----------|------|----------|-------|
| **ns1.phoenix-host.net** | `23.88.111.142` | PowerDNS Primary + NetBird Management/Signal/Relay | Hetzner Falkenstein | CX22 (2 vCPU, 4GB RAM, 40GB NVMe) |
| **ns2.phoenix-host.net** | `89.167.125.29` | PowerDNS Secondary + NetBird Peer | Hetzner Helsinki | CX22 (2 vCPU, 4GB RAM, 40GB NVMe) |
| **admin1.phoenix-host.net** | `46.224.122.58` | k3s + Management API + Admin Panel + Client Panel + Phase 1 Workloads | Hetzner (TBD location) | CX32 (4 vCPU, 8GB RAM, 80GB NVMe) |

**NetBird mesh IPs (from previous deployment — will be reassigned after fresh NetBird setup):**
- ns1: `100.76.182.198`
- ns2: `100.76.92.172`
- admin1: `100.76.98.87`
- workstation: `100.76.226.120`

**Note:** NetBird IPs may change after re-imaging. Update documentation once mesh is re-established.

---

## Architecture Decisions

### DNS Server: PowerDNS (Confirmed)

**Decision:** Use **PowerDNS 4.9** in Docker Compose on ns1 (primary) and ns2 (secondary).

**Rationale (from ADR-016):**
- ✅ **Distro-independent:** Official Docker image `powerdns/pdns-auth-49` works on any OS
- ✅ **No apt repository issues:** Previous deployment had libboost dependency conflicts on Debian 13
- ✅ **Easy backup:** Docker volumes provide clear backup targets
- ✅ **Proven in previous deployment:** PowerDNS + PostgreSQL (ns1) + SQLite (ns2) worked well
- ✅ **REST API:** PowerDNS API enables programmatic zone/record management from Management API
- ✅ **AXFR/NOTIFY:** Native zone replication (< 5 seconds propagation)
- ✅ **DNSSEC support:** Built-in, optional per domain

**PowerDNS vs BIND + rndc:**

| Aspect | PowerDNS 4.9 | BIND 9 + rndc |
|--------|--------------|---------------|
| **API** | ✅ Native REST API | ❌ No native API (must use rndc or dynamic updates) |
| **Zone replication** | ✅ AXFR/NOTIFY built-in | ✅ AXFR/NOTIFY via zone transfers |
| **Backend** | ✅ PostgreSQL, MySQL, SQLite | ❌ Flat zone files (or LDAP backend) |
| **Docker deployment** | ✅ Official image `powerdns/pdns-auth-49` | ⚠️ Community images (ISC doesn't publish official) |
| **Dynamic updates** | ✅ Via REST API (JSON) | ⚠️ Via rndc + zone file rewrites or RFC 2136 |
| **DNSSEC** | ✅ Built-in `pdnsutil` commands | ✅ Built-in `dnssec-*` tools |
| **Documentation** | ✅ Extensive REST API docs | ✅ Extensive BIND ARM |
| **Programmatic management** | ✅ Simple HTTP API calls | ❌ Must parse zone files or use rndc (text protocol) |
| **Multi-region** | ✅ Autosecondary for multi-primary | ⚠️ Requires manual zone file sync or catalog zones |

**Recommendation:** **PowerDNS** (aligned with ADR-016 and existing documentation).

**Reasoning:**
1. **REST API is critical** — Management API needs to create zones and records programmatically. PowerDNS provides a clean JSON REST API. BIND requires rndc (text protocol) or dynamic updates (RFC 2136), both more complex.
2. **Database-backed** — PowerDNS stores zones in PostgreSQL (ns1) and SQLite (ns2), making backup and replication straightforward. BIND uses zone files, requiring file parsing.
3. **Already documented** — All project documentation (`DISPERSED_DNS_ARCHITECTURE.md`, `POWERDNS_INTEGRATION.md`, ADR-016) is written for PowerDNS.
4. **Proven in previous deployment** — PowerDNS worked reliably in the previous infrastructure.

**Alignment check:** ✅ PowerDNS is specified in:
- `docs/01-core/DISPERSED_DNS_ARCHITECTURE.md`
- `docs/01-core/POWERDNS_INTEGRATION.md`
- `docs/ARCHITECTURE_DECISION_RECORDS.md` (ADR-016)

---

## Infrastructure Components

### 1. DNS Servers (ns1, ns2)

**ns1 (Primary):**
- PowerDNS 4.9 in Docker Compose
- PostgreSQL 16 backend (Docker named volume `pdns_pgdata`)
- PowerDNS API at `http://127.0.0.1:8081` (accessible via NetBird mesh)
- NetBird Management server + Signal server + Relay server (all-in-one)
- Public DNS on port 53 (UDP/TCP)
- AXFR source for ns2
- Backup: Restic → Hetzner Storagebox (PostgreSQL dump, NetBird SQLite, configs)

**ns2 (Secondary):**
- PowerDNS 4.9 in Docker Compose
- SQLite backend (Docker named volume `pdns_sqlite`)
- NetBird peer only (no management/signal/relay)
- Public DNS on port 53 (UDP/TCP)
- AXFR target from ns1
- Autosecondary enabled (zones auto-replicate from ns1)
- Backup: Restic → Hetzner Storagebox (SQLite, configs)

**No API on ns2** — all zone management happens on ns1.

**Config paths:**
- ns1: `/opt/powerdns/docker-compose.yml`, `/opt/powerdns/pdns.conf`
- ns2: `/opt/powerdns/docker-compose.yml`, `/opt/powerdns/pdns-slave.conf`

### 2. NetBird VPN Mesh (Redundant Design)

**Architecture (DNS Round-Robin with Floating IP Preparation):**

**Active Deployment:**
- **ns1:** NetBird Management + Signal + Relay (full stack)
- **ns2:** NetBird Management + Signal + Relay (full stack, standby)
- **admin1:** NetBird peer
- **workstation:** NetBird peer

**Shared State:**
- PostgreSQL database for NetBird (deployed on ns1, accessed by both ns1 and ns2)
- Both ns1 and ns2 connect to same PostgreSQL instance
- Peer configurations replicated via shared database

**DNS Configuration:**
```
netbird.phoenix-host.net.          IN  A  23.88.111.142  ; ns1
netbird.phoenix-host.net.          IN  A  89.167.125.29  ; ns2
netbird-signal.phoenix-host.net.   IN  A  23.88.111.142  ; ns1
netbird-signal.phoenix-host.net.   IN  A  89.167.125.29  ; ns2
```

**Failover Mechanism:**
- **Current:** DNS round-robin (automatic failover, 5-10 second delay)
- **Future:** Floating IP support prepared (requires infrastructure upgrade)

**Purpose:**
- Secure admin access to all servers
- Management API connects to PowerDNS API on ns1 via NetBird mesh
- k3s cluster on admin1 can communicate with ns1/ns2 for DNS operations
- High availability: If ns1 fails, ns2 serves NetBird management/signal/relay

**NetBird endpoints:**
- Management UI: `https://netbird.phoenix-host.net` → both ns1 and ns2 (DNS round-robin)
- Signal server: `netbird-signal.phoenix-host.net:443` → both ns1 and ns2 (gRPC over TLS)
- Relay server: STUN/TURN on both ns1 and ns2

**Floating IP Preparation (Future):**
- DNS will be updated to point to a single floating IP: `netbird.phoenix-host.net. IN A 100.76.100.100`
- Floating IP managed by keepalived or Hetzner Floating IP feature
- Requires Layer 2 network adjacency or Hetzner Cloud migration
- See ADR-021 for migration path

### 3. k3s Kubernetes Cluster (admin1)

**Deployment:** Single-node k3s cluster on admin1 (Phase 1)

**Workloads:**
- Management API (Fastify backend + MariaDB)
- Admin Panel (Vite + React frontend)
- Client Panel (Vite + React frontend)
- Phase 1 customer workloads (Starter/Business plan pods)

**Storage:**
- Local path provisioner (default k3s storage class)
- MariaDB: StatefulSet with persistent volume

**Ingress:**
- Traefik (k3s built-in ingress controller)
- DNS-based routing (A records in PowerDNS point to admin1 public IP)

**Backup:**
- Restic → Hetzner Storagebox (MariaDB dumps, PVC data, k3s manifests)

### 4. Management API (admin1 — k3s pod)

**Stack:** Node.js 22 + Fastify 4 + TypeScript + Knex + MariaDB

**Database:** MariaDB 11 (StatefulSet in k3s)

**API endpoints:**
- `POST /api/v1/auth/token` — JWT authentication
- `GET /api/v1/admin/status` — Health check
- Client CRUD: `GET/POST/PATCH/DELETE /api/v1/admin/clients`
- Domain CRUD: `GET/POST/PATCH/DELETE /api/v1/admin/domains`
- PowerDNS integration: Create zones, add/update/delete records

**Connects to:**
- PowerDNS API on ns1 (via NetBird mesh at `http://100.76.182.198:8081`)
- MariaDB in k3s cluster

**Public endpoint:** `https://admin.phoenix-host.net/api/v1` (Traefik ingress)

### 5. Admin Panel & Client Panel (admin1 — k3s pods)

**Admin Panel:**
- React 18 + Vite + TypeScript + shadcn/ui + Tailwind CSS
- Deployed as static site (nginx container)
- Public endpoint: `https://admin.phoenix-host.net`
- Features: Client management, DNS management, billing, monitoring (see `docs/02-operations/ADMIN_PANEL_REQUIREMENTS.md`)

**Client Panel:**
- React 18 + Vite + TypeScript + shadcn/ui + Tailwind CSS
- Deployed as static site (nginx container)
- Public endpoint: `https://client.phoenix-host.net`
- Features: File manager, email management, database management (see `docs/02-operations/CLIENT_PANEL_FEATURES.md`)

### 6. Backup Infrastructure

**Tool:** Restic → Hetzner Storagebox (SFTP)

**Backup schedule:**
- ns1: 02:00 UTC — PostgreSQL dump (PowerDNS + NetBird), configs
- ns2: 02:15 UTC — SQLite dump (PowerDNS only), configs
- admin1: 02:30 UTC — MariaDB dump, k3s PVCs, configs

**Note:** NetBird state is stored in PostgreSQL on ns1 (shared between ns1 and ns2)

**Retention:** 7 daily, 4 weekly, 12 monthly (see `docs/02-operations/BACKUP_STRATEGY.md`)

**Backup target:** `u335448-sub9@u335448.your-storagebox.de` (verify credentials with user)

---

## Firewall & Network Security

### Critical Lesson from Previous Deployment

**ISSUE:** Advanced nftables pre-routing and post-routing configurations caused access loss to ns1 server after NetBird configuration changes.

**ROOT CAUSE:** Complex DNAT rules and custom routing chains interacted unpredictably with NetBird's WireGuard interface and Docker's iptables chains.

**SOLUTION FOR FRESH DEPLOYMENT:**

1. **Keep firewall rules simple** — Only essential INPUT, OUTPUT, and FORWARD chains
2. **No advanced pre-routing or post-routing** — Avoid custom DNAT, SNAT, or MASQUERADE rules unless absolutely necessary
3. **No complex NAT chains** — Let Docker and NetBird manage their own NAT
4. **Default policy: DROP on INPUT, ACCEPT on OUTPUT** — Block inbound by default, allow established connections
5. **Whitelist only required ports:**
   - Port 53 (DNS — UDP/TCP) — public
   - Port 443 (HTTPS — Traefik, NetBird management UI) — public
   - Port 51820 (WireGuard — NetBird) — public
   - Port 10000 (NetBird relay TURN) — public
   - SSH only via NetBird mesh (no public SSH)

### Recommended nftables Baseline (Simple)

```nft
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;
    
    # Allow loopback
    iif "lo" accept
    
    # Allow established/related
    ct state established,related accept
    
    # Allow ICMP (ping)
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    
    # Allow DNS (public)
    tcp dport 53 accept
    udp dport 53 accept
    
    # Allow HTTPS (public)
    tcp dport 443 accept
    
    # Allow WireGuard (NetBird)
    udp dport 51820 accept
    
    # Allow NetBird relay TURN (if needed)
    udp dport 10000 accept
    
    # Allow SSH from NetBird mesh only (not public)
    # (Add NetBird interface name after NetBird is configured)
    # iifname "wt0" tcp dport 22 accept
    
    # Log and drop everything else
    counter drop
  }
  
  chain forward {
    type filter hook forward priority filter; policy accept;
    
    # Allow established/related
    ct state established,related accept
    
    # Docker will add its own rules here
  }
  
  chain output {
    type filter hook output priority filter; policy accept;
  }
}
```

**Rules:**
- ✅ Simple INPUT chain with explicit port allow-list
- ✅ No custom DNAT or SNAT
- ✅ Docker manages FORWARD chain (containers can communicate)
- ✅ OUTPUT policy accept (services can make outbound connections)
- ❌ No pre-routing or post-routing hooks
- ❌ No custom NAT chains

**Docker compatibility:**
- Docker injects its own rules into the FORWARD chain
- After nftables reload, **restart Docker** to restore Docker's chains (see AGENTS.md gotcha #2)

**NetBird compatibility:**
- NetBird creates its own WireGuard interface (`wt0`)
- After NetBird is configured, optionally add: `iifname "wt0" tcp dport 22 accept` to allow SSH only from mesh
- Do not add custom routing rules for NetBird traffic

---

## Deployment Automation Approach

### Decision Point: Ansible, Docker Compose, or Manual?

**Options:**

1. **Rebuild Ansible roles from scratch** (like previous deployment)
   - Pro: Reproducible, idempotent, version-controlled
   - Con: Time-consuming to recreate all roles
   
2. **Docker Compose only** (no configuration management)
   - Pro: Faster to deploy, simpler
   - Con: OS hardening and package installation still manual
   
3. **Manual deployment with documentation** (step-by-step runbook)
   - Pro: Full control, no abstraction
   - Con: Error-prone, not reproducible

**Recommendation:** **Rebuild Ansible roles (Option 1)** — aligned with Phase 1 roadmap.

**Reasoning:**
- Previous Ansible roles worked well (common, netbird_management, netbird_peer, powerdns_master, powerdns_slave, backup)
- Reproducible deployment is critical for disaster recovery
- Phase 1 roadmap (Week 1-2) includes Ansible infrastructure automation
- We can reuse the structure of previous roles while simplifying firewall rules

**Alignment check:** ✅ Phase 1 roadmap (`docs/04-deployment/PHASE_1_ROADMAP.md`) specifies Ansible in Week 1-2.

---

## Phase 1 Deployment Order

### Week 1-2: Infrastructure (Ansible)

1. **Re-image servers** — Fresh Debian 13 (or Debian 12 stable) on ns1, ns2, admin1
2. **Ansible: common role** — OS hardening, nftables (simple rules), Docker CE, fail2ban
3. **Ansible: netbird_management role** — Deploy NetBird stack on ns1 (management + signal + relay)
4. **Ansible: netbird_peer role** — Deploy NetBird peer on ns2, admin1, workstation
5. **Verify NetBird mesh** — All nodes can ping each other via NetBird IPs
6. **Ansible: powerdns_master role** — Deploy PowerDNS + PostgreSQL on ns1
7. **Ansible: powerdns_slave role** — Deploy PowerDNS + SQLite on ns2
8. **Verify DNS replication** — Create test zone on ns1, confirm it appears on ns2 within 5 seconds
9. **Ansible: backup role** — Deploy Restic backup on all servers
10. **Verify backups** — Trigger manual backup, confirm files appear on Storagebox

### Week 3-4: Management API Deployment

11. **Ansible: k3s role** — Deploy k3s on admin1 (single-node cluster)
12. **Deploy MariaDB StatefulSet** — Persistent volume, root password in k8s secret
13. **Run Knex migrations** — Create clients, domains, databases, audit_logs tables
14. **Deploy Management API pod** — Connect to MariaDB and PowerDNS API (via NetBird)
15. **Verify API health** — `GET https://admin.phoenix-host.net/api/v1/admin/status` returns 200 OK
16. **Test API endpoints** — Create client, create domain, add DNS record, verify on ns1/ns2

### Week 5-6: Admin Panel MVP (Next Task)

17. **Scaffold admin panel** — Vite + React + TypeScript + shadcn/ui
18. **Deploy admin panel pod** — Static site, nginx container
19. **Implement client management** — List, create, edit, delete clients
20. **Implement domain management** — List, create, delete domains, add DNS records

---

## Architecture Decisions (User Confirmed)

**Date Confirmed:** 2026-03-11

1. ✅ **Server OS:** **Debian 13 (trixie)** — Official Debian stable release
   
2. ✅ **NetBird setup:** **Fresh deployment** — Deploy new NetBird management server on ns1
   
3. ✅ **Backup credentials:** **`phoenix-host.key.pub`** — SSH public key for Storagebox authentication
   - Storagebox: `u335448-sub9@u335448.your-storagebox.de`
   
4. ✅ **SSH access:** **Option A + Keep SSH open** — Public SSH during deployment, remain open as break-glass access
   - SSH will remain available on all servers for emergency access
   - Primary access via NetBird mesh once deployed
   
5. ✅ **Ansible connection:** **Confirmed**
   - `ansible_user=root`
   - `ansible_ssh_private_key_file=~/phoenix-host.key`

---

## Deployment Sequence

**Status:** READY TO PROCEED — User confirmed architecture decisions above.

### Phase 1: Ansible Infrastructure (Week 1-2)

1. ✅ **Create Ansible inventory** — `ansible/inventory/hosts.yml` with server IPs and vars
2. ✅ **Create `common` role** — OS hardening, simple nftables (SSH + break-glass), Docker CE, fail2ban
3. ⏳ **Create `netbird_management` role** — Deploy NetBird stack on **both ns1 and ns2** (redundant, ADR-021)
4. ⏳ **Create `netbird_peer` role** — Deploy NetBird peer on admin1, workstation
5. ⏳ **Verify NetBird mesh** — All nodes can ping each other via NetBird IPs
6. ⏳ **Configure DNS round-robin** — Add dual A records for `netbird.phoenix-host.net` (ns1 + ns2 IPs)
7. ⏳ **Create `powerdns_master` role** — Deploy PowerDNS + PostgreSQL on ns1
8. ⏳ **Create `powerdns_slave` role** — Deploy PowerDNS + SQLite on ns2
9. ⏳ **Verify DNS replication** — Create test zone on ns1, confirm it appears on ns2 within 5s
10. ⏳ **Create `backup` role** — Deploy Restic backup on all servers (PostgreSQL includes NetBird database)
11. ⏳ **Verify backups** — Trigger manual backup, confirm files appear on Storagebox

---

## Summary

| Component | Technology | Deployment | Location |
|-----------|-----------|-----------|----------|
| **DNS Primary** | PowerDNS 4.9 + PostgreSQL 16 | Docker Compose | ns1 |
| **DNS Secondary** | PowerDNS 4.9 + SQLite | Docker Compose | ns2 |
| **VPN Mesh** | NetBird (redundant) | Docker Compose (ns1 + ns2), binary (peers) | All servers |
| **k3s Cluster** | k3s (single-node Phase 1) | Ansible | admin1 |
| **Management API** | Fastify + MariaDB | k3s pod | admin1 |
| **Admin Panel** | React + Vite | k3s pod (nginx) | admin1 |
| **Client Panel** | React + Vite | k3s pod (nginx) | admin1 |
| **Backups** | Restic → Storagebox | Systemd timer | All servers |
| **Firewall** | nftables (simple rules) | Ansible | All servers |
| **Automation** | Ansible 2.15+ | Local workstation | — |

**Alignment:** ✅ All decisions align with `docs/01-core/DISPERSED_DNS_ARCHITECTURE.md`, `docs/ARCHITECTURE_DECISION_RECORDS.md` (ADR-016, ADR-021), and Phase 1 roadmap.

**Firewall:** ✅ Simple nftables rules only — no advanced pre/post-routing to avoid access issues.

**DNS:** ✅ PowerDNS (not BIND) — REST API, database-backed, proven in previous deployment.

**NetBird Redundancy:** ✅ DNS round-robin (now) with floating IP preparation (future) — see ADR-021.

---

## Future Upgrade Path: Floating IP for NetBird

**When to upgrade:**
- Failover delay < 5 seconds becomes critical
- ns1 and ns2 moved to same datacenter (enables keepalived)
- Platform migrated to Hetzner Cloud (enables Hetzner Floating IPs)

**Migration steps:**

1. **Provision floating IP:**
   - **Option A (Keepalived):** Requires ns1 and ns2 on same Layer 2 network
     ```bash
     # Configure keepalived on both ns1 and ns2
     # Virtual IP: 100.76.100.100 (example)
     ```
   - **Option B (Hetzner Cloud Floating IP):** Requires migration to Hetzner Cloud
     ```bash
     # Provision Hetzner Floating IP via Cloud Console or API
     # Assign to ns1 (primary)
     ```

2. **Update DNS records:**
   ```bash
   # Remove dual A records
   # Add single A record pointing to floating IP
   curl -X PATCH http://127.0.0.1:8081/api/v1/servers/localhost/zones/phoenix-host.net. \
     -H "X-API-Key: $KEY" \
     -d '{
       "rrsets": [{
         "name": "netbird.phoenix-host.net.",
         "type": "A",
         "changetype": "REPLACE",
         "records": [{"content": "100.76.100.100", "disabled": false}]
       }]
     }'
   ```

3. **Wait for DNS TTL:** Typically 300 seconds (5 minutes)

4. **Test failover:**
   ```bash
   # Stop NetBird on ns1
   systemctl stop netbird-management

   # Verify floating IP moves to ns2 (keepalived) or manually reassign (Hetzner Cloud)
   # Test NetBird clients can still connect
   ```

5. **Update Ansible variables:**
   ```yaml
   # ansible/group_vars/all.yml
   netbird_redundancy: floating_ip
   netbird_floating_ip: 100.76.100.100
   netbird_failover_method: keepalived  # or hetzner_cloud_floating_ip
   ```

**No application changes required** — NetBird clients will automatically use the new DNS record.

**See ADR-021 for detailed migration rationale and alternatives.**

---

## NetBird Certificate Bootstrap

**IMPORTANT:** NetBird Management has a circular dependency when using self-hosted authentication. Before deploying NetBird services, you must pre-generate SSL certificates using a temporary container.

**See detailed guide:** [`docs/04-deployment/NETBIRD_CERTIFICATE_BOOTSTRAP.md`](./NETBIRD_CERTIFICATE_BOOTSTRAP.md)

**Quick summary:**
1. Deploy temporary `whoami` container with Traefik labels
2. Wait 60 seconds for Let's Encrypt DNS-01 challenge to complete
3. Verify certificates exist in `acme.json`
4. Remove whoami, deploy NetBird Management
5. Traefik automatically reuses existing certificates (no new ACME challenge needed)

This approach was successfully tested on 2026-03-11 and confirmed working.
