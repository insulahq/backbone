# Upgrading components

How version changes reach the nodes, the rules that keep an upgrade safe on
this two-node active-passive platform, and the runbook for the current set of
pinned versions.

## How versions are applied

- Every image and package version is pinned in a role's `defaults/main.yml`
  (`group_vars/all.yml` carries no version overrides). Changing a pin does
  nothing until that role runs again.
- Role deploys (`deploy-*.yml`, `site.yml`) template a new compose file and
  pull with `pull: missing`, so **running the deploy playbook after a pin
  change is the upgrade**.
- `rolling-update.yml` reuses the compose files already on the node and
  re-pulls the **same** tags (`pull: always`). It cannot change a pinned
  version, and it refuses `openziti` (its `compose up` would start a second
  controller on the standby).

## Rules

1. **Know the PG primary first.** On each node:
   `docker exec postgresql psql -U postgres -tAc 'SELECT pg_is_in_recovery()'`
   (`f` = primary). Playbooks order their plays by `dns_failover_primary` /
   `postgresql_primary_node`, which default to ns1 — after a failover, pass
   `-e dns_failover_primary=<primary> -e postgresql_primary_node=<primary>`.
2. **Application services: PG primary first.** Their migrations run wherever
   the new image starts first, and clients are served by the primary.
3. **PostgreSQL itself: standby first**, then the primary.
4. **One-way migrations need a dump first** (restic snapshots alone are a
   slow way back). Before upgrading Zitadel, PowerDNS-Admin or NetBird, dump
   the affected databases on the primary:

   ```bash
   for db in zitadel pdnsadmin netbird netbird_dex netbird_events; do
     docker exec postgresql pg_dump -U postgres -Fc "$db" > "/root/pre-upgrade-$db-$(date +%F).dump"
   done
   ```

   Rollback = `pg_restore --clean` the dump and redeploy the old pin.
5. **Playbooks that run both nodes at once** (`deploy-powerdns.yml`,
   `deploy-traefik.yml`) restart the service on both nodes simultaneously —
   a DNS or HTTPS outage on both at the same moment. Run them with
   `--limit <standby>` then `--limit <primary>` instead.
6. Run `test-suite.yml` before (it must be green) and after each step, and
   take a fresh backup on both nodes before starting:
   `systemctl start restic-backup.service`.

## Runbook — current pins

Each step stands alone; do them in this order (security urgency first) and
verify before moving on.

### 0. Pre-flight

- `test-suite.yml` green; note which node is the PG primary.
- `SELECT version();` on both nodes — record the running PostgreSQL minor.
- Fresh backups on both nodes, then the database dumps from rule 4.

### 1. PowerDNS 5.1.5 + PowerDNS-Admin v2026.08.1

Security: CVE-2026-52682 and CVE-2026-73206 (both High, unauthenticated DoS
on the public authoritative servers).

```bash
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml --limit <primary>
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml --limit <standby>
```

- One node at a time (rule 5), PG primary first (rule 2): PowerDNS-Admin
  runs on both nodes against one `pdnsadmin` DB, and the first node to start
  the new image migrates it.

- PowerDNS-Admin runs `flask db upgrade` on start (one-way Alembic
  migrations, including a foreign-key rewrite on the large `history`
  table). Check `docker logs powerdns-admin` for a clean upgrade and that the
  container turns `healthy` (healthcheck is now `curl …/healthcheck`).
- Verify: `dig @<node> <domain> SOA` on both nodes, PowerDNS-Admin login.
- Rollback: PowerDNS → previous tag. PowerDNS-Admin → restore the
  `pdnsadmin` dump + `v0.4.2`.

### 2. OpenZiti 1.6.21 + console (ZAC) 4.5.5

Security: unauthenticated memory exhaustion on the public edge API, router
identity checks; the console (public) below 4.5.3 has an unauthenticated
`/sso` endpoint (critical). Before deploying (the old `:latest` image is
still on the node), check how old the running console is:
`docker image inspect openziti/zac:latest --format '{{.Created}}'` — anything
before 2026-09-22 was exposed.

```bash
ansible-playbook -i inventory/hosts.yml deploy-openziti.yml
```

- Never via `rolling-update.yml` (now refused).
- Verify: `test-suite.yml --tags openziti`, console login, routers online.
- Rollback: previous tags (DB schema unchanged within 1.6.x).

### 3. Zitadel v4.19.5

Security: Login V1 unauthenticated account takeover (GHSA-45f2-5q3r-xgg6,
critical) and user rename (GHSA-4hgj-wm6c-q7p2).

```bash
ansible-playbook -i inventory/hosts.yml deploy-zitadel.yml -e dns_failover_primary=<primary>
```

- On the primary the role pulls the new image, stops the standby's
  old-version Zitadel (gotcha 159), then runs setup steps 77–79. Expect a
  short login outage while the primary's instance runs setup; the standby
  comes back on its own run. Started from a standby by mistake (wrong
  `dns_failover_primary`), the play fails rather than stop the serving
  instance.
- Don't start this during cluster instability: a PG role change mid-upgrade
  makes the watchdog `docker restart` the quiesced old instance.
- Verify: `https://<zitadel_domain>/debug/ready` → 200, console login,
  `test-suite.yml --tags zitadel`.
- Rollback: restore the `zitadel` dump + `v4.16.1` on both nodes (no
  downgrade path otherwise).

### 4. Traefik v3.7.15, Gatus v5.37.0, Portainer 2.45.2, ntfy v2.32.0

```bash
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml --limit <standby>
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml --limit <primary>
ansible-playbook -i inventory/hosts.yml deploy-gatus.yml
ansible-playbook -i inventory/hosts.yml deploy-portainer.yml
ansible-playbook -i inventory/hosts.yml deploy-ntfy.yml
```

- A Traefik restart on the primary closes every client connection; NetBird
  peers redial (clean resets recover in ~30 s). Watch the
  `NetBird-Mesh-Peers-Healthy` Gatus check afterwards.
- Portainer backs up its own DB before migrating (rollback: previous tag).
- ntfy migrates its message store 15 → 17 (additive). Rollback to ≥ v2.31.1
  is automatic; to v2.27.0 first run
  `UPDATE schema_version SET version = 15 WHERE store = 'message'`.

### 5. NetBird 0.80.0 (server, reverse proxy, dashboard v2.94.0, clients)

Security: relay pre-auth decoding (server), local root via the client daemon
socket (client). **Do not take 0.81.x** — see `netbird_management` defaults.

```bash
# server: PG primary first (migrations run where the new image starts)
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml -e dns_failover_primary=<primary>
# reverse proxy right after — rolling-update never touches it, and
# server/proxy version skew has broken the proxy before
ansible-playbook -i inventory/hosts.yml deploy-netbird-proxy.yml -e dns_failover_primary=<primary>
# managed clients (incl. ns1/ns2): installs 0.80.0, downgrades any 0.81.x, holds it
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml
```

- A server restart wipes in-memory signal state (gotcha 148): watch
  `NetBird-Mesh-Peers-Healthy`; peers without the self-heal guard may need
  `netbird down && netbird up`.
- Unmanaged peers: owners install exactly 0.80.0 (`apt install
  netbird=0.80.0 && apt-mark hold netbird`, or the 0.80.0 Windows installer).
- Check the dashboard login callback (`/nb-auth`) — the dashboard image moved
  to a newer Alpine/nginx while the repo mounts its own nginx config.
- Check the self-heal guard on one managed peer: `bash -x
  /usr/local/bin/netbird-selfheal.sh` (client 0.78+ refuses `netbird up` as
  root when the active profile belongs to another user; the guard must still
  reach its remedy).
- Rollback: restore the three netbird dumps + 0.74.7 / v2.90.5, clients
  `netbird=0.74.7`.

### 6. PostgreSQL 18.6 + pgproxy socat 1.8.1.3 (maintenance window)

Both change the PostgreSQL compose project, so this recreates `postgresql`
and `pgproxy` — writes blip on the primary. Security: ~24 CVEs fixed since
18.4.

```bash
# standby first; wait until it streams again before touching the primary
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit <standby> -e postgresql_primary_node=<primary>
docker exec postgresql psql -U postgres -c 'SELECT client_addr, state FROM pg_stat_replication'   # on the primary
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit <primary> -e postgresql_primary_node=<primary>
```

- The primary's container restart normally completes inside repmgrd's 60 s
  failover debounce. If a failover does happen, auto-failback returns the
  primary role afterwards.
- After both nodes: `SELECT version();` → 18.6 on both; then check GIN
  `reltuples` (18.6 release note — a parallel GIN build could store Infinity
  or NaN, which stops autovacuum on that table) in every database, and
  `ANALYZE` any table it lists with a non-sane value:

  ```bash
  for db in $(docker exec postgresql psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datallowconn AND datname <> 'template1'"); do
    docker exec postgresql psql -U postgres -d "$db" -tAc \
      "SELECT '$db', t.oid::regclass, t.reltuples FROM pg_class t JOIN pg_index i ON t.oid = i.indrelid JOIN pg_class ic ON i.indexrelid = ic.oid WHERE t.relhasindex AND ic.relam = 2742"
  done
  ```

- The other 18.6 / 18.2 migration notes (logical-decoding output plugins,
  pgcrypto PGP ciphers, btree_gist / ltree reindexing) apply only to features
  this platform does not use.
- Rollback: the previous dated tag (any 18.x minor runs on the same data
  directory).

### 7. Afterwards

- Full `test-suite.yml`.
- Update the version tables in `AGENTS.md`, `README.md` and `ROADMAP.md` if
  any pin was changed during the run.
