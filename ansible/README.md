# Ansible Infrastructure Deployment

> **Status:** READY TO DEPLOY — Common role completed  
> **Alignment:** All configuration aligns with `docs/04-deployment/FRESH_INFRASTRUCTURE_PLAN.md`

## Overview

This directory contains Ansible playbooks and roles for deploying the Phoenix Host infrastructure on ns1, ns2, and admin1 servers.

**Architecture decisions confirmed by user (2026-03-11):**
- ✅ Debian 13 (trixie) — Official stable release
- ✅ PowerDNS 4.9 (not BIND) — REST API, database-backed
- ✅ Fresh NetBird deployment — New management server on ns1
- ✅ Simple nftables firewall — NO advanced pre/post-routing
- ✅ SSH break-glass access — SSH stays open on all servers

## Quick Start

### Prerequisites

1. **Ansible installed** on your workstation:
   ```bash
   pip3 install ansible
   ```

2. **SSH key** (`~/phoenix-host.key`) with access to all servers

3. **Servers re-imaged** with Debian 13 (trixie)

### Deployment

**IMPORTANT:** Always run Ansible commands from the `ansible/` directory:

```bash
cd /config/hosting-platform/ansible
```

#### Step 1: Verify connectivity

```bash
ansible all -m ping
```

Expected output: All servers return `pong`.

#### Step 2: Deploy common role (OS hardening + Docker + simple firewall)

```bash
ansible-playbook site.yml --tags common
```

Or deploy to all servers:

```bash
ansible-playbook site.yml
```

#### Step 3: Verify deployment

SSH to any server and verify:

```bash
ssh -i ~/phoenix-host.key root@23.88.111.142  # ns1
docker --version
nft list tables
systemctl status fail2ban
```

## Repository Structure

```
ansible/
├── ansible.cfg              # Ansible configuration
├── site.yml                 # Main playbook
├── inventory/
│   └── hosts.yml            # Server inventory with IPs
├── group_vars/
│   └── all.yml              # Global variables
└── roles/
    └── common/              # ✅ OS hardening, nftables, Docker
        ├── tasks/
        │   └── main.yml
        ├── templates/
        │   └── nftables.conf.j2
        └── handlers/
            └── main.yml
```

## Roles (Phase 1 Deployment Order)

| # | Role | Status | Purpose |
|---|------|--------|---------|
| 1 | ✅ `common` | **COMPLETE** | OS hardening, simple nftables, Docker CE, fail2ban |
| 2 | ⏳ `netbird_management` | Pending | NetBird management + signal + relay on ns1 |
| 3 | ⏳ `netbird_peer` | Pending | NetBird peer on ns2, admin1, workstation |
| 4 | ⏳ `powerdns_master` | Pending | PowerDNS primary + PostgreSQL on ns1 |
| 5 | ⏳ `powerdns_slave` | Pending | PowerDNS secondary + SQLite on ns2 |
| 6 | ⏳ `backup` | Pending | Restic backup to Storagebox |
| 7 | ⏳ `k3s` | Pending | k3s single-node cluster on admin1 |

## Server Inventory

| Server | IP | Role | Ansible Groups |
|--------|----|----- |----------------|
| **ns1** | `23.88.111.142` | PowerDNS Primary + NetBird Management | `dns_servers`, `netbird_management`, `powerdns_primary`, `backup_targets` |
| **ns2** | `89.167.125.29` | PowerDNS Secondary + NetBird Peer | `dns_servers`, `netbird_peers`, `powerdns_secondary`, `backup_targets` |
| **admin1** | `46.224.122.58` | k3s + Management API + Panels | `k8s_servers`, `netbird_peers`, `backup_targets` |

## Firewall Configuration

**CRITICAL LESSON FROM PREVIOUS DEPLOYMENT:**

Advanced nftables pre-routing and post-routing configurations broke ns1 access after NetBird changes.

**SOLUTION:** The `common` role deploys a **simple nftables configuration** with:
- ✅ Basic INPUT/OUTPUT/FORWARD chains only
- ✅ NO custom DNAT, SNAT, or MASQUERADE rules
- ✅ NO prerouting or postrouting hooks
- ✅ Docker and NetBird manage their own NAT

**Allowed ports:**
- Port 22 (SSH) — break-glass access (stays open)
- Port 53 (DNS) — UDP/TCP on ns1/ns2
- Port 443 (HTTPS) — NetBird management UI on ns1
- Port 51820 (WireGuard) — NetBird mesh
- Port 10000 (TURN) — NetBird relay on ns1

**After nftables reload, Docker must be restarted** — the handler does this automatically.

## Troubleshooting

### Ansible cannot connect to servers

```bash
# Test SSH access manually
ssh -i ~/phoenix-host.key root@23.88.111.142

# Check inventory syntax
ansible-inventory --list

# Test with verbose output
ansible all -m ping -vvv
```

### Docker not working after nftables changes

```bash
# Restart Docker (restores Docker's chains)
systemctl restart docker

# Verify Docker can communicate
docker run --rm hello-world
```

### Firewall blocking expected traffic

```bash
# Check nftables rules
nft list ruleset

# Check fail2ban status
fail2ban-client status sshd
```

## Next Steps

After deploying the common role:

1. ✅ **Verify all servers** — SSH, Docker, firewall
2. ⏳ **Create `netbird_management` role** — Deploy NetBird on ns1
3. ⏳ **Create `netbird_peer` role** — Connect ns2, admin1, workstation
4. ⏳ **Verify NetBird mesh** — All nodes can ping each other
5. ⏳ **Create `powerdns_master` role** — Deploy PowerDNS on ns1
6. ⏳ **Create `powerdns_slave` role** — Deploy PowerDNS on ns2
7. ⏳ **Verify DNS replication** — Create test zone, confirm < 5s propagation
8. ⏳ **Create `backup` role** — Deploy Restic backup
9. ⏳ **Create `k3s` role** — Deploy k3s on admin1

See `docs/04-deployment/FRESH_INFRASTRUCTURE_PLAN.md` for full deployment plan.
