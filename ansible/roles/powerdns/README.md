# PowerDNS Role

Deploys PowerDNS 4.9 authoritative server on both ns1 and ns2 with a shared PostgreSQL HA backend. Zone data replicates via PostgreSQL streaming replication (repmgr), not AXFR/NOTIFY.

## Architecture

Both nodes run PowerDNS in **Native mode** (read-write). There is no DNS primary/secondary distinction -- both can serve queries and accept API writes (with a caveat below).

```
ns1                                ns2
┌──────────────────┐               ┌──────────────────┐
│  PowerDNS 4.9    │               │  PowerDNS 4.9    │
│  (Native, r/w)   │               │  (Native, r/w)   │
│       │          │               │       │          │
│  ┌────▼────┐     │               │  ┌────▼────┐     │
│  │ gpgsql  │     │   streaming   │  │ gpgsql  │     │
│  │ backend ├─────┼──replication──┼──┤ backend │     │
│  └─────────┘     │   (repmgr)    │  └─────────┘     │
│  PG primary/     │               │  PG standby/     │
│  standby         │               │  primary         │
└──────────────────┘               └──────────────────┘
```

**Write limitation:** DNS API writes (creating zones, adding records) only succeed on the node running the PostgreSQL HA primary. The other node's PowerDNS can serve DNS queries (reads from PG standby) but API write operations will fail because its local PostgreSQL is a read-only standby. This is acceptable for Phase 1.

## Components

| Container | Image | Purpose |
|-----------|-------|---------|
| `powerdns-auth` | `powerdns/pdns-auth-49` | Authoritative DNS server |
| `powerdns-nginx` | `nginx:alpine` | API proxy, binds to NetBird IP only |
| `powerdns-admin` | `powerdnsadmin/pda-legacy:v0.4.1` | Web UI (ns1 only) |

## Dependencies

Must be deployed after:
1. `common` -- Docker CE, OS hardening
2. `postgresql_repmgr` -- PostgreSQL HA cluster (provides the `postgresql_default` Docker network)
3. `netbird_peer` -- NetBird IP for API binding (optional; falls back to `127.0.0.1`)

## Key Variables

Set in `group_vars/all.yml` or vault:

| Variable | Description | Default |
|----------|-------------|---------|
| `powerdns_api_key` | API authentication key | Auto-generated to `.generated_secrets/` |
| `powerdns_db_password` | PostgreSQL password for `pdns` user | Auto-generated |
| `powerdns_db_name` | PowerDNS database name | `powerdns` |
| `powerdns_db_user` | PowerDNS database user | `pdns` |
| `powerdns_bind_interface` | Interface for API binding | `{{ netbird_ip }}` or `127.0.0.1` |
| `powerdns_admin_node` | Node that runs PowerDNS-Admin UI | `ns1` |
| `platform_domain` | Platform domain for zone creation | (required) |
| `postgresql_primary_node` | Node running PG primary (for DB init) | (required) |

## What This Role Does

1. **Generates secrets** -- API key, DB passwords, admin secret key (persisted in `.generated_secrets/`)
2. **Creates databases** -- `powerdns` and `pdnsadmin` databases/users on the PG primary
3. **Initializes schema** -- PowerDNS 4.9 official PostgreSQL schema (idempotent, `IF NOT EXISTS`)
4. **Deploys stack** -- `pdns.conf`, `docker-compose.yml`, `nginx.conf` templates
5. **Starts services** -- PowerDNS + nginx proxy (+ PowerDNS-Admin on ns1)
6. **Creates platform zone** -- `{{ platform_domain }}` as Native zone with SOA serial increment

## Network Topology

- **DNS (port 53):** Bound to `0.0.0.0` -- serves public DNS queries
- **API (port 8081):** Bound to NetBird IP -- accessible only via VPN mesh
- **Admin UI (port 8080):** Bound to NetBird IP, ns1 only -- accessible only via VPN mesh
- **PostgreSQL:** Connected via `postgresql_default` Docker network (internal)

## Gotchas

- `pdns_control ping` is invalid in PowerDNS 4.9; use `pdns_control uptime` for health checks (gotcha 29)
- `pdnsutil add-record` does NOT auto-increment SOA serial; always run `pdnsutil increase-serial` after (gotcha 30)
- `soa_edit_api: INCEPTION-INCREMENT` doesn't fire when serial is 0; manually increment after zone creation (gotcha 33)
- PowerDNS webserver restricted to `127.0.0.0/8,172.16.0.0/12,10.0.0.0/8` (gotcha 46)
- `pdns.conf` deployed with mode `0600` to protect API key (gotcha 45)
