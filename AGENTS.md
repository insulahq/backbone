# AGENTS.md -- Phoenix Host Infrastructure

> **Read this file first.** Single entry point for any agent or developer resuming work.

---

## 1. What This Is

Ansible automation for deploying two fully redundant DNS + VPN mesh servers on Hetzner. This is the infrastructure foundation for a web hosting platform (Phoenix Host). The hosting platform itself (API, panels, workloads) is built separately on top of this infrastructure.

**Scope:** Two Debian 13 servers running PowerDNS, Traefik, PostgreSQL HA, NetBird VPN mesh, and Restic backups.

**Servers:**

| Server | Location | Role |
|--------|----------|------|
| ns1 | Hetzner Falkenstein | PowerDNS (read-write), NetBird management, PostgreSQL standby |
| ns2 | Hetzner Helsinki | PowerDNS (read-write), NetBird management, PostgreSQL primary |

PostgreSQL primary/standby swapped after NS1 failure on 2026-03-13 (repmgrd promoted NS2).

---

## 2. Components

| Component | Version | Description |
|-----------|---------|-------------|
| OS | Debian 13 | Hardened with nftables + fail2ban |
| PowerDNS | 4.9 | Both nodes Native (read-write), shared PostgreSQL HA backend |
| Traefik | 3.6 | Reverse proxy, DNS-01 ACME via PowerDNS API |
| PostgreSQL | 18 | Streaming replication via repmgr 5.5, auto-failover |
| NetBird | 0.66.4 | Combined management+signal+relay, PostgreSQL backend, round-robin DNS |
| Zitadel | 2.71.0 | Central IAM (OIDC/OAuth2), PostgreSQL backend, multi-tenant |
| Restic | 0.16.4 | Incremental backup to Hetzner Storagebox |

### Maintenance Automation

| Component | Schedule | Description |
|-----------|----------|-------------|
| Docker cleanup | Weekly (Sun 4AM) | Prunes unused images, containers, networks, build cache |
| PostgreSQL maintenance | Weekly (Sun 3AM) | VACUUM ANALYZE + REINDEX SYSTEM on all databases |
| Disk monitoring | Hourly | Checks disk usage, alerts via webhook at 80%/90% thresholds |
| Restic cache cleanup | Weekly (Sun, with backup) | Cleans stale Restic cache entries |
| Journal rotation | Automatic | systemd journal capped at 500MB, 4-week retention |

### Alerting

All infrastructure alerts flow through a single `alert_webhook_url` (set in `group_vars/all.yml`). Every alert is a JSON POST with a consistent payload:

```json
{ "host": "ns1", "service": "backup", "level": "critical", "message": "...", "timestamp": "..." }
```

| Service | Events | Level |
|---------|--------|-------|
| `backup` | Backup failed, unexpected error | critical |
| `disk` | Filesystem 80%+ full | warning/critical |
| `docker` | Cleanup script failed | critical |
| `postgresql` | VACUUM/REINDEX failed, replication slot lag >5GB, inactive slot | warning |
| `repmgr` | Node started as primary/standby, failback detected, promotion, split-brain detected, self-demotion | info/warning/critical |

Compatible with: ntfy, Slack, Discord, Uptime Kuma, Grafana OnCall, PagerDuty, or any JSON POST endpoint. Host-side scripts use a shared library (`/usr/local/lib/phoenix-alert.sh`); the PostgreSQL container uses an inline implementation via `ALERT_WEBHOOK_URL` env var.

---

## 3. How to Deploy

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml                 # Everything
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml       # Traefik only
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml    # PostgreSQL HA only
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml      # PowerDNS only
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml       # NetBird management
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml # NetBird peers
ansible-playbook -i inventory/hosts.yml deploy-netbird-ha.yml    # Traefik + PG + DNS + NetBird
ansible-playbook -i inventory/hosts.yml deploy-zitadel.yml       # Zitadel IAM
ansible-playbook -i inventory/hosts.yml deploy-backup.yml        # Backup only
```

**Fresh deployment requires multiple runs** due to circular dependencies (NetBird needs Traefik certs, Traefik needs PowerDNS API, PowerDNS nginx binds to NetBird IP). See `docs/BOOTSTRAP.md`.

---

## 4. Agent Instructions

### Git

Commit every meaningful unit of work. Convention: `type(scope): summary`

Types: `feat`, `fix`, `infra`, `refactor`, `docs`, `chore`
Scopes: `ansible`, `dns`, `backup`, `auth`

Rules:
- Run from `/config/hosting-platform/` (repo root)
- Never commit secrets or credentials
- Never force-push to `main`

### Decision Making

- If the implementation idea conflicts with a doc in `docs/`, ask the user first
- When tradeoffs exist, present options with pros/cons and ask
- Prefer low-cost, simple solutions
- Update AGENTS.md after significant work

---

## 5. Critical Gotchas

Hard-won lessons from deployment. These **will** bite you if ignored.

### Docker & Networking

| # | Issue | Fix |
|---|-------|-----|
| 1 | Docker `0.0.0.0` port binding bypasses nftables INPUT chain | Traffic goes through FORWARD chain |
| 2 | `flush ruleset` in nftables wipes Docker's iptables chains | Always restart Docker after nftables changes |
| 7 | Complex DNAT/SNAT/NAT rules broke server access | Keep firewall simple. Let Docker and NetBird manage their own NAT |
| 22 | Container restart in partial network state loses port forwarding | `docker compose up -d --force-recreate` to reconnect all networks |

### PowerDNS

| # | Issue | Fix |
|---|-------|-----|
| 29 | `pdns_control ping` is invalid in PowerDNS 4.9 | Use `pdns_control uptime > /dev/null 2>&1` for health checks |
| 30 | `pdnsutil add-record` does NOT auto-increment SOA serial | Always run `pdnsutil increase-serial` after |
| 33 | `soa_edit_api: INCEPTION-INCREMENT` doesn't fire when serial is 0 | Manually increment serial after zone creation |

### PostgreSQL & repmgr

| # | Issue | Fix |
|---|-------|-----|
| 11 | `bitnami/postgresql-repmgr` removed from registries | Use `sourcemation/postgres-repmgr:5.5.0` (PG18 + repmgr 5.5) |
| 12 | Entrypoint crashes on restart ("already registered") | Custom `entrypoint-wrapper.sh` with `--force` flag |
| 13 | Docker hairpin NAT: container can't reach its own forwarded port | Use `extra_hosts`: own hostname -> 127.0.0.1, peer -> NetBird IP |
| 14 | pg_hba.conf blocks Docker bridge networks | Add `host all all 172.16.0.0/12 scram-sha-256` (Docker RFC 1918) |
| 20 | Stale `postmaster.pid` after unclean stop | Entrypoint wrapper cleans PID + socket files on startup |
| 37 | repmgrd `conninfo` with `host=127.0.0.1` masked failures | Cross-wire via extra_hosts: peer sees real NetBird IP |
| 41 | `promote_command` used `/usr/bin/repmgr` (doesn't exist) | Use `$(which repmgr)` -- actual path is `/usr/lib/postgresql/18/bin/repmgr` |
| 49 | Old entrypoint wrapper blindly trusted `REPMGR_ROLE` env var — after failover, old primary restarted as primary creating split-brain | Rewritten wrapper: `determine_role()` queries peer + compares timelines on every boot; `promote-check.sh` validates connectivity before promotion; runtime watchdog detects dual-primary and self-demotes lower timeline; `.demoted` marker survives restarts |

### NetBird

| # | Issue | Fix |
|---|-------|-----|
| 17 | NetBird IPs change on re-enrollment (fresh PG DB) | Check IPs via `netbird status --json`, update all configs |
| 24 | Circular boot dependency: NetBird needs PG via WireGuard, WireGuard needs NetBird | Connect netbird-server to `postgresql_default` Docker network, use `host=postgresql` in DSN |
| 36 | Dashboard auth breaks after netbird-server restart | Clear cookies, run `netbird login` on clients |
| 38 | NS2 DSN was NS1-first, causing 30s timeout when NS1 down | Each node lists itself first in multi-host DSN |
| 39 | `idp.db` (Dex credentials) not replicated via PostgreSQL | Ansible syncs idp.db NS1->NS2 on every deploy |

### Backup

| # | Issue | Fix |
|---|-------|-----|
| 5 | Restic `--group-by "host"` causes snapshot conflicts | Use `--group-by "host,paths"` |
| 9 | NetBird SSH config intercepts all SSH connections | Backup script uses `-F /dev/null` in SFTP args |
| 10 | Wrong restic password corrupts repo permanently | Wipe ALL files before re-init |
| 42 | `ProtectSystem=strict` in systemd blocks restic reading `/opt/*` | Use `ProtectSystem=full` (protects `/usr`,`/boot` but allows `/opt` reads) |

### Security

| # | Issue | Fix |
|---|-------|-----|
| 43 | PostgreSQL 5432 on `0.0.0.0` with `trust` auth for repmgr | Bind to NetBird IP only, use `scram-sha-256` for all pg_hba entries |
| 44 | `lookup('password', '/dev/null')` regenerates secrets each run | Use `lookup('password', 'path/to/file')` to persist generated secrets |
| 45 | PowerDNS `.secrets` file and API key in debug output | Removed .secrets file; removed API key from debug msg; pdns.conf mode 0600 |
| 46 | PowerDNS `webserver-allow-from=0.0.0.0/0` | Restrict to `127.0.0.0/8,172.16.0.0/12,10.0.0.0/8` |
| 47 | Docker images unpinned (`latest` tags) | Pin: `sourcemation/postgres-repmgr:5.5.0`, `netbird-server:0.66.4`, `dashboard:v2.34.2`, `pdns-auth-49:4.9.13`, `nginx:1.27-alpine` |
| 48 | nftables `netbird_management` group check never matched (ports 443/10000 never opened) | Changed to check `dns_servers` group (both ns1 and ns2 run NetBird management) |

### Disk & Data Growth

| # | Issue | Fix |
|---|-------|-----|
| 57 | Replication slots hold WAL indefinitely when standby offline | `max_slot_wal_keep_size = 10GB` caps WAL per slot; standby re-clones if behind |
| 58 | PowerDNS containers (pdns, nginx, pdns-admin) had no log limits | Added `json-file` driver with `max-size: 100m, max-file: 2` to all containers |
| 59 | No Docker daemon.json — new containers get unlimited logs | Deploy `daemon.json` with default `max-size: 100m, max-file: 3` |
| 60 | No Docker image/container cleanup — old images accumulate | Weekly `docker-cleanup.timer` prunes images >7d, stopped containers, build cache |
| 61 | systemd journal grows unbounded (Debian default ~10% of disk) | `journald.conf.d/size-limit.conf`: `SystemMaxUse=500M`, `MaxRetentionSec=4week` |
| 62 | No disk space alerting — discover full disk when services crash | `disk-monitor.timer` (hourly): warns at 80%, critical at 90%, webhook alerts |
| 63 | Zitadel event store (append-only) + all DB tables lack scheduled maintenance | Weekly `pg-maintenance.timer`: VACUUM ANALYZE + REINDEX SYSTEM on all databases |
| 64 | Restic cache (`/var/cache/restic`) grows indefinitely | Weekly `restic cache --cleanup` runs after integrity check in backup script |

### IPv6

| # | Issue | Fix |
|---|-------|-----|
| 50 | PowerDNS `local-address=0.0.0.0` served DNS on IPv4 only | Changed to `0.0.0.0, ::` and added `[::]:53` port bindings |
| 51 | Traefik ports bound to IPv4 only, Docker network IPv4-only | Added `[::]:80/443` bindings, dual-stack IPAM with ULA subnet |
| 52 | No AAAA DNS records in default config | Added AAAA record template in `all.example.yml`, `public_ipv6` in inventory |
| 53 | `pg_hba.conf` only allowed IPv4 Docker CIDRs | Added `fd00::/8` (Docker ULA) to pg_hba rules |
| 54 | PostgreSQL promote-check only tested IPv4 DNS resolvers | Added `2001:4860:4860::8888` and `2606:4700:4700::1111` |
| 55 | NetBird STUN port bound to IPv4 only | Added explicit `[::]:3478` binding |
| 56 | NetBird trusted proxy list was IPv4 only | Added Traefik IPv6 container address to `trustedHTTPProxies` |

---

## 6. Repository Structure

```
hosting-platform/
├── AGENTS.md              # This file
├── README.md              # Project overview
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
│   ├── deploy-*.yml         # Targeted playbooks
│   ├── inventory/
│   │   └── hosts.yml        # Server inventory (gitignored)
│   ├── .generated_secrets/  # Auto-generated passwords (gitignored)
│   ├── group_vars/
│   │   └── all.yml          # Global variables (gitignored)
│   ├── host_vars/
│   │   ├── ns1.yml
│   │   └── ns2.yml
│   └── roles/
│       ├── common/            # OS hardening, nftables, Docker, fail2ban
│       ├── powerdns/          # PowerDNS (both nodes, shared PostgreSQL HA)
│       ├── traefik/           # Traefik v3.6 reverse proxy
│       ├── postgresql_repmgr/ # PostgreSQL 18 + repmgr HA
│       ├── netbird_management/# NetBird combined server
│       ├── netbird_peer/      # NetBird peer enrollment
│       ├── zitadel/           # Zitadel IAM (OIDC/OAuth2, multi-tenant)
│       └── backup/            # Restic backup (with logrotate + notifications)
└── docs/
    ├── BOOTSTRAP.md               # Fresh deployment procedure
    ├── RECOVERY.md                # Disaster recovery runbook
    ├── DISPERSED_DNS_ARCHITECTURE.md
    ├── NETBIRD_CERTIFICATE_BOOTSTRAP.md  # (partially outdated, see header)
    └── NETBIRD_SIGNAL_CORRECTION.md      # (historical, see header)
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
#   netbird, netbird_management, netbird_peer, zitadel, backup,
#   security, ssh, fail2ban, packages, maintenance
```

---

## 8. Testing

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
- Do not expose PostgreSQL on `0.0.0.0` — bind to NetBird IP only (gotcha 43)
- Do not force-push to `main` without explicit user approval
- Do not use `pull: always` in docker_compose_v2 tasks — use `pull: missing` (wasteful re-downloads)
- Do not change the Zitadel masterkey after initialization — it cannot be rotated (encrypted data becomes inaccessible)
