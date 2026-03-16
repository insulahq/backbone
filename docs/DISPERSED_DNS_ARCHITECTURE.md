# Dispersed DNS Architecture (Single + Multi-Region Strategy)

**Document Version:** 3.0
**Last Updated:** 2026-03-14
**Status:** UPDATED — both nodes now run PowerDNS Native with shared PostgreSQL HA
**Audience:** DevOps engineers, platform architects, DNS administrators

---

## Overview

This document specifies the DNS architecture for the web hosting platform,
supporting both current (single-region) and future (multi-region) deployments.

### Core Strategy

**Both nodes run PowerDNS in Native mode with a shared PostgreSQL HA backend.**
Zone data replicates via PostgreSQL streaming replication (repmgr), NOT AXFR/NOTIFY.
Both nodes can read and write zones — there is no primary/secondary DNS distinction.

### Key Properties

- **Fully redundant:** Both nodes serve DNS and accept API writes
- **Shared database:** Zone data in PostgreSQL HA cluster (repmgr streaming replication)
- **No AXFR:** Zone replication happens at the database level, not DNS protocol level
- **Docker-based:** PowerDNS runs in Docker Compose — distro-independent, easy to backup
- **Simple:** No primary/secondary configuration, no NOTIFY, no zone transfer setup

---

## Phase 1: Two-Node Setup (Current)

### Architecture

```
ns1 (Hetzner Falkenstein)
├── Docker Compose at /opt/powerdns/
│   ├── powerdns/pdns-auth-49  (Port 53 public, API :8081 → WireGuard IP only)
│   ├── nginx (reverse proxy for API)
│   └── powerdns-admin (Web UI, ns1 only)
│
├── PowerDNS NATIVE (read-write)
│   ├── Backend: PostgreSQL HA cluster (via Docker network)
│   └── API writes via WireGuard tunnel
│
└── PostgreSQL HA standby (repmgr)

ns2 (Hetzner Helsinki)
├── Docker Compose at /opt/powerdns/
│   ├── powerdns/pdns-auth-49  (Port 53 public, API :8081 → WireGuard IP only)
│   └── nginx (reverse proxy for API)
│
├── PowerDNS NATIVE (read-write)
│   ├── Backend: PostgreSQL HA cluster (via Docker network)
│   └── API writes via WireGuard tunnel
│
└── PostgreSQL HA primary (repmgr)

Zone Replication:
  Write on ns1 → PostgreSQL HA → streaming replication → ns2 sees data instantly
  Write on ns2 → PostgreSQL HA → streaming replication → ns1 sees data instantly
  (writes always go to PG primary, regardless of which PowerDNS receives the API call)
```

### How It Works

1. Both PowerDNS instances connect to the **local** PostgreSQL container via Docker network (`postgresql_default`)
2. PowerDNS uses `gpgsql-host=postgresql` — Docker DNS resolves this to the local container
3. The local PostgreSQL container is either the HA primary or standby (managed by repmgr)
4. **Reads** work on both primary and standby (DNS queries are read-only)
5. **Writes** (zone creation, record changes via API) are routed to the PostgreSQL primary by the application — PowerDNS writes to whichever PG it's connected to, and if that's the standby, PG returns a read-only error
6. To handle this correctly, API writes should go through the node that hosts the PostgreSQL primary, or use a connection pooler with `target_session_attrs=read-write`

**Important:** With the current setup, DNS API writes only succeed on the node running the PostgreSQL primary. The other node's PowerDNS can serve DNS queries (reads) but API write operations will fail because its local PostgreSQL is the standby. This is acceptable for Phase 1 — Traefik DNS-01 challenges and zone management can be directed to the primary node.

### Zone Management

**API Writes:**
- DNS changes via PowerDNS API on the PostgreSQL primary node
- PowerDNS-Admin UI available on ns1 (via WireGuard tunnel)
- Both nodes serve DNS queries (reads from either primary or standby PG)

**Nameservers given to customers:**
- `ns1.<platform_domain>` — serves DNS queries (read-write if PG primary)
- `ns2.<platform_domain>` — serves DNS queries (read-write if PG primary)

### Failure Scenarios (Phase 1)

| Scenario | Impact | Recovery |
|----------|--------|----------|
| **ns1 down, ns2 is PG primary** | ns2 serves DNS + handles API writes. Full operation. | Restore ns1; repmgr auto-rejoins as standby |
| **ns2 down, ns2 is PG primary** | ns1 serves DNS queries (reads from standby PG). API writes fail until repmgr promotes ns1. | repmgrd promotes ns1 to PG primary after 60s |
| **PostgreSQL failover** | repmgr promotes standby to primary. PowerDNS on new primary resumes writes. | Automatic (repmgrd handles promotion) |
| **Network between ns1 and ns2** | PG replication pauses. Both nodes serve DNS from their local PG copy. Risk of split-brain if both accept writes. | Fix network; repmgr reconciles |

---

## Phase 2+: Multi-Region Deployment (Future)

### Architecture

In multi-region, each region runs its own PostgreSQL + PowerDNS stack:

```
Frankfurt Region                  Strasbourg Region
└── ns1-de + ns2-de               └── ns1-fr + ns2-fr
    PowerDNS + PostgreSQL HA          PowerDNS + PostgreSQL HA
    (primary for de customers)        (primary for fr customers)
```

Cross-region zone replication uses AXFR/NOTIFY between region primaries (not within a region — within a region, PostgreSQL handles it).

---

## DNSSEC Support

DNSSEC is supported via PowerDNS's `gpgsql-dnssec=yes` setting. Keys and signatures are stored in PostgreSQL and replicated to both nodes automatically.

```bash
# Enable DNSSEC for a zone
docker exec powerdns-auth pdnsutil secure-zone example.com
docker exec powerdns-auth pdnsutil show-zone example.com
```

---

## Security

- PowerDNS API is only accessible via WireGuard tunnel (nginx binds to WireGuard IP)
- Public internet can only reach port 53 (DNS queries)
- `webserver-allow-from` restricted to RFC 1918 + loopback
- pdns.conf file mode 0640, group pdns (UID 953) — protects API key
- API key never displayed in Ansible debug output

---

## Summary

| Aspect | Phase 1 (Current) | Phase 2+ (Future) |
|--------|-------------------|-------------------|
| **DNS Mode** | Native (both read-write) | Native within region |
| **Zone Replication** | PostgreSQL streaming replication | PG within region, AXFR between regions |
| **DNS Nodes** | 2 (ns1 + ns2, both equivalent) | 2+ per region |
| **API Access** | Both nodes (writes to PG primary) | Per-region API |
| **Backend** | Shared PostgreSQL HA cluster | Per-region PostgreSQL HA |
| **AXFR/NOTIFY** | Not used | Between regions only |
| **Admin UI** | PowerDNS-Admin on ns1 | Per-region |
