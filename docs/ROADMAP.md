# Roadmap

## Current State (v1.0)

Two-node active-passive backbone with full HA:

- PostgreSQL 18 HA with repmgr auto-failover (60s detection)
- pgproxy write proxy (all services write to current primary regardless of node)
- Active-passive DNS (automatic switching via platform-dns-switch)
- Post-promote hook updates pgproxy + DNS + restarts consumers
- WAL gap auto-recovery with log-based confirmation
- Rolling update playbook for zero-downtime container upgrades
- All tests passing (62 non-destructive + 15 destructive failover)

### Services Running

| Service | Version | Both Nodes |
|---------|---------|:----------:|
| PostgreSQL + repmgr | 18 + 5.5 | Yes |
| PowerDNS (Native mode) | 5.0 | Yes |
| Traefik | 3.6 | Yes |
| NetBird (management + mesh) | 0.67.0 | Yes |
| Zitadel IAM | 4.12.3 | Yes |
| Gatus monitoring | 5.14.0 | Yes |
| Portainer | 2.39.0 | Yes |
| Restic backup | 0.16.4 | Yes |

---

## Phase 1: CDN Integration (Quick Win)

**Goal**: Instant global latency improvement with zero infrastructure changes.

**Approach**: Place Cloudflare (free tier) in front of Traefik for hosted websites.

- Static assets served from Cloudflare edge PoPs worldwide
- TLS termination at Cloudflare edge (removes 1-2 round-trips for distant users)
- DDoS protection included
- Backbone DNS remains authoritative (Cloudflare proxies HTTP only)

**Effort**: Low (DNS config changes only)
**Impact**: High for static-heavy websites

### What Changes
- Add Cloudflare as reverse proxy for hosted domains (orange cloud)
- Backbone Traefik serves as origin
- PowerDNS continues to serve authoritative DNS for the platform domain itself

### What Doesn't Change
- All backbone infrastructure stays as-is
- PowerDNS still manages zone records
- HA failover continues to work (Cloudflare health checks can detect origin failures)

---

## Phase 2: Read-Replica Edge Nodes

**Goal**: Serve read-heavy workloads from geographically closer nodes.

**Approach**: Deploy lightweight edge nodes that run a subset of backbone services with a PostgreSQL read-only replica.

### Architecture

```
                    ┌─────────────────┐
                    │  Geo-DNS Router  │
                    │ (PowerDNS GeoIP) │
                    └────┬────────┬───┘
                         │        │
              European   │        │  African
              users      │        │  users
                         │        │
                         ▼        ▼
              ┌──────────────┐  ┌──────────────┐
              │ ns1/ns2      │  │ edge-af1     │
              │ (Europe)     │  │ (Africa)     │
              │              │  │              │
              │ PG Primary   │◄─│ PG Standby   │
              │ Full stack   │  │ Traefik      │
              │ Read + Write │  │ PowerDNS     │
              │              │──►│ pgproxy→EU   │
              └──────────────┘  └──────────────┘
                   WireGuard mesh
```

### Edge Node Services

| Service | Runs on Edge? | Purpose |
|---------|:------------:|---------|
| PostgreSQL (standby) | Yes | Read-only replica for local reads |
| pgproxy | Yes | Routes writes to backbone PG primary |
| PowerDNS | Yes | Serves DNS queries from local replica |
| Traefik | Yes | TLS termination, reverse proxy |
| NetBird peer | Yes | VPN mesh connectivity to backbone |
| Zitadel | No | Auth stays on backbone (write-heavy) |
| NetBird management | No | Signal exchange requires single server |
| Gatus | No | Monitoring stays on backbone |
| Portainer | No | Management stays on backbone |

### Latency Improvement (Africa Example)

| Request Type | Direct to Europe | Via Africa Edge |
|-------------|:---:|:---:|
| DNS query | ~180ms | ~5ms |
| TLS handshake | ~360ms | ~10ms |
| Static page load | ~200ms | ~10ms |
| DB read (1 query) | ~180ms | ~5ms (local replica) |
| DB write (1 query) | ~180ms | ~360ms (round-trip) |
| Full page (3 reads + 1 write) | ~720ms | ~365ms |

### Implementation Plan

1. **New Ansible group**: `edge_nodes` in inventory
2. **WireGuard mesh extension**: Hub-and-spoke from edge → both backbone nodes
3. **New role: `edge_node`**: Deploys PG standby + Traefik + PowerDNS + pgproxy
4. **PG standby auto-clone**: Edge PG clones from backbone primary via WireGuard
5. **pgproxy on edge**: Routes writes to backbone primary WireGuard IP
6. **PowerDNS on edge**: Reads from local PG standby (zone data replicated via PG)
7. **Traefik on edge**: TLS termination for hosted sites, reverse proxy to local apps

**Effort**: Medium (new Ansible role + WireGuard mesh extension)
**Dependencies**: Phase 1 not required, but recommended

---

## Phase 3: Geo-DNS Routing

**Goal**: Automatically route users to the nearest edge node.

### Option A: PowerDNS GeoIP Backend (Self-Hosted)

Add GeoIP module to existing PowerDNS:

```
launch=gpgsql,geoip
geoip-database-file=/usr/share/GeoIP/GeoLite2-City.mmdb
geoip-zones-file=/etc/powerdns/geo-zones.yaml
```

Per-domain geo-zone config:
```yaml
domains:
  - domain: example.com
    ttl: 30
    records:
      www.example.com:
        - selectortype: closest
          selector:
            default: "<ns1_ip>"        # Europe (backbone)
            af: "<edge-af1_ip>"        # Africa edge
            as: "<edge-as1_ip>"        # Asia edge (future)
```

**Pros**: Self-hosted, integrates with existing PowerDNS, free
**Cons**: Requires MaxMind GeoIP DB updates, per-domain config

### Option B: Cloudflare Geo-Steering (Managed)

Use Cloudflare Load Balancing ($5/mo) with geo-steering policies:
- Regions map to origin pools
- Automatic health checking + failover
- Zero self-hosted infrastructure for routing

**Pros**: Simple, reliable, global
**Cons**: Monthly cost, external dependency

### Recommended Path
- Start with Option A (PowerDNS GeoIP) for the platform domain
- Use Option B (Cloudflare) for hosted customer domains that need global reach

**Effort**: Medium
**Dependencies**: Phase 2 (edge nodes must exist to route to)

---

## Phase 4: Additional Edge Regions

**Goal**: Expand geographic coverage based on user demand.

### Potential Regions

| Region | Location | Use Case |
|--------|----------|----------|
| Africa | Johannesburg / Lagos | Sub-Saharan Africa |
| Asia | Singapore / Mumbai | Southeast Asia / India |
| Americas | Sao Paulo / Miami | Latin America |
| Middle East | Dubai | MENA region |

### Per-Region Deployment

Each edge node follows the same pattern from Phase 2:
1. Provision VPS in target region
2. Add to `edge_nodes` inventory group
3. Run `ansible-playbook site.yml --limit edge-xx1`
4. Add GeoIP routing rules for the region
5. Verify with latency tests

**Effort**: Low per node (pattern established in Phase 2)
**Dependencies**: Phase 2 + Phase 3

---

## Phase 5: Multi-Master PostgreSQL (Future)

**Goal**: Eliminate write latency penalty on edge nodes.

**Approach**: Replace PG streaming replication with multi-master:
- **BDR (Bi-Directional Replication)**: PostgreSQL extension for multi-master
- **CockroachDB**: Distributed SQL with automatic geo-partitioning
- **Citus**: PostgreSQL extension for distributed tables

This is a fundamental architecture change and should only be considered when:
- Write latency on edge nodes becomes a real bottleneck
- The number of edge nodes exceeds what streaming replication can handle
- Application workload is write-heavy (not typical for web hosting)

**Effort**: Very High (architecture redesign)
**Dependencies**: Phase 2-4 operational experience

---

## Backlog: Security Hardening

Items identified in code review, deferred from v1.0:

| Item | Priority | Description |
|------|----------|-------------|
| Docker socket proxy | High | Replace `0666` socket with restricted proxy (e.g., `tecnativa/docker-socket-proxy`) |
| Test result aggregation | Medium | Fix failover test count (results from non-primary host not aggregated in summary) |
| Ansible role DNS task idempotency | Low | Roles still create DNS records on deploy (overridden by PG wrapper, but brief window) |

---

## Decision Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-25 | Active-passive DNS (no round-robin) | NetBird signal exchange requires single-server; round-robin broke peer connectivity |
| 2026-03-25 | pgproxy (socat) over HAProxy | Simplicity; socat is 1 line vs HAProxy config; sufficient for 2-node |
| 2026-03-25 | PowerDNS moved from host network to Docker bridge | LUA health checks disabled; bridge enables pgproxy access + PDA connectivity |
| 2026-03-25 | DOCKER-USER iptables chain for port blocking | Docker's iptables-nft bypasses nftables FORWARD chain; DOCKER-USER is the official hook |
| 2026-03-25 | Post-promote hook (not promote-check) for pgproxy/DNS | promote-check runs pre-promotion; curl/nsenter calls caused SIGPIPE (exit 141) |
| 2026-03-25 | Embedded Dex authStore → PostgreSQL | SQLite idp.db not replicated; authStore config available since NetBird v0.66.1 |
