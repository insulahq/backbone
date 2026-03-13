# AGENTS.md -- Phoenix Host Infrastructure

> **Read this file first.** Single entry point for any agent or developer resuming work.

---

## 1. What This Is

Ansible automation for deploying two fully redundant DNS + VPN mesh servers on Hetzner. This is the infrastructure foundation for a web hosting platform (Phoenix Host). The hosting platform itself (API, panels, workloads) is built separately on top of this infrastructure.

**Scope:** Two Debian 13 servers running PowerDNS, Traefik, PostgreSQL HA, NetBird VPN mesh, and Restic backups.

**Servers:**

| Server | Location | Role |
|--------|----------|------|
| ns1 | Hetzner Falkenstein | PowerDNS primary, NetBird management, PostgreSQL standby |
| ns2 | Hetzner Helsinki | PowerDNS secondary, NetBird management, PostgreSQL primary |

PostgreSQL primary/standby swapped after NS1 failure on 2026-03-13 (repmgrd promoted NS2).

---

## 2. Components

| Component | Version | Description |
|-----------|---------|-------------|
| OS | Debian 13 | Hardened with nftables + fail2ban |
| PowerDNS | 4.9.13 | Primary (ns1, PostgreSQL backend) + Secondary (ns2, SQLite, AXFR) |
| Traefik | 3.6 | Reverse proxy, DNS-01 ACME via PowerDNS API |
| PostgreSQL | 18 | Streaming replication via repmgr 5.5, auto-failover |
| NetBird | 0.66.4 | Combined management+signal+relay, PostgreSQL backend, round-robin DNS |
| Restic | 0.16.4 | Incremental backup to Hetzner Storagebox |

---

## 3. How to Deploy

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml                 # Everything
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml       # Traefik only
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml    # PostgreSQL HA only
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml       # NetBird management
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml # NetBird peers
ansible-playbook -i inventory/hosts.yml deploy-netbird-ha.yml    # Traefik + PG + NetBird
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
| 3 | Zone `kind` must be `Master` (not `Native`) for autosecondary | API zone creation must use `"kind": "Master"` |
| 29 | `pdns_control ping` is invalid in PowerDNS 4.9 | Use `pdns_control uptime > /dev/null 2>&1` for health checks |
| 30 | `pdnsutil add-record` does NOT auto-increment SOA serial | Always run `pdnsutil increase-serial` + `pdns_control notify` after |
| 31 | Autosecondary only registers first notifying IP | Add both public + NetBird IPs as autoprimaries |
| 32 | Zone deletion does NOT propagate to secondary | Must explicitly delete on NS2 via API or `pdnsutil delete-zone` |
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
| 47 | Docker images unpinned (`latest` tags) | Pin: `sourcemation/postgres-repmgr:5.5.0`, `netbird-server:0.66.4`, `dashboard:v2.34.2` |

---

## 6. Repository Structure

```
hosting-platform/
├── AGENTS.md              # This file
├── README.md              # Project overview
├── .gitignore
├── .github/
│   ├── pull_request_template.md
│   ├── ISSUE_TEMPLATE/
│   └── workflows/
│       └── ansible-lint.yml
├── ansible/
│   ├── ansible.cfg
│   ├── README.md
│   ├── site.yml           # Main playbook
│   ├── deploy-*.yml       # Targeted playbooks
│   ├── inventory/
│   │   └── hosts.yml      # Server inventory (gitignored)
│   ├── .generated_secrets/ # Auto-generated passwords (gitignored)
│   ├── group_vars/
│   │   └── all.yml        # Global variables (gitignored)
│   ├── host_vars/
│   │   ├── ns1.yml
│   │   └── ns2.yml
│   └── roles/
│       ├── common/            # OS hardening, nftables, Docker, fail2ban
│       ├── powerdns_master/   # PowerDNS primary + PostgreSQL backend
│       ├── powerdns_slave/    # PowerDNS secondary + SQLite
│       ├── traefik/           # Traefik v3.6 reverse proxy
│       ├── postgresql_repmgr/ # PostgreSQL 18 + repmgr HA
│       ├── netbird_management/# NetBird combined server
│       ├── netbird_peer/      # NetBird peer enrollment
│       └── backup/            # Restic backup
└── docs/                  # Architecture and operations docs
```

---

## 7. Do NOT

- Do not commit secrets, tokens, passwords, or IP addresses
- Do not use complex nftables NAT rules (gotcha 7)
- Do not use `bitnami/postgresql-repmgr` (removed from registries, gotcha 11)
- Do not hardcode `/usr/bin/repmgr` (wrong path, gotcha 41)
- Do not use `lookup('password', '/dev/null')` — secrets regenerate each run (gotcha 44)
- Do not use `latest` tags for Docker images (gotcha 47)
- Do not expose PostgreSQL on `0.0.0.0` — bind to NetBird IP only (gotcha 43)
- Do not force-push to `main` without explicit user approval
