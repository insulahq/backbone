# PostgreSQL + repmgr Role

Deploys PostgreSQL 18 with repmgr 5.5 for primary/standby streaming replication with automatic failover.

## Architecture

```
ns1                              ns2
┌─────────────────┐              ┌─────────────────┐
│ PostgreSQL 18   │  streaming   │ PostgreSQL 18   │
│ repmgr 5.5     ├──replication──┤ repmgr 5.5     │
│ (primary or    │              │ (standby or    │
│  standby)      │              │  primary)      │
└────────┬────────┘              └────────┬────────┘
         │         NetBird mesh           │
         └────────────────────────────────┘
```

One node is the primary (accepts writes), the other is a streaming standby (read-only). repmgrd monitors the cluster and promotes the standby if the primary is unreachable for 60 seconds (6 attempts x 10s interval).

## What It Does

1. **Deploys custom entrypoint wrapper** -- Handles idempotent registration, stale PID cleanup, `pg_rewind` for failover recovery
2. **Starts PostgreSQL container** -- Bound to NetBird IP only (not `0.0.0.0`, gotcha 43)
3. **Configures repmgr** -- Auto-generates `repmgr.conf` with hostname-based resolution via `extra_hosts`
4. **Creates application databases** -- On primary only (replicated to standby automatically)
5. **Configures pg_hba.conf** -- Fixes subnet ranges, enforces `scram-sha-256` authentication

## Dependencies

Must be deployed after:
1. `common` -- Docker CE
2. `netbird_peer` -- NetBird IP for binding (PostgreSQL binds to NetBird IP only)

## Key Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `postgresql_image` | `sourcemation/postgres-repmgr:5.5.0` | Pinned Docker image |
| `postgresql_install_dir` | `/opt/postgresql` | Host directory |
| `postgresql_primary_node` | `ns2` | Which node runs as primary |
| `postgresql_node_ids` | `{ns1: 1, ns2: 2}` | Maps hostname to repmgr node_id |
| `postgresql_databases` | `[{name: netbird, ...}]` | Application databases to create |
| `postgresql_superuser_password` | (group_vars) | PostgreSQL superuser password |
| `postgresql_repmgr_password` | (group_vars) | repmgr replication user password |

## Consumers

The PostgreSQL HA cluster is shared by:
- **PowerDNS** -- `powerdns` and `pdnsadmin` databases (created by `powerdns` role)
- **NetBird** -- `netbird` database (created by this role)
- **repmgr** -- `repmgr` database (created by entrypoint wrapper)

## Gotchas

- Do NOT use `bitnami/postgresql-repmgr` -- removed from registries (gotcha 11)
- Entrypoint wrapper uses `--force` flag to handle "already registered" errors (gotcha 12)
- Docker hairpin NAT: `extra_hosts` maps own hostname to 127.0.0.1, peer to NetBird IP (gotcha 13)
- pg_hba.conf: Docker bridge `172.16.0.0/12`, NetBird CGNAT `100.64.0.0/10` (gotcha 14)
- Stale `postmaster.pid` cleaned on startup (gotcha 20)
- repmgrd `conninfo` uses real NetBird IPs via `extra_hosts`, not `127.0.0.1` (gotcha 37)
- Each node lists itself first in multi-host DSN to avoid 30s timeout (gotcha 38)
- `repmgr` binary is at `/usr/lib/postgresql/18/bin/repmgr`, use `$(which repmgr)` (gotcha 41)
- PostgreSQL bound to NetBird IP only, `scram-sha-256` for all auth (gotcha 43)
