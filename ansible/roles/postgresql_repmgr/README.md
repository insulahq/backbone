# PostgreSQL + repmgr Role

Deploys PostgreSQL 18 with repmgr 5.5 for primary/standby streaming replication with automatic failover, automatic failback, and split-brain prevention.

## Architecture

```
ns1                              ns2
┌─────────────────┐              ┌─────────────────┐
│ PostgreSQL 18   │  streaming   │ PostgreSQL 18   │
│ repmgr 5.5     ├──replication──┤ repmgr 5.5     │
│ (primary or    │              │ (standby or    │
│  standby)      │              │  primary)      │
└────────┬────────┘              └────────┬────────┘
         │       WireGuard tunnel         │
         └────────────────────────────────┘
```

One node is the primary (accepts writes), the other is a streaming standby (read-only). The entrypoint wrapper handles all failover/failback logic with four layers of split-brain prevention.

## Failover Flow

1. Primary goes down
2. repmgrd on standby detects failure (6 x 10s = 60s detection window)
3. `promote-check.sh` validates external connectivity (prevents false promotion during WireGuard tunnel drops)
4. Standby promotes to primary (creates new timeline)
5. Old primary comes back
6. Entrypoint queries peer, sees it's primary -> starts as standby
7. `pg_rewind` syncs diverged data (falls back to full re-clone if WAL diverged too far)
8. Registers as standby, repmgrd resumes monitoring the new primary

## Split-Brain Prevention

Four layers prevent dual-primary states:

| Layer | When | How |
|-------|------|-----|
| **Startup** | Container boot | `determine_role()` queries the peer before choosing role. Never trusts the static `REPMGR_INITIAL_ROLE` env var after first boot. |
| **Promotion** | Before promoting | `promote-check.sh` verifies external connectivity. If the standby can't reach the internet, it's likely a local network issue (not a dead primary) -- promotion is blocked. |
| **Runtime** | Every 15s | Background watchdog detects if both nodes are running as primary. Lower timeline self-demotes. Same-timeline uses `REPMGR_INITIAL_ROLE` as deterministic tiebreaker. |
| **Restart** | After demotion | `.demoted` marker file in PGDATA survives container restarts. On next boot, forces standby role regardless of other checks. |

### Simultaneous Restart After Failover

If both nodes restart at the same time after a failover (e.g., datacenter-wide power outage):

- The promoted node (timeline > 1) starts as primary immediately
- The old primary (timeline = 1) waits up to 90s for the peer to appear
- If the peer appears as primary, the old primary starts as standby
- If the peer never appears (truly down), the old primary starts as primary (best effort)
- If both start as primary despite all checks, the runtime watchdog catches it within 45s

## What It Does

1. **Deploys custom entrypoint wrapper** -- Handles role detection, pg_rewind failback, split-brain watchdog, clean signal handling
2. **Starts PostgreSQL container** -- Bound to WireGuard IP only (not `0.0.0.0`, gotcha 43)
3. **Configures repmgr** -- Auto-generates `repmgr.conf` with hostname-based resolution via `extra_hosts`, `failover_validation_command` for promotion safety
4. **Creates application databases** -- On primary only (replicated to standby automatically)
5. **Configures pg_hba.conf** -- Fixes subnet ranges, enforces `scram-sha-256` authentication

## Dependencies

Must be deployed after:
1. `common` -- Docker CE
2. `wireguard` -- WireGuard tunnel IP for binding (PostgreSQL binds to WireGuard IP only)

## Key Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `postgresql_image` | `sourcemation/postgres-repmgr:5.5.0` | Pinned Docker image |
| `postgresql_install_dir` | `/opt/postgresql` | Host directory |
| `postgresql_primary_node` | `ns2` | Initial primary (only matters on first boot) |
| `postgresql_node_ids` | `{ns1: 1, ns2: 2}` | Maps hostname to repmgr node_id |
| `postgresql_databases` | `[{name: netbird, ...}]` | Application databases to create |
| `postgresql_superuser_password` | (group_vars) | PostgreSQL superuser password |
| `postgresql_repmgr_password` | (group_vars) | repmgr replication user password |

## Environment Variables (container)

| Variable | Purpose |
|----------|---------|
| `REPMGR_INITIAL_ROLE` | `primary` or `standby` -- only used on first boot (empty PGDATA) |
| `PEER_NAME` | The other node's hostname (resolved via `extra_hosts` to NetBird IP) |
| `NODE_ID` | repmgr node ID (integer) |
| `NODE_NAME` | repmgr node name (matches `inventory_hostname`) |

## Consumers

The PostgreSQL HA cluster is shared by:
- **PowerDNS** -- `powerdns` and `pdnsadmin` databases (created by `powerdns` role)
- **NetBird** -- `netbird` database (created by this role)
- **repmgr** -- `repmgr` database (created by entrypoint wrapper)

## Gotchas

- Do NOT use `bitnami/postgresql-repmgr` -- removed from registries (gotcha 11)
- Entrypoint wrapper uses `--force` flag to handle "already registered" errors (gotcha 12)
- Docker hairpin NAT: `extra_hosts` maps own hostname to 127.0.0.1, peer to WireGuard IP (gotcha 13)
- pg_hba.conf: Docker bridge `172.16.0.0/12`, WireGuard `10.0.0.0/8` (gotcha 14)
- Stale `postmaster.pid` cleaned on startup (gotcha 20)
- repmgrd `conninfo` uses real WireGuard IPs via `extra_hosts`, not `127.0.0.1` (gotcha 37)
- Each node lists itself first in multi-host DSN to avoid 30s timeout (gotcha 38)
- `repmgr` binary is at `/usr/lib/postgresql/18/bin/repmgr`, use `$(which repmgr)` (gotcha 41)
- PostgreSQL bound to WireGuard IP only, `scram-sha-256` for all auth (gotcha 43)
- Old wrapper had no failback logic -- old primary restarted as primary creating split-brain (gotcha 49, fixed)

## Known Limitation

With only 2 nodes and no external consensus mechanism (etcd/Consul), a true network partition where both nodes are running and the WireGuard tunnel drops for >70s can still result in a brief dual-primary window. The `promote-check.sh` (external connectivity validation) reduces this risk, and the runtime watchdog resolves it within 45s of connectivity being restored. For the DNS + VPN workload, this is acceptable.
