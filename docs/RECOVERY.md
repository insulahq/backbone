# Disaster Recovery Runbook

**Last Updated:** 2026-03-14
**Audience:** Operators responding to infrastructure failures

---

## Quick Reference

| Scenario | RTO | RPO | Procedure |
|----------|-----|-----|-----------|
| Single node down (other healthy) | 1-2 min (auto) | 0 (streaming repl) | [Scenario 1](#scenario-1-single-node-down) |
| PostgreSQL failover (automatic) | ~60s (repmgrd) | 0 | [Scenario 2](#scenario-2-postgresql-failover) |
| Single node disk failure | 30-60 min | Last backup | [Scenario 3](#scenario-3-disk-failure-rebuild-node) |
| Both nodes down | 1-2 hours | Last backup | [Scenario 4](#scenario-4-both-nodes-down) |
| Restic backup corruption | N/A | Previous backup | [Scenario 5](#scenario-5-backup-repository-issues) |
| NetBird mesh broken | 5-10 min | N/A | [Scenario 6](#scenario-6-netbird-mesh-broken) |
| Split-brain PostgreSQL | 10-15 min | Depends | [Scenario 7](#scenario-7-split-brain-postgresql) |

---

## Prerequisites

Before any recovery, ensure you have:

1. SSH root access to surviving server(s) or Hetzner console access
2. Ansible control machine with the repo checked out
3. Access to `ansible/group_vars/all.yml` and `ansible/inventory/hosts.yml`
4. Restic password (stored in `ansible/.generated_secrets/restic_password`)
5. Hetzner Storagebox credentials

---

## Scenario 1: Single Node Down

**Symptoms:** One server unreachable, DNS still resolving on the other.

**Impact:**
- DNS: Reduced redundancy but still serving (other node answers)
- PostgreSQL: repmgrd will promote standby to primary within ~60s
- NetBird: Dashboard available via round-robin (may need retry)
- Backups: Unaffected on surviving node

**Action:**
```bash
# 1. Verify the surviving node is healthy
ssh root@<SURVIVING_IP> "docker ps && netbird status && systemctl status restic-backup.timer"

# 2. Check PostgreSQL role
ssh root@<SURVIVING_IP> "docker exec postgresql repmgr cluster show"

# 3. If down node comes back, it should auto-rejoin as standby
# Monitor logs:
ssh root@<RECOVERED_IP> "docker logs -f postgresql 2>&1 | head -100"

# 4. If auto-rejoin fails, run the playbook to re-sync:
cd ansible
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit <RECOVERED_NODE>
```

---

## Scenario 2: PostgreSQL Failover (Automatic)

**Symptoms:** repmgrd promoted standby to primary. Old primary is down or degraded.

**Verification:**
```bash
# Check which node is primary on BOTH nodes
ssh root@<NS1_IP> "docker exec postgresql repmgr cluster show"
ssh root@<NS2_IP> "docker exec postgresql repmgr cluster show"

# Check repmgr events
ssh root@<NEW_PRIMARY_IP> "docker exec postgresql repmgr cluster event --limit=10"
```

**After old primary recovers:**
The entrypoint wrapper (`entrypoint-wrapper.sh`) automatically detects the role change on restart:
1. Queries the peer to determine who is primary
2. Compares timelines
3. Uses `pg_rewind` to rejoin as standby if needed
4. Falls back to full re-clone if `pg_rewind` fails

```bash
# If automatic rejoin doesn't work, force a rejoin:
ssh root@<OLD_PRIMARY_IP> "docker exec postgresql repmgr standby clone --force -h <NEW_PRIMARY_NETBIRD_IP> -U repmgr -d repmgr"
ssh root@<OLD_PRIMARY_IP> "docker restart postgresql"
```

**Important:** Update `postgresql_primary_node` in `roles/postgresql_repmgr/defaults/main.yml` to reflect the new primary, so future Ansible runs deploy in the correct order.

---

## Scenario 3: Disk Failure — Rebuild Node

**Symptoms:** Server disk is dead. Hetzner has re-provisioned with fresh Debian 13.

**Procedure:**

### Step 1: Verify backup availability
```bash
# On the control machine (or surviving node)
export RESTIC_REPOSITORY="sftp:<STORAGEBOX_USER>@<STORAGEBOX_HOST>:/backups/<DEAD_NODE>"
export RESTIC_PASSWORD_FILE="ansible/.generated_secrets/restic_password"

# List available snapshots
restic snapshots --host <DEAD_NODE>

# Check what's in the latest snapshot
restic ls latest --host <DEAD_NODE>
```

### Step 2: Run Ansible to rebuild
```bash
cd ansible

# 1. Deploy base OS hardening + Docker
ansible-playbook -i inventory/hosts.yml site.yml --tags common --limit <DEAD_NODE>

# 2. Deploy Traefik
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml --limit <DEAD_NODE>

# 3. Deploy PostgreSQL (it will join as standby automatically)
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit <DEAD_NODE>

# 4. Deploy PowerDNS
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml --limit <DEAD_NODE>

# 5. Deploy NetBird management
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml --limit <DEAD_NODE>

# 6. Re-enroll as NetBird peer
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml --limit <DEAD_NODE>

# 7. Check NetBird IP (may have changed — gotcha 17)
ssh root@<NEW_IP> "netbird status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"localPeerState\"][\"ip\"])'"

# 8. Update inventory/hosts.yml if NetBird IP changed, then redeploy services that bind to it
ansible-playbook -i inventory/hosts.yml deploy-netbird-ha.yml --limit <DEAD_NODE>

# 9. Deploy Zitadel (stateless — just starts and connects to existing PG data)
ansible-playbook -i inventory/hosts.yml deploy-zitadel.yml --limit <DEAD_NODE>

# 10. Deploy backups
ansible-playbook -i inventory/hosts.yml deploy-backup.yml --limit <DEAD_NODE>
```

### Step 3: Restore configuration files from backup (if needed)
```bash
# On the rebuilt node, if specific config files are needed:
ssh root@<REBUILT_NODE>

export RESTIC_REPOSITORY="sftp:<USER>@<HOST>:/backups/<NODE>"
export RESTIC_PASSWORD_FILE="/etc/restic/password"

# Restore specific paths
restic restore latest --target /tmp/restore --include "/opt/netbird/idp.db"

# Copy restored files to correct locations
cp /tmp/restore/opt/netbird/idp.db /opt/netbird/
docker restart netbird-server
```

---

## Scenario 4: Both Nodes Down

**Symptoms:** Both servers unreachable. Total outage.

**Procedure:**

1. Provision two new Debian 13 servers on Hetzner
2. Update `inventory/hosts.yml` with new IPs
3. Follow `docs/BOOTSTRAP.md` for a fresh deployment
4. After PostgreSQL is running on the new primary, restore data from backup:

```bash
# On the control machine
restic restore latest \
    --target /tmp/restore \
    --host <OLD_PRIMARY_NODE> \
    --include "/opt/powerdns" \
    --include "/opt/netbird"

# Copy PostgreSQL data (zones, NetBird config) to new primary
scp -r /tmp/restore/opt/powerdns/pdns.conf root@<NEW_PRIMARY>:/opt/powerdns/
scp -r /tmp/restore/opt/netbird/ root@<NEW_PRIMARY>:/opt/netbird/
```

5. Recreate DNS zones from PowerDNS backup or re-add manually
6. Re-create NetBird setup key and PAT (old ones are invalidated)
7. Update `group_vars/all.yml` with new values

---

## Scenario 5: Backup Repository Issues

### Restic password lost
**Impact:** All existing backups are permanently inaccessible (gotcha 10).
```bash
# The password is stored in:
#   - ansible/.generated_secrets/restic_password (control machine)
#   - /etc/restic/password (on each server)
# If both are lost, you must wipe and re-initialize:
ssh root@<NODE> "restic -r <REPO> cat config"  # Will fail without password

# Nuclear option: wipe and start fresh (gotcha 10)
# WARNING: This destroys ALL existing backups
ssh root@<NODE> "sftp <USER>@<HOST>:/backups/<NODE>"
# sftp> rm *
# sftp> exit
ssh root@<NODE> "systemctl start restic-backup.service"  # Re-initializes repo
```

### Backup failures
```bash
# Check recent backup logs
ssh root@<NODE> "journalctl -u restic-backup.service --since '24 hours ago'"

# Check Storagebox connectivity
ssh root@<NODE> "echo quit | sftp -o ConnectTimeout=10 -i /etc/restic/hosting-platform.key <USER>@<HOST>"

# Run backup manually with verbose output
ssh root@<NODE> "/etc/restic/backup.sh"

# Check repo integrity
ssh root@<NODE> "restic -r <REPO> check"
```

---

## Scenario 6: NetBird Mesh Broken

**Symptoms:** Servers can't reach each other via NetBird IPs. Public IPs still work.

```bash
# 1. Check NetBird status on both nodes
ssh root@<NS1_PUBLIC_IP> "netbird status"
ssh root@<NS2_PUBLIC_IP> "netbird status"

# 2. If disconnected, try reconnecting
ssh root@<NODE> "netbird down && netbird up"

# 3. If enrollment is lost, re-enroll
ssh root@<NODE> "netbird down"
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml --limit <NODE>

# 4. Check if NetBird IP changed (gotcha 17)
ssh root@<NODE> "netbird status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"localPeerState\"][\"ip\"])'"

# 5. If IP changed, update inventory and redeploy bound services
ansible-playbook -i inventory/hosts.yml deploy-netbird-ha.yml
```

---

## Scenario 7: Split-Brain PostgreSQL

**Symptoms:** Both nodes think they are primary. Detected by runtime watchdog or manual check.

```bash
# 1. Identify the situation
ssh root@<NS1> "docker exec postgresql repmgr cluster show"
ssh root@<NS2> "docker exec postgresql repmgr cluster show"

# 2. Check timelines (higher timeline = more recent promotion)
ssh root@<NS1> "docker exec postgresql psql -U postgres -tc 'SELECT pg_control_checkpoint()'"
ssh root@<NS2> "docker exec postgresql psql -U postgres -tc 'SELECT pg_control_checkpoint()'"

# 3. The entrypoint wrapper has a watchdog that auto-demotes the lower-timeline node
# Check if it already resolved:
ssh root@<NODE> "docker logs postgresql 2>&1 | tail -50"

# 4. If not auto-resolved, manually demote one node:
# Pick the node with FEWER recent writes (or lower timeline)
ssh root@<DEMOTE_NODE> "docker exec postgresql repmgr standby clone --force -h <PRIMARY_NETBIRD_IP> -U repmgr -d repmgr"
ssh root@<DEMOTE_NODE> "docker restart postgresql"

# 5. Verify resolution
ssh root@<PRIMARY> "docker exec postgresql repmgr cluster show"
```

---

## Verification Checklist

After any recovery, verify all components:

```bash
# DNS resolution (both nodes)
dig @<NS1_PUBLIC_IP> <PLATFORM_DOMAIN> SOA +short
dig @<NS2_PUBLIC_IP> <PLATFORM_DOMAIN> SOA +short

# PostgreSQL replication
ssh root@<PRIMARY> "docker exec postgresql repmgr cluster show"

# NetBird mesh connectivity
ssh root@<NS1> "ping -c 3 <NS2_NETBIRD_IP>"
ssh root@<NS2> "ping -c 3 <NS1_NETBIRD_IP>"

# Traefik TLS
curl -I https://netbird.<PLATFORM_DOMAIN>

# Backup timer
ssh root@<NS1> "systemctl status restic-backup.timer"
ssh root@<NS2> "systemctl status restic-backup.timer"

# PowerDNS API
curl -s -H "X-API-Key: <KEY>" http://<NETBIRD_IP>:8081/api/v1/servers/localhost/zones | python3 -m json.tool
```

---

## Emergency Contacts

| Resource | Access |
|----------|--------|
| Hetzner Cloud Console | https://console.hetzner.cloud |
| Hetzner Robot (Storagebox) | https://robot.hetzner.com |
| Restic password file | `ansible/.generated_secrets/restic_password` |
| All generated secrets | `ansible/.generated_secrets/` |
