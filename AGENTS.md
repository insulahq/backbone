# AGENTS.md -- Hosting Platform Infrastructure

> **Read this file first.** Single entry point for any agent or developer resuming work.

---

## 1. What This Is

Ansible automation for deploying two fully redundant DNS + VPN mesh servers on two geographically separated servers. This is the infrastructure foundation for a web hosting platform (Hosting Platform). The hosting platform itself (API, panels, workloads) is built separately on top of this infrastructure.

**Scope:** Two Debian 13 servers running WireGuard, PowerDNS, Traefik, PostgreSQL HA, NetBird VPN mesh, Zitadel IAM, and Restic backups.

**Servers:**

| Server | Location | WireGuard IP | Role |
|--------|----------|-------------|------|
| ns1 | Location A | 10.100.0.1 | **Primary** — PostgreSQL primary, DNS preferred, all services |
| ns2 | Location B | 10.100.0.2 | **Secondary** — PostgreSQL standby, DNS failover, all services |

**Network Architecture:**
- **WireGuard (`wg0`)** — Infrastructure backbone. All internal services (PostgreSQL, PowerDNS API, Portainer) bind to WireGuard IPs. Zero external dependencies, established in Step 2.
- **NetBird (`wt0`)** — Overlay VPN mesh for Phase 2 servers, client access, and remote administration. Uses embedded Dex IdP for local authentication. Deployed in Step 7 after all dependencies are ready.

---

## 2. Components

| Component | Version | Description |
|-----------|---------|-------------|
| OS | Debian 13 | Hardened with nftables + fail2ban |
| WireGuard | kernel | Infrastructure backbone tunnel, zero-dependency private network |
| PowerDNS | 5.0 | Both nodes Native (read-write), shared PostgreSQL HA backend |
| Traefik | 3.6 | Reverse proxy, DNS-01 ACME via PowerDNS API |
| PostgreSQL | 18 | Streaming replication via repmgr 5.5, auto-failover |
| NetBird | 0.69.0 | Combined management+signal+relay, PostgreSQL backend, active-passive DNS |
| NetBird Reverse Proxy | 0.69.0 (beta) | Public HTTPS ingress to NetBird-mesh services. Sits behind Traefik in TCP-passthrough mode at `*.proxy.<domain>`; terminates TLS itself with ACME TLS-ALPN-01. Auth (OIDC/password/PIN/header/IP allowlist/none) configured per-service in dashboard. |
| Zitadel | 4.12.3 | Central IAM (OIDC/OAuth2), PostgreSQL backend, multi-tenant |
| Gatus | 5.14.0 | HA monitoring dashboard + alert receiver, PostgreSQL backend |
| OpenZiti | 1.4.1 | Zero-trust network overlay, active-standby controller, active-active edge routers |
| Portainer | 2.39.0 | Docker management UI, WireGuard + NetBird access |
| Restic | 0.16.4 | Incremental backup to SFTP backup server |

### Maintenance Automation

| Component | Schedule | Description |
|-----------|----------|-------------|
| Docker cleanup | Weekly (Sun 4AM) | Prunes unused images, containers, networks, build cache |
| PostgreSQL maintenance | Weekly (Sun 3AM) | VACUUM ANALYZE + REINDEX SYSTEM on all databases |
| Disk monitoring | Hourly | Checks disk usage, alerts via webhook at 80%/90% thresholds |
| Restic cache cleanup | Weekly (Sun, with backup) | Cleans stale Restic cache entries |
| Journal rotation | Automatic | systemd journal capped at 500MB, 4-week retention |

### Alerting

All infrastructure alerts flow through **Gatus** (HA monitoring dashboard at `status.platform_domain`). Gatus receives push events from all services and forwards to configured notification targets (Slack, Discord, ntfy, email, Telegram, PagerDuty, etc.).

| Service | Events | Level |
|---------|--------|-------|
| `backup` | Backup failed, unexpected error | critical |
| `disk` | Filesystem 80%+ full | warning/critical |
| `docker` | Cleanup script failed | critical |
| `postgresql` | VACUUM/REINDEX failed, replication slot lag >5GB, inactive slot | warning |
| `repmgr` | Node started as primary/standby, failback detected, promotion, split-brain detected, self-demotion | info/warning/critical |

Host-side scripts use a shared library (`/usr/local/lib/platform-alert.sh`) that pushes to the local Gatus instance; the PostgreSQL container uses an inline implementation via `GATUS_URL`/`GATUS_TOKEN` env vars. A raw `alert_webhook_url` fallback exists for non-Gatus setups.

Gatus also performs **active monitoring**: DNS resolution on both servers, Traefik HTTPS, and Zitadel health checks.

---

## 3. How to Deploy

```bash
cd ansible

# Full deploy (phases 1-4: backbone → primary → secondary → peers)
ansible-playbook -i inventory/hosts.yml site.yml

# Phase-specific deployment
ansible-playbook -i inventory/hosts.yml site.yml --tags phase1   # Infrastructure backbone
ansible-playbook -i inventory/hosts.yml site.yml --tags phase2   # Services on primary (ns1)
ansible-playbook -i inventory/hosts.yml site.yml --tags phase3   # Services on secondary (ns2)
ansible-playbook -i inventory/hosts.yml site.yml --tags phase4   # NetBird peers

# Service-specific deployment (deploys primary first, then secondary)
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml       # Traefik only
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml    # PostgreSQL HA only
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml      # PowerDNS only
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml       # NetBird management
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml # NetBird peers
ansible-playbook -i inventory/hosts.yml deploy-netbird-ha.yml    # Traefik + PG + DNS + NetBird
ansible-playbook -i inventory/hosts.yml deploy-zitadel.yml       # Zitadel IAM
ansible-playbook -i inventory/hosts.yml deploy-gatus.yml         # Gatus monitoring
ansible-playbook -i inventory/hosts.yml deploy-portainer.yml     # Portainer Docker UI
ansible-playbook -i inventory/hosts.yml deploy-backup.yml        # Backup only
```

**Fresh deployment** uses a three-phase approach: infrastructure backbone on both
nodes, services on the primary node (ns1), then the secondary (ns2). See `docs/BOOTSTRAP.md`.

**SSH keys:** Per-server ED25519 keypairs are auto-generated in `.generated_secrets/ssh/`. The bootstrapping SSH key (`hosting-platform.key`) is only needed for the first run:
```bash
ansible-playbook -i inventory/hosts.yml site.yml --tags phase1 -e "ansible_ssh_private_key_file=$HOME/hosting-platform.key"
```
All subsequent runs use the per-server keys automatically (configured in `group_vars/all.yml`).

---

## 4. Agent Instructions

### Git

Commit every meaningful unit of work. Convention: `type(scope): summary`

Types: `feat`, `fix`, `infra`, `refactor`, `docs`, `chore`
Scopes: `ansible`, `dns`, `backup`, `auth`

Rules:
- Run from `/config/backbone/` (repo root — project home: https://github.com/insulahq/backbone)
- Never commit secrets or credentials
- Never force-push to `main`

### Decision Making

- If the implementation idea conflicts with a doc in `docs/`, ask the user first
- When tradeoffs exist, present options with pros/cons and ask
- Prefer low-cost, simple solutions
- Update AGENTS.md after significant work

---

## 5. Gotchas

Lessons from deployment. These explain **why** the code is written a specific way.

### Docker & Networking

| # | Issue | Fix |
|---|-------|-----|
| 1 | Docker `0.0.0.0` port binding bypasses nftables INPUT chain | Traffic goes through FORWARD chain |
| 2 | `flush ruleset` in nftables wipes Docker's iptables chains | Always restart Docker after nftables changes |
| 7 | Complex DNAT/SNAT/NAT rules broke server access | Keep firewall simple. Let Docker and NetBird manage their own NAT |
| 22 | Container restart in partial network state loses port forwarding | `docker compose up -d --force-recreate` to reconnect all networks |
| 85 | Docker network name derived from install directory — changing dir breaks downstream | Explicitly name networks (`postgresql_default`, `powerdns_internal`) in docker-compose.yml |

### PowerDNS

| # | Issue | Fix |
|---|-------|-----|
| 29 | `pdns_control ping` is invalid in PowerDNS 5.0 | Use `pdns_control uptime > /dev/null 2>&1` for health checks |
| 30 | `pdnsutil add-record` does NOT auto-increment SOA serial | Always run `pdnsutil increase-serial` after |
| 33 | `soa_edit_api: INCEPTION-INCREMENT` doesn't fire when serial is 0 | Manually increment serial after zone creation |
| 45 | PowerDNS `.secrets` file and API key in debug output | pdns.conf mode 0640 (group: pdns UID 953); no API key in debug msgs |
| 46 | PowerDNS `webserver-allow-from=0.0.0.0/0` | Restrict to `127.0.0.0/8,172.16.0.0/12,10.0.0.0/8` |
| 71 | `pdns.conf` mode `0600` unreadable by pdns user (UID 953) | `mode: 0640, group: 953` |

### PostgreSQL & repmgr

| # | Issue | Fix |
|---|-------|-----|
| 11 | `bitnami/postgresql-repmgr` removed from registries | Use `sourcemation/postgres-repmgr:5.5.0` (PG18 + repmgr 5.5) |
| 12 | Entrypoint crashes on restart ("already registered") | Custom `entrypoint-wrapper.sh` with `--force` flag |
| 13 | Docker hairpin NAT: container can't reach its own forwarded port | `extra_hosts`: own hostname → 127.0.0.1, peer → WireGuard IP |
| 14 | pg_hba.conf blocks Docker bridge networks | Add `host all all 172.16.0.0/12 scram-sha-256` |
| 20 | Stale `postmaster.pid` after unclean stop | Entrypoint wrapper cleans PID + socket files on startup |
| 37 | repmgrd `conninfo` with `host=127.0.0.1` masked failures | Cross-wire via extra_hosts: peer sees real WireGuard IP |
| 41 | `promote_command` used `/usr/bin/repmgr` (doesn't exist) | Use `$(which repmgr)` — actual path is `/usr/lib/postgresql/18/bin/repmgr` |
| 43 | PostgreSQL on `0.0.0.0` with `trust` auth | Bind to WireGuard IP only, `scram-sha-256` for all pg_hba entries |
| 49 | Entrypoint blindly trusted `REPMGR_ROLE` env var — split-brain after failover | `determine_role()` queries peer + compares timelines; `promote-check.sh` validates connectivity; runtime watchdog self-demotes lower timeline; `.demoted` marker survives restarts |
| 57 | Replication slots hold WAL indefinitely when standby offline | `max_slot_wal_keep_size = 10GB`; standby re-clones if behind |
| 67 | `set -e` + `[ -e "$f" ] && { cmd }` returns exit 1 when test is false | Use `if [ -e "$f" ]; then cmd; fi` instead of `&&` short-circuit |
| 68 | `determine_role()` debug on stdout polluted `$(determine_role)` capture | Redirect debug to stderr (`>&2`); only final role goes to stdout |
| 69 | `promote-check.sh` in `/usr/local/bin/` not writable by postgres user | Write to `/tmp/promote-check.sh` |
| 70 | `docker_container_exec` returns dict without `.rc` during startup | Use `pg_ready.rc \| default(1) == 0` |
| 80 | `listen_addresses` missing from `postgresql.conf` — default `localhost` | Added `listen_addresses = '*'` to `init_primary()` postgresql.conf block |
| 81 | Superuser password never set — scram-sha-256 auth fails for `postgres` | Added `ALTER USER postgres WITH PASSWORD` in `init_primary()` |
| 86 | Zitadel/Gatus `start-from-init` on PG standby — migrations need write access | Two-play pattern: PG primary node runs first, then remaining nodes |

### Traefik & ACME

| # | Issue | Fix |
|---|-------|-----|
| 74 | Traefik v3.6 filters unhealthy/starting containers from routing | Removed Docker healthcheck from netbird-server |
| 75 | Traefik can't reach PowerDNS API from inside container via host IP | Traefik joins `powerdns_internal` network; uses `http://powerdns-nginx:8081` |
| 76 | `defaultCertificate` (empty) + `defaultGeneratedCert` conflict | Removed empty `defaultCertificate` block |
| 89 | PDNS API URL via WireGuard IP relied on fragile Docker DNAT hairpin | Same as #75 — direct Docker network, no DNAT |

### NetBird

| # | Issue | Fix |
|---|-------|-----|
| 17 | NetBird IPs change on re-enrollment (fresh PG DB) | Check IPs via `netbird status --json`, update configs |
| 72 | Encryption key: 32 alphanumeric chars base64-decode to only 24 bytes | `openssl rand -base64 32` (44 chars → 32 bytes) |
| 82 | Health check uses DNS domain before record exists | Use `ansible_host` with `Host` header (same as Zitadel) |
| 84 | `config.yaml` templated before OIDC client_id created | Re-template task after OIDC app creation triggers restart handler |

### OpenZiti

| # | Issue | Fix |
|---|-------|-----|
| 136 | VPS hairpin NAT: router can't reach controller via own public IP | Router uses `network_mode: host` with `127.0.0.1` as first controller endpoint |
| 137 | Enrollment JWTs embed `edge.api.address` — if set to Traefik URL, verification fails | `edge.api.address` uses WireGuard IP:8441 (OpenZiti PKI). Traefik proxies public API separately |
| 138 | ZAC serves HTTP on port 1408, not HTTPS on 8443 | Traefik handles TLS. `ZAC_CONTROLLER_URLS` set to public domain for browser API calls |
| 139 | Router caches controller endpoint in `/openziti/router/endpoints` after enrollment | Watchdog clears file + restarts router after failover/failback so it falls back to config |
| 140 | `docker compose up -d` on standby starts stale controller container (Docker DNAT cache) | Watchdog uses `--force-recreate` to rebuild from scratch |
| 141 | `restart: unless-stopped` auto-starts standby controller on Docker daemon restart | Controller + console use `restart: "no"`. Watchdog is sole authority for lifecycle |
| 142 | OpenZiti reconnect dialer has exponential backoff — takes minutes to try second endpoint | `127.0.0.1` listed FIRST in `ctrl.endpoints`. Connection refused (fast) vs i/o timeout (slow) |
| 143 | `chmod -R 777` on controller DB dir / `chmod -R a+r` on PKI | Container UID 2171 (ziggy). Keys `0640 root:2171`, DB `0750 2171:2171`, configs `0640 root:2171` |
| 144 | Admin password baked into bootstrap.sh and enroll-router.sh | Scripts deployed mode 0700, template tasks have `no_log: true` |
| 145 | Failback synced DB while peer controller still writing (TOCTOU) | Stop peer controller FIRST, then rsync. Controller quiesced = safe copy |
| 146 | `openziti/zac` has no version-specific tags | Pinned to `:latest` with comment. All other images use `{{ openziti_version }}` |
| 147 | pg-maintenance.sh `CONTAINER` var was Gatus alert name, not Docker container | Renamed to `PG_CONTAINER="postgresql"` and `ALERT_NAME="PG-Maintenance-OK"` |

### Backup

| # | Issue | Fix |
|---|-------|-----|
| 5 | Restic `--group-by "host"` causes snapshot conflicts | Use `--group-by "host,paths"` |
| 9 | NetBird SSH config intercepts all SSH connections | Backup script uses `-F /dev/null` in SFTP args |
| 10 | Wrong restic password corrupts repo permanently | Wipe ALL files before re-init |
| 42 | `ProtectSystem=strict` blocks restic reading `/opt/*` | Use `ProtectSystem=full` |

### Security & Secrets

| # | Issue | Fix |
|---|-------|-----|
| 44 | `lookup('password', '/dev/null')` regenerates secrets each run | Use `lookup('password', 'path/to/file')` to persist |
| 47 | Docker images unpinned (`latest` tags) | Pin all images to specific versions |
| 65 | Single shared SSH key for all servers | Per-server ED25519 keypairs in `.generated_secrets/ssh/` |

### IPv6

| # | Issue | Fix |
|---|-------|-----|
| 50 | PowerDNS `local-address=0.0.0.0` — IPv4 only | Changed to `0.0.0.0, ::` with `[::]:53` port bindings |
| 51 | Traefik ports IPv4 only, Docker network IPv4-only | `[::]:80/443` bindings, dual-stack IPAM with ULA subnet |
| 52 | No AAAA DNS records in default config | AAAA template in `all.example.yml`, `public_ipv6` in inventory |
| 53 | `pg_hba.conf` only allowed IPv4 Docker CIDRs | Added `fd00::/8` (Docker ULA) |
| 54 | Promote-check only tested IPv4 DNS resolvers | Added `2001:4860:4860::8888` and `2606:4700:4700::1111` |
| 55 | NetBird STUN port bound to IPv4 only | Added `[::]:3478` binding |
| 56 | NetBird trusted proxy list IPv4 only | Added Traefik IPv6 container address |
| 66 | Docker ULA subnets used non-hex labels (`fd00:traefik::`) | Proper ULA: `fd00:dead:beef:1::/112`, `fd00:dead:beef:2::/112` |

### Disk & Data Growth

| # | Issue | Fix |
|---|-------|-----|
| 58 | PowerDNS containers had no log limits | `json-file` driver with `max-size: 100m, max-file: 2` |
| 59 | No Docker daemon.json — unlimited logs | `daemon.json` with default `max-size: 100m, max-file: 3` |
| 60 | No Docker image cleanup — old images accumulate | Weekly `docker-cleanup.timer` |
| 61 | systemd journal grows unbounded | `SystemMaxUse=500M`, `MaxRetentionSec=4week` |
| 62 | No disk space alerting | `disk-monitor.timer` (hourly): warns 80%, critical 90% |
| 63 | All DB tables lack scheduled maintenance | Weekly `pg-maintenance.timer`: VACUUM ANALYZE + REINDEX |
| 64 | Restic cache grows indefinitely | Weekly `restic cache --cleanup` in backup script |

### Ansible & Control Machine

| # | Issue | Fix |
|---|-------|-----|
| 73 | `ansible.cfg` ignored in world-writable directories | `chmod 755` on project directory |
| 83 | fail2ban `logpath = /var/log/auth.log` — doesn't exist on Debian 13 | `backend = systemd` with `journalmatch` |
| 87 | `community.docker.docker_network` needs `python3-docker` | Added to common role base packages |
| 88 | `wg genkey` on controller — missing `wireguard-tools` | Pre-check task with clear error message and install instructions |
| 90 | `apt update` with `cache_valid_time: 3600` trusts stale the provider image cache — packages not found | Removed `cache_valid_time`; always refresh on first run |

### PowerDNS Deployment

| # | Issue | Fix |
|---|-------|-----|
| 91 | Schema init task silently skipped — `docker_container_exec` with YAML `>` folding + psql had parsing issues; condition evaluated wrong | Rewrote to use `bash -c` wrapper; inverted condition to check for `"1"` (schema exists) instead of empty string |
| 92 | `run_once: true` on zone/record creation tasks ran on first inventory host (ns1 = PG standby); all writes failed on read-only DB | Changed to `when: inventory_hostname == postgresql_primary_node` for all write operations |
| 93 | `powerdns_internal` network declared as compose-managed but pre-created by Traefik role; Docker Compose rejected mismatched labels | Changed to `external: true` in PowerDNS compose; Traefik role creates the network |

### Traefik & ACME (continued)

| # | Issue | Fix |
|---|-------|-----|
| 94 | `PDNS_API_KEY` empty in Traefik compose — PowerDNS role sets the key via `set_fact` at runtime, but Traefik role doesn't load it | Added task to load API key from `.generated_secrets/powerdns_api_key` in Traefik role |
| 95 | ACME on PG standby node — local PowerDNS can't write TXT challenge records (read-only PG) | Standby node's Traefik uses primary node's PowerDNS API via WireGuard IP |
| 96 | ACME `could not determine authoritative nameservers` — Traefik's propagation check failed to resolve NS chain | Added `dnschallenge.resolvers=8.8.8.8:53,1.1.1.1:53` to use public DNS for propagation checks |

### Zitadel

| # | Issue | Fix |
|---|-------|-----|
| 97 | Zitadel v2.65–v2.71 migration 34 creates `UNLOGGED` partitioned table — PostgreSQL 18 doesn't support this | Upgraded to Zitadel v4.12.3 which handles PG 18 correctly |
| 98 | `config.yaml` and `steps.yaml` deployed with mode `0600` — Zitadel container runs as non-root and can't read them | Changed to mode `0644` (same pattern as PowerDNS gotcha 71) |
| 99 | Admin password generated with `chars=ascii_letters,digits` — Zitadel requires at least one symbol | Changed to `chars=ascii_letters,digits,punctuation` |
| 100 | Docker healthcheck (`/app/zitadel ready`) fails during init/migration — Traefik permanently excludes container from routing | Removed Docker healthcheck (same pattern as gotcha 74) |
| 101 | Zitadel v4 listens on plain HTTP behind Traefik but defaults to expecting TLS; `h2c` backend scheme caused routing failures | Added `--tlsMode external` flag; removed `h2c` scheme from Traefik service label |
| 102 | Login V2 UI requires a Login Client service user + `ZITADEL_SERVICE_USER_TOKEN` env var — without it, `/ui/v2/login/` returns 404; catch-22: can't create the user without a working login | Disabled Login V2 (`DefaultInstance.Features.LoginV2.Required: false`); v1 login works out of the box |
| 103 | OIDC project search in all roles hardcoded project name `"Hosting Platform"` — user created `"Hosting Apps"` | Removed — automated OIDC app creation removed; OIDC configured manually post-deploy |
| 104 | OIDC app creation returned `409 Conflict` (already exists) on re-run — task failed instead of succeeding idempotently | Removed — automated OIDC app creation removed; OIDC configured manually post-deploy |

### NetBird

| # | Issue | Fix |
|---|-------|-----|
| 105 | NetBird v0.66+ uses embedded Dex IdP for local auth — config pointed `auth.issuer` to Zitadel, causing JWKS mismatch (tokens signed by Zitadel, validated against embedded Dex keys) | Changed `issuer` to `https://vpn.<domain>/oauth2` (embedded IdP endpoint); Zitadel added as external IdP via dashboard UI |
| 106 | `/oauth2` path missing from Traefik backend router — embedded Dex endpoint caught by dashboard nginx (priority 1) which returned HTML instead of OIDC JSON | Added `PathPrefix(\`/oauth2\`)` to the `netbird-backend` Traefik router rule |
| 107 | Dashboard `OidcTrustedDomains.js` template only includes management endpoint — OIDC service worker blocks callbacks from untrusted auth domain | Template needs auth authority domain added (ephemeral fix; permanent fix requires custom template in role) |
| 108 | Dashboard nginx `try_files $uri $uri.html $uri/ =404` — SPA callback routes `/nb-auth` and `/nb-silent-auth` have no static files; returns 404 on OIDC redirect back | Needs nginx config override to `try_files $uri $uri.html $uri/ /index.html` (ephemeral fix on container restart) |
| 109 | `dnsDomain` missing from `config.yaml` — defaults to `netbird.selfhosted` instead of configured value | Added `dnsDomain: "{{ netbird_peer_dns_domain }}"` to config template; existing accounts need DB update (`settings_dns_domain`) |
| 110 | Zitadel access tokens are opaque by default — NetBird management server can't validate non-JWT tokens (`token is malformed: invalid number of segments`) | Set `accessTokenType: OIDC_TOKEN_TYPE_JWT` on the OIDC app via Zitadel API (only relevant if Zitadel is used as external IdP) |
| 111 | `idp.db` (embedded Dex user credentials) stored as SQLite in Docker volume — not replicated via PostgreSQL; logins fail on the node missing it | **Resolved**: `authStore` config (v0.66.1+) points embedded Dex at PostgreSQL HA cluster; `activityStore` also migrated. Dex uses lib/pq (no multi-host DSN) — same pattern as Gatus gotcha #119 |

### Portainer

| # | Issue | Fix |
|---|-------|-----|
| 112 | Docker healthcheck uses `wget` which doesn't exist in Portainer CE image — container permanently shows `unhealthy` | Removed Docker healthcheck (same pattern as gotcha 74) |
| 113 | Portainer admin creation times out after 5 minutes — instance locks and requires restart | Document in BOOTSTRAP.md; restart container to reset the window |
| 114 | Portainer bound to WireGuard IP only — not reachable via NetBird mesh | Changed to `0.0.0.0` binding; nftables FORWARD chain drops port 9000 from public interfaces (allows `wg0`, `wt0`, `lo` only) |

### DNS Failover

| # | Issue | Fix |
|---|-------|-----|
| 115 | `ifportup(443)` only checks if Traefik port is open — backend service (Zitadel, NetBird, Gatus) could be dead while Traefik serves 502s | Replaced with `ifurlup()` for service domains — checks actual health endpoints (`/debug/ready`, `/api/instance`, `/health`). Base domain keeps `ifportup(443)` since Traefik being up is the correct check |
| 116 | `selector='all'` round-robin returns both IPs equally — no primary/backup preference | Changed to priority groups `{ {ns1}, {ns2} }` — PowerDNS returns first group with a healthy member. `dns_failover_primary` (default: `ns1`) controls preference |
| 117 | Jinja2 `{{` conflicts with Lua table-of-tables syntax `{{'ip'}, {'ip'}}` | Use `{ {'ip'}, {'ip'} }` with spaces — Lua ignores whitespace in tables, Jinja2 only interprets `{{` (no space) as expression delimiter |

### Zitadel

| # | Issue | Fix |
|---|-------|-----|
| 118 | Zitadel connects to local `postgresql` (Docker DNS) — fails on standby node (read-only) | Multi-host `Host: postgresql,<peer_wg_ip>` + `PGTARGETSESSIONATTRS=read-write` env var; pgx skips read-only hosts |

### Gatus

| # | Issue | Fix |
|---|-------|-----|
| 119 | Gatus DSN uses single-host `@postgresql:5432` — fails on standby node (read-only) | Gatus uses `lib/pq` which doesn't support `target_session_attrs` or multi-host DSN; primary connects via Docker DNS, standby connects to primary via WireGuard IP |

### PowerDNS (continued)

| # | Issue | Fix |
|---|-------|-----|
| 120 | Schema check `WHERE table_name='domains'` matched `information_schema.domains` (PG built-in) — schema init skipped, PowerDNS gets "relation does not exist" | Added `table_schema='public'` filter to schema check query |
| 121 | `GRANT` statements in `init-schema.sql` only execute on first creation — skipped when schema check finds existing tables | Added unconditional `GRANT` task that runs every time |
| 122 | `docker cp` into PG container creates root-owned files in `/tmp` — `psql` can't read them (sticky bit) | Pipe SQL via `stdin` instead of file copy |
| 123 | `pda-legacy` ignores `PORT` env var — always listens on 8000, nginx proxied to 9191 | Hardcoded port 8000 in nginx upstream |
| 124 | `pda-legacy` ignores individual `SQLA_DB_*` env vars — falls back to SQLite | Use `SQLALCHEMY_DATABASE_URI` with full PostgreSQL connection string |
| 125 | PDA on standby node fails — writes to local read-only PG | Standby PDA connects to primary PG via WireGuard IP (same as Gatus) |
| 126 | `powerdns-nginx` healthcheck hits API endpoint requiring auth — always unhealthy | Changed healthcheck to `wget http://localhost:8081/` (root path, no auth needed) |

### Traefik & ACME (continued)

| # | Issue | Fix |
|---|-------|-----|
| 127 | ACME propagation check queries all authoritative NS servers — fails when ns2 DNS isn't running yet | Added `disablepropagationcheck=true` to Traefik ACME config |
| 128 | Stale `_acme-challenge` TXT records from failed attempts cause "Incorrect TXT record" errors | Clean up TXT records before retrying; records auto-managed by Traefik |

### Traefik Rate Limiting

| # | Issue | Fix |
|---|-------|-----|
| 129 | Rate limit middleware defined via Docker labels on Traefik container — Traefik doesn't read its own labels | Define middleware in `dynamic.yml` file provider; reference as `ratelimit@file` |

### DNS Failover

| # | Issue | Fix |
|---|-------|-----|
| 130 | LUA `ifportup()`/`ifurlup()` fails inside Docker — hairpin NAT prevents container from reaching host's own forwarded ports | Use static active-passive DNS (primary IP only); `dns_health_check_enabled` defaults to `false` |
| 131 | Active-passive DNS means single IP during normal operation — failover switches to surviving node | pg-role-watchdog detects role change and calls platform-dns-switch within 10s |

### Zitadel

| # | Issue | Fix |
|---|-------|-----|
| 132 | Auto-generated admin password with `punctuation` chars breaks YAML double-quote escaping in `steps.yaml` — Human user silently not created | Use `\| to_json` filter for password in template; append `!1Ax` suffix for complexity policy |
| 133 | `lookup('password')` writes base password to file but Jinja2 `+ '!1Ax'` suffix only exists in memory — secrets file has wrong password | Added separate `copy` task to persist full password (including suffix) to `.generated_secrets/` |

### NetBird

| # | Issue | Fix |
|---|-------|-----|
| 134 | External IdP (Zitadel OIDC) login creates new orphan account — NetBird matches by IdP user ID, not email | Must invite user via NetBird Team settings before OIDC login; or enable "Check authorization on authentication" in Zitadel project |
| 135 | `idp.db` sync via raw SSH from controller fails — controller not on WireGuard network | **Obsolete**: idp.db sync removed — embedded Dex now uses PostgreSQL HA via `authStore` config |
| 136 | **Split-signal mesh isolation** — after management container restart + DNS failover, NetBird peer clients reconnect to the standby's signal server while external peers stay on the primary's signal server. Signal state is per-instance (not replicated), so peers on different signal servers cannot exchange ICE offers. Symptoms: `SentOffer` count climbs to thousands, `RemoteOffer` stays near zero, peers stuck in `Connecting` forever. | `pg-role-watchdog.sh` now restarts `netbird.service` (peer client) on every role change. Hourly `netbird-signal-check.timer` compares actual signal connection IP against PG-derived primary IP and restarts on mismatch. The watchdog also restarts `netbird-server` (management container) on the standby, flushing stale external peer sessions. **Superseded 2026-07 by fencing (gotcha 149)**: netbird-server runs ONLY on the PG primary, so a second signal server no longer exists to split against. Peer-client restart on role change + hourly signal-check retained as defense in depth. |
| 148 | **External peers strand after every netbird-server restart** (gotcha #136 follow-on). NetBird signal-state is in-memory in netbird-server. Any restart wipes it — and netbird-server MUST restart on PG failover because both its connection pools (pgx + lib-pq via GORM) cache stale connections to the ex-primary for up to 60 minutes (`MaxConnLifetime`) with no `PrepareConn`/`BeforeAcquire` validation hooks (verified in v0.69.0 source `management/server/store/sql_store.go:62-147,2794-2835`). Empirically observed during 2026-04-25 destructive failover test: `ValidateConnect failed (read only connection)` in netbird-server logs, three external customer peers stranded for 3+ hours. **Affected events**: destructive failover test, server reboot, hardware outage, image upgrade, any container restart. **Local peers (ns1/ns2) recover** via the watchdog's `systemctl restart netbird`. **External peers (anything not ns1/ns2)** retain stale signal sessions and need manual `sudo netbird down && sudo netbird up` on each affected machine — there is no remote way to kick them. The watchdog now invokes `/usr/local/bin/netbird-peer-wakeup.sh` after every role change: pings each peer's NetBird IP from ns1/ns2 (forces an ICE offer from our side via signal — recovers ~50% of cases), then alerts via Gatus `NetBird-Mesh-Peers-Healthy` for any still-stale peers. **Operator runbook**: after any planned netbird-server restart, monitor the `NetBird-Mesh-Peers-Healthy` Gatus endpoint and notify owners of any flagged peers to bounce their daemon. **Update 2026-07 — three structural fixes shrink this class**: (1) netbird-server no longer restarts on PG failover — the watchdog fences it to the primary (gotcha 149) and it starts FRESH on the new primary after pgproxy retarget, so its pools cannot poison and signal state is only wiped when all clients must reconnect anyway; (2) pgproxy kills orphaned per-connection socat children on target change (with `fork`, children survive the parent kill and kept proxying pooled consumer connections to the read-only ex-primary — the original poisoning path); (3) peers run a client-side self-heal guard (`netbird-selfheal.timer`, deployed by the netbird_peer role; for unmanaged customer machines `scripts/` has per-platform variants — `netbird-selfheal-install.sh` for systemd Linux, `netbird-selfheal-install.ps1` for Windows Scheduled Task, `netbird-selfheal-docker.sh` for cron + containerized clients, `netbird-selfheal-compose.example.yml` for compose-only healthcheck+autoheal) that performs the `netbird down && up` cycle (or `docker restart`) automatically after ~6 min of management/signal disconnect — the only mechanism that recovers external peers after a hard primary failure. Wake-up ping + Gatus alert remain for unguarded peers; `netbird-peer-health.sh` now prefers the management API (`netbird_admin_pat`) for authoritative stranded-peer lists (`connected` + `last_seen` per peer). |
| 149 | **netbird-server + netbird-proxy are intentionally STOPPED on the PG standby** (fencing). NetBird signal state is per-instance and in-memory — a standby that accepts client connections re-opens the split-signal trap (gotcha 136) for any client with stale DNS. A stopped container also drops the standby's Traefik netbird routes, so a stale client gets an immediate failure → redials → 30s-TTL DNS → primary. | Enforced by `enforce_netbird_fence()` in `pg-role-watchdog.sh` every cycle: stop on standby, start on primary AFTER pgproxy retarget (starting earlier would poison the activity-store pool via the stale pgproxy target). `docker start netbird-server` on the standby gets reverted within ~30s — self-healing, not a malfunction. Because of `restart: unless-stopped`, a fenced container stays stopped across reboots: ONLY the watchdog starts netbird-server on promotion. Deploy roles (netbird_management, netbird_proxy) and rolling-update.yml fence inline post-`compose up` to close the 30s window. Do not "fix" a stopped netbird-server/netbird-proxy without checking `pg_is_in_recovery()` first. Test suite asserts running-on-primary/stopped-on-standby. **Accepted trade-off**: on every failover there is a short window (bounded by the two nodes' uncoordinated 30s watchdog timers + the ~7s pgproxy retarget wait) with no netbird-server running anywhere — clients just retry and land on the new primary; this replaces the far worse silent split-signal stranding. |

---

## 6. Repository Structure

```
backbone/
├── AGENTS.md              # This file
├── README.md              # Project overview
├── scripts/                         # Self-heal guard installers for unmanaged NetBird peers
│   ├── netbird-selfheal-install.sh  # Linux (systemd timer)
│   ├── netbird-selfheal-install.ps1 # Windows (Scheduled Task)
│   ├── netbird-selfheal-docker.sh   # Containerized client, host cron + docker restart
│   └── netbird-selfheal-compose.example.yml  # Compose-only: healthcheck + autoheal
├── .gitignore
├── .pre-commit-config.yaml # Pre-commit hooks (gitleaks, yamllint, ansible-lint)
├── .github/
│   ├── pull_request_template.md
│   ├── ISSUE_TEMPLATE/
│   └── workflows/
│       └── ansible-lint.yml  # CI: lint + syntax-check + secrets scan
├── ansible/
│   ├── ansible.cfg
│   ├── .ansible-lint        # ansible-lint config (matches CI)
│   ├── .yamllint            # yamllint config
│   ├── requirements.yml     # Ansible Galaxy collection dependencies
│   ├── README.md
│   ├── site.yml             # Main playbook (tagged plays)
│   ├── test-suite.yml       # System test suite (post-deploy verification)
│   ├── _ssh-keys.yml        # Shared SSH key generation pre-play (imported by all playbooks)
│   ├── deploy-*.yml         # Targeted playbooks
│   ├── inventory/
│   │   └── hosts.yml        # Server inventory (gitignored)
│   ├── .generated_secrets/  # Auto-generated passwords + SSH keys (gitignored)
│   │   └── ssh/             # Per-server ED25519 keypairs (ns1, ns1.pub, etc.)
│   ├── group_vars/
│   │   └── all.yml          # Global variables (gitignored)
│   ├── host_vars/
│   │   ├── ns1.yml
│   │   └── ns2.yml
│   └── roles/
│       ├── common/            # OS hardening, nftables, Docker, fail2ban
│       ├── wireguard/         # WireGuard infrastructure tunnel (zero-dep backbone)
│       ├── powerdns/          # PowerDNS (both nodes, shared PostgreSQL HA)
│       ├── traefik/           # Traefik v3.6 reverse proxy
│       ├── postgresql_repmgr/ # PostgreSQL 18 + repmgr HA
│       ├── netbird_management/# NetBird combined server (Zitadel auth)
│       ├── netbird_peer/      # NetBird peer enrollment
│       ├── zitadel/           # Zitadel IAM (OIDC/OAuth2, multi-tenant)
│       ├── gatus/             # Gatus monitoring (HA dashboard + alert receiver)
│       ├── portainer/         # Portainer CE Docker management (WireGuard-only)
│       └── backup/            # Restic backup (with logrotate + notifications)
└── docs/
    ├── BOOTSTRAP.md               # Fresh deployment procedure
    ├── RECOVERY.md                # Disaster recovery runbook
    └── DISPERSED_DNS_ARCHITECTURE.md
```

---

## 7. Tags

All plays and tasks are tagged for selective execution:

```bash
# Run only common (OS hardening, Docker)
ansible-playbook -i inventory/hosts.yml site.yml --tags common

# Run only Docker-related tasks within common
ansible-playbook -i inventory/hosts.yml site.yml --tags docker

# Run only firewall tasks
ansible-playbook -i inventory/hosts.yml site.yml --tags firewall

# Other available tags: traefik, postgresql, powerdns, dns,
#   netbird, netbird_management, netbird_peer, zitadel, gatus,
#   portainer, backup, security, ssh, fail2ban, packages, maintenance
```

---

## 8. Testing

### System Test Suite (post-deploy)
```bash
# All non-destructive tests (DNS, TLS, PG, NetBird, Zitadel, OIDC, Gatus, Portainer, backup, maintenance)
ansible-playbook -i inventory/hosts.yml test-suite.yml

# Specific test groups
ansible-playbook -i inventory/hosts.yml test-suite.yml --tags dns
ansible-playbook -i inventory/hosts.yml test-suite.yml --tags postgresql
# Destructive failover tests (stops services temporarily, then restores)
ansible-playbook -i inventory/hosts.yml test-suite.yml --tags failover
```

Tags: `dns`, `tls`, `postgresql`, `netbird`, `zitadel`, `gatus`, `portainer`,
`backup`, `maintenance`, `cross_node`, `failover`

Prints a pass/fail summary table and exits non-zero on any failure (CI-compatible).

Failover tests (destructive, opt-in via `--tags failover`):
- DNS LUA failover — stops Traefik, verifies `ifportup()` excludes dead node, restores
- PostgreSQL HA — stops primary, waits for repmgrd promotion, tests writes, verifies rejoin
- NetBird management — stops management server, verifies API via surviving node, restores
- Zitadel IAM — stops Zitadel, verifies health on surviving node, restores
- Full node outage — stops all services on one node, verifies DNS/PG/Gatus on survivor, restores all

### Ansible Lint (CI)
```bash
ansible-lint -c ansible/.ansible-lint ansible/
```

### Molecule (local)
```bash
pip install molecule molecule-plugins[docker]
cd ansible/roles/common && molecule test
cd ansible/roles/postgresql_repmgr && molecule test
cd ansible/roles/backup && molecule test
```

### Pre-commit Hooks
```bash
pip install pre-commit
pre-commit install
pre-commit run --all-files
```

---

## 9. Do NOT

- Do not commit secrets, tokens, passwords, or IP addresses
- Do not use complex nftables NAT rules (gotcha 7)
- Do not use `bitnami/postgresql-repmgr` (removed from registries, gotcha 11)
- Do not hardcode `/usr/bin/repmgr` (wrong path, gotcha 41)
- Do not use `lookup('password', '/dev/null')` — secrets regenerate each run (gotcha 44)
- Do not use `latest` tags for Docker images (gotcha 47)
- Do not expose PostgreSQL on `0.0.0.0` — bind to WireGuard IP only (gotcha 43)
- Do not force-push to `main` without explicit user approval
- Do not use `pull: always` in docker_compose_v2 tasks — use `pull: missing` (wasteful re-downloads)
- Do not change the Zitadel masterkey after initialization — it cannot be rotated (encrypted data becomes inaccessible)
- Do not remove stale keys from `authorized_keys` during bootstrap — the bootstrapping SSH key and any provider-provisioned keys must remain as recovery fallbacks; per-server keys are added alongside existing keys (`exclusive: false`)
