# Disaster Recovery Runbook

**Last Updated:** 2026-04-06
**Audience:** Operators responding to infrastructure failures

---

## Quick Reference

| # | Scenario | Recovery | RTO | RPO |
|---|----------|----------|-----|-----|
| 1 | [Single node down (other healthy)](#scenario-1-single-node-down) | Automatic | ~80s | 0 |
| 2 | [PostgreSQL failover](#scenario-2-postgresql-failover) | Automatic | ~80s | 0 |
| 3 | [Node replacement (new server)](#scenario-3-node-replacement) | Manual | ~30 min | 0 |
| 4 | [Both nodes down simultaneously](#scenario-4-both-nodes-down) | Manual | 1-2 hours | Up to 24h |
| 5 | [Both down, standby boots first](#scenario-5-standby-boots-first) | Auto (300s) | ~5 min | 0 |
| 6 | [PG container crash (not node)](#scenario-6-pg-container-crash) | Automatic | 10-20s | 0 |
| 7 | [WAL gap (standby fell behind)](#scenario-7-wal-gap) | Automatic | 60-300s | 0 |
| 8 | [Split-brain PostgreSQL](#scenario-8-split-brain) | Automatic | 30-45s | Diverged writes lost |
| 9 | [NetBird mesh broken](#scenario-9-netbird-mesh-broken) | Manual | 5-10 min | N/A |
| 10 | [Database-only restore](#scenario-10-database-only-restore) | Manual | 10-30 min | Up to 24h |
| 11 | [Backup repository issues](#scenario-11-backup-issues) | Manual | Varies | Previous backup |
| 12 | [Control machine lost](#scenario-12-control-machine-lost) | Manual | 1-4 hours | 0 (if servers up) |
| 13 | [OpenZiti controller down](#scenario-13-openziti-controller-down) | Automatic | ~90s | 0 (DB synced) |

---

## Prerequisites

Before any recovery, ensure you have:

1. SSH root access to surviving server(s) or provider console access
2. Ansible control machine with the repo checked out
3. Access to `ansible/group_vars/all.yml` and `ansible/inventory/hosts.yml`
4. Restic password (stored in `ansible/.generated_secrets/restic_password`)
5. Backup server credentials (SFTP or S3)

> **CRITICAL:** Back up `.generated_secrets/` offline. See [Offline Secrets Procedure](#offline-secrets-procedure).

---

## Scenario 1: Single Node Down

**Symptoms:** One server unreachable, DNS still resolving via the other.

**What happens automatically:**
1. repmgrd on the surviving standby detects primary failure (~60s)
2. `promote-check.sh` validates external connectivity (prevents false promotion)
3. Standby promotes to primary
4. `pg-role-watchdog` (within 10s) detects role change → updates pgproxy → restarts services → switches DNS

**Impact during recovery:**
- DNS: Other node continues serving (both are authoritative NS)
- PostgreSQL: Write unavailability for ~80s (detection + promotion + DNS switch)
- Services: Brief restart on the surviving node (PowerDNS, NetBird, Zitadel, Gatus)
- OpenZiti: Router on surviving node stays healthy. If controller was on the failed node,
  the watchdog on the surviving node promotes itself (~90s). Routers reconnect via
  `127.0.0.1` (host network). Edge API and ZAC console resume on the surviving node.

**When the failed node returns:**
The entrypoint automatically detects the role change, uses `pg_rewind` to rejoin as standby, and resumes streaming replication. No manual action needed.

```bash
# Verify automatic recovery
ssh root@<SURVIVING_IP> "docker exec postgresql repmgr cluster show"

# If auto-rejoin fails after node returns:
cd ansible
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit <RECOVERED_NODE>
```

---

## Scenario 2: PostgreSQL Failover

**Symptoms:** repmgrd promoted standby to primary. Services may show brief errors.

**Verification:**
```bash
# Check roles on both nodes
ssh root@<NS1_IP> "docker exec postgresql repmgr cluster show"
ssh root@<NS2_IP> "docker exec postgresql repmgr cluster show"

# Check repmgr events
ssh root@<NEW_PRIMARY_IP> "docker exec postgresql repmgr cluster event --limit=10"

# Check watchdog handled DNS switch
ssh root@<NEW_PRIMARY_IP> "journalctl -u pg-role-watchdog --since '5 minutes ago' --no-pager"
```

**After old primary recovers:** Automatic — entrypoint uses `pg_rewind` or full re-clone.

```bash
# Force rejoin if automatic fails:
ssh root@<OLD_PRIMARY_IP> "cd /opt/postgresql && docker compose restart postgresql"
# Monitor: docker logs -f postgresql
```

---

## Scenario 3: Node Replacement (New Server)

**Symptoms:** Server is permanently dead. Provider has provisioned a new Debian 13 server.

**Timeline: ~30 minutes, zero downtime for users.**

### Step 1: Update inventory (2 min)

Edit `ansible/inventory/hosts.yml` — change the dead node's `ansible_host` to the new IP.
If the new server has a different IPv6, update `public_ipv6` too.

> WireGuard IP (`10.100.0.x`) and hostname stay the same.

### Step 2: Update DNS glue records (5 min)

At your domain registrar, update the NS glue record for the dead node to the new IP.
Propagation takes up to 48h but the surviving node serves DNS throughout.

### Step 3: Update WireGuard on surviving node (if IP changed)

```bash
# Only needed if the new server has a DIFFERENT public IP
ansible-playbook -i inventory/hosts.yml deploy-wireguard.yml --limit <SURVIVING_NODE>
```

This updates the surviving node's WireGuard config with the new server's endpoint IP.

### Step 4: Deploy to the new server (~15 min)

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml --limit <NEW_NODE> \
  -e "ansible_ssh_private_key_file=$HOME/hosting-platform.key"
```

This runs the full stack: OS hardening → WireGuard → PostgreSQL (auto-clones from primary) → all services.

### Step 5: Re-enroll NetBird peer (5 min)

```bash
# Create a new setup key in the NetBird dashboard (vpn.<domain>)
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml --limit <NEW_NODE>
```

### Step 6: Verify

```bash
ansible-playbook -i inventory/hosts.yml test-suite.yml
```

**What you DON'T need to do:**
- No database restore (PG auto-clones from surviving primary)
- No DNS zone recreation (replicated via PG)
- No certificate transfer (Traefik re-issues via ACME)
- No WireGuard key regeneration (reuses existing keys from `.generated_secrets/`)

### Known pitfalls (surfaced by 2026-04-23 node-replacement drill)

1. **SSH host key on the surviving node.** After re-imaging, the peer gets a new SSH host key. Remove the stale entry on the surviving node and re-scan **before** running `site.yml`:
   ```bash
   ssh-keygen -R <NEW_NODE_WG_IP> -f /root/.ssh/known_hosts   # on surviving node
   ssh-keyscan -t ed25519 <NEW_NODE_WG_IP> >> /root/.ssh/known_hosts
   ```
   Otherwise `openziti PKI rsync` (delegated to surviving node) fails with "REMOTE HOST IDENTIFICATION HAS CHANGED".

2. **Zitadel DB password may not be in `.generated_secrets/`.** On clusters set up before this drill fix, `.generated_secrets/zitadel_db_password` is missing — Ansible will generate a *new* password and ns2's Zitadel will fail to authenticate against the existing PG user. Before running `site.yml`, extract the real password from the surviving node:
   ```bash
   # On surviving node (ns1):
   grep '^      Password:' /opt/zitadel/config.yaml | head -1 | sed 's/^ *Password: *//;s/"//g'
   # Then on controller:
   printf '%s' '<THE_PASSWORD>' > ansible/.generated_secrets/zitadel_db_password
   chmod 600 ansible/.generated_secrets/zitadel_db_password
   ```

3. **NetBird peer enrollment is manual.** `deploy-netbird-peers.yml` installs the client but does not auto-enroll. Create a setup key in the dashboard, then on the new node:
   ```bash
   netbird up --setup-key <KEY> --management-url https://vpn.<domain> --hostname <HOSTNAME>
   ```

4. **`--start-at-task` resume is dangerous.** If `site.yml` fails mid-run, resume with a full re-run of `site.yml --limit NEW_NODE` instead of `--start-at-task=...`. Skipping earlier systemd unit installs leaves the node half-provisioned (OpenZiti standby timers were missed in the drill using `--start-at-task`).

---

## Scenario 4: Both Nodes Down

**Symptoms:** Both servers unreachable. Total outage.

### If servers can be rebooted (not lost)

Boot either node. If the **old primary** boots first, it starts normally. If the **standby** boots first, see [Scenario 5](#scenario-5-standby-boots-first).

### If both servers are permanently lost

1. Provision two new Debian 13 servers (different locations)
2. Update `inventory/hosts.yml` with new IPs
3. If IPs changed, update NS glue records at your registrar
4. Follow [docs/BOOTSTRAP.md](BOOTSTRAP.md) for fresh deployment
5. Restore database from backup:

```bash
# On the new primary, after PostgreSQL is running:
/etc/restic/restore.sh database --load
```

6. Re-create NetBird setup key (old ones are invalidated)
7. Verify: `ansible-playbook -i inventory/hosts.yml test-suite.yml`

**RPO:** Up to 24 hours (daily backup). Streaming replication data between the last backup and the failure is lost.

---

## Scenario 5: Standby Boots First (Primary Gone)

**Symptoms:** After a dual outage, the standby boots but the primary never comes back.

**What happens automatically:**
1. Entrypoint detects it was a standby, tries to reach the primary
2. Waits up to 300s (5 minutes) for the primary to appear
3. After timeout: **self-promotes** to primary
4. Watchdog switches DNS to this node

**No manual action needed.** Monitor via:
```bash
ssh root@<BOOTED_NODE> "docker logs -f postgresql 2>&1 | grep -E 'SELF-PROMOTING|RESOLVED|ready to accept'"
```

---

## Scenario 6: PG Container Crash (Not Full Node)

**Symptoms:** PostgreSQL container restarted but node is healthy.

**What happens automatically:**
1. Docker restarts the container (`unless-stopped` policy)
2. Entrypoint re-runs: detects role from peer, starts correctly
3. If restart completes within 60s, no failover (repmgrd reconnect window)
4. If restart takes >60s, standby promotes (same as Scenario 1)

Typically recovers in 10-20s with no failover.

---

## Scenario 7: WAL Gap (Standby Fell Behind)

**Symptoms:** Standby was offline too long, primary's `max_slot_wal_keep_size` removed WAL segments.

**What happens automatically:**
1. On standby restart, PG tries to stream missing WAL → fails
2. **During startup:** If PG gets stuck in replay for >90s, entrypoint detects the "has already been removed" error and auto-re-clones from primary
3. **After startup:** If WAL receiver drops after PG is running, the entrypoint's WAL health check detects the gap and auto-re-clones

```bash
# Monitor re-clone progress:
ssh root@<STANDBY> "docker logs -f postgresql 2>&1 | grep -E 'Re-clone|standby clone|streaming'"
```

**Manual fix if auto-recovery fails:**
```bash
ssh root@<STANDBY> "cd /opt/postgresql && docker compose stop postgresql && \
  docker volume rm postgresql_postgresql_data && docker compose up -d postgresql"
```

---

## Scenario 8: Split-Brain PostgreSQL

**Symptoms:** Both nodes think they are primary.

**What happens automatically:**
The `split_brain_watchdog` (runs every 15s on primary) detects dual-primary via peer query. Resolution:
- Higher timeline wins (was promoted more recently)
- Same timeline: `REPMGR_INITIAL_ROLE` is the deterministic tiebreaker
- Loser self-demotes: writes `.demoted` marker → container restarts as standby → `pg_rewind`

```bash
# Check if already auto-resolved:
ssh root@<NODE> "docker logs postgresql 2>&1 | grep -E 'SPLIT-BRAIN|SELF-DEMOTING'"

# Manual resolution if watchdog hasn't acted:
# 1. Identify which node has fewer/older writes
ssh root@<NS1> "docker exec postgresql psql -U postgres -tc 'SELECT timeline_id FROM pg_control_checkpoint()'"
ssh root@<NS2> "docker exec postgresql psql -U postgres -tc 'SELECT timeline_id FROM pg_control_checkpoint()'"

# 2. Demote the lower-timeline node
ssh root@<DEMOTE_NODE> "cd /opt/postgresql && docker compose restart postgresql"
```

> **Data impact:** Writes to the demoted node since divergence are lost (`pg_rewind` rolls them back). The window is typically <60s.

---

## Scenario 9: NetBird Mesh Broken

**Symptoms:** Servers can't reach each other via NetBird IPs (`100.x.x.x`). Public IPs still work.

> **No impact on core infrastructure.** WireGuard (`wg0`) is independent of NetBird (`wt0`). PostgreSQL replication, PowerDNS API, and all inter-node communication use WireGuard.

```bash
# 1. Check status
ssh root@<NODE> "netbird status"

# 2. Reconnect
ssh root@<NODE> "netbird down && netbird up"

# 3. Re-enroll if needed
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml --limit <NODE>
```

---

## Scenario 10: Database-Only Restore

**Symptoms:** Data corruption, accidental deletion, or need to rollback.

PostgreSQL is backed up via `pg_dumpall` piped to restic stdin, tagged `pgdump`.

```bash
# List available database snapshots
ssh root@<NODE> "/etc/restic/restore.sh list"

# Extract and load on the primary node
ssh root@<PRIMARY> "/etc/restic/restore.sh database --load"

# Or extract only (review before loading)
ssh root@<NODE> "/etc/restic/restore.sh database"
# Then manually: docker exec -i postgresql psql -U postgres < /root/pg-restore-*/pg_dumpall.sql

# Ansible playbook (remote)
ansible-playbook -i inventory/hosts.yml restore.yml --limit <PRIMARY> --tags database
```

> **WARNING:** `pg_dumpall --load` overwrites ALL databases. The standby will automatically re-sync via streaming replication after the primary is updated.

---

## Scenario 11: Backup Issues

### Backup failures
```bash
# Check logs
ssh root@<NODE> "journalctl -u restic-backup.service --since '24 hours ago'"

# Run manually
ssh root@<NODE> "/etc/restic/backup.sh"

# Check repo integrity
ssh root@<NODE> "/etc/restic/restore.sh list"
```

### Restic password lost
The password is stored in:
- `ansible/.generated_secrets/restic_password` (control machine)
- `/etc/restic/password` (on each server)

If ALL copies are lost, existing backups are **permanently inaccessible**. You must wipe the repo and start fresh:
```bash
# Nuclear option — destroys all existing backups
ssh root@<NODE> "rm -rf /var/cache/restic/*"
ssh root@<NODE> "systemctl start restic-backup.service"  # Re-initializes
```

---

## Scenario 12: Control Machine Lost

**Symptoms:** The Ansible control machine is dead. Servers are still running.

**Immediate impact:** None — servers run independently.

**To regain management access:**

1. Set up a new control machine with Ansible + this repo
2. Recover `.generated_secrets/` from your offline backup (see [Offline Secrets Procedure](#offline-secrets-procedure))
3. If no offline backup exists, recover from a running server:

```bash
# The restic password is on every server
ssh root@<ANY_NODE> "cat /etc/restic/password"

# Service configs (containing all passwords) are under /opt
ssh root@<ANY_NODE> "cat /opt/zitadel/config.yaml"     # Zitadel passwords
ssh root@<ANY_NODE> "cat /opt/powerdns/pdns.conf"       # PowerDNS API key
ssh root@<ANY_NODE> "cat /opt/netbird/config.yaml"      # NetBird secrets
ssh root@<ANY_NODE> "cat /etc/wireguard/wg0.conf"       # WireGuard keys

# Reconstruct group_vars/all.yml from these values + the example file
```

4. Recreate `inventory/hosts.yml` from the example + known server IPs
5. Test access: `ansible all -i inventory/hosts.yml -m ping`

---

## Verification Checklist

After any recovery, run the automated test suite:

```bash
# Full validation (87 tests)
ansible-playbook -i inventory/hosts.yml test-suite.yml

# Failover-specific (21 tests including pre/post-flight)
ansible-playbook -i inventory/hosts.yml test-suite.yml --tags failover
```

Or verify manually:
```bash
# PostgreSQL cluster
ssh root@<PRIMARY> "docker exec postgresql repmgr cluster show"

# DNS (from any external resolver)
dig @<NS1_IP> <DOMAIN> SOA +short
dig @<NS2_IP> <DOMAIN> SOA +short

# WireGuard tunnel
ssh root@<NS1> "ping -c 3 10.100.0.2"

# TLS certificates
curl -I https://vpn.<DOMAIN>

# Backup timer
ssh root@<NODE> "systemctl status restic-backup.timer"
```

---

## Scenario 13: OpenZiti Controller Down

**Symptoms:** ZAC console unreachable, tunneler clients can't authenticate, Gatus reports "OpenZiti Edge API" down.

**What happens automatically:**
1. The `ziti-watchdog` on the standby node detects the controller is unreachable (3 cycles x 30s = ~90s)
2. Watchdog promotes itself: starts controller + console from synced DB copy
3. Clears router endpoints cache and restarts local router
4. Router reconnects to local controller via `127.0.0.1:8440`

**Verify promotion:**
```bash
# On surviving node
docker ps --filter name=ziti-controller  # Should be running
docker logs ziti-controller --tail 5     # Should show startup
journalctl -u ziti-watchdog.service -n 20  # Should show "FAILOVER COMPLETE"
```

**If watchdog did NOT promote (e.g., both nodes were down):**
```bash
# On the preferred primary, manually start
cd /opt/openziti
docker compose up -d --force-recreate ziti-controller ziti-console
rm -f /opt/openziti/router/endpoints
docker compose restart ziti-router
```

**After the failed node returns:**
The watchdog on the preferred primary will detect the controller running on the peer. After a 10-minute settling period, it performs automatic failback: stops peer controller, syncs latest DB, starts locally.

**OpenZiti PKI:**
If the PKI directory (`/opt/openziti/pki/`) is lost on both nodes, a full re-bootstrap is required:
```bash
ansible-playbook -i inventory/hosts.yml deploy-openziti.yml
```
This regenerates all certificates and re-enrolls routers. Existing enrolled tunneler identities will need re-enrollment.

---

## Offline Secrets Procedure

**CRITICAL:** `ansible/.generated_secrets/` lives ONLY on the Ansible control machine. It contains secrets that CANNOT be regenerated:

| Secret | Why it's critical |
|--------|------------------|
| `restic_password` | Without it, all backups are permanently inaccessible |
| `zitadel_masterkey` | Immutable after first Zitadel init — cannot be changed |
| `ssh/{ns1,ns2}` | Per-server SSH keypairs for Ansible access |
| `wireguard/{ns1,ns2}.key` | WireGuard tunnel private keys |
| All other passwords | Database credentials, API keys, etc. |

### Back up after every `setup.sh` run:

```bash
# Encrypted archive to USB or safe location
cd ansible
tar czf - .generated_secrets/ group_vars/all.yml inventory/hosts.yml | \
  gpg --symmetric --cipher-algo AES256 \
  -o hosting-platform-secrets-$(date +%Y%m%d).gpg

# Store the GPG passphrase separately (password manager, physical safe)
```

### Recovery without offline backup:

If the control machine is lost but at least one server is running, see [Scenario 12](#scenario-12-control-machine-lost) — all secrets can be reconstructed from the running server's config files.

---

## Emergency Contacts

| Resource | Access |
|----------|--------|
| Cloud provider console | `<PROVIDER_CONSOLE_URL>` |
| Backup server panel | `<PROVIDER_PANEL_URL>` |
| Restic password | `ansible/.generated_secrets/restic_password` |
| All generated secrets | `ansible/.generated_secrets/` |
| Offline backup | `<LOCATION_OF_GPG_ARCHIVE>` |
