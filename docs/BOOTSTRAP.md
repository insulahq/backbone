# Bootstrap: Fresh Deployment from Scratch

This document describes how to deploy the infrastructure on two fresh Debian 13 servers.

A single `site.yml` run will **not** work from scratch due to circular dependencies between components. Follow these steps in order.

---

## Prerequisites

1. Two Hetzner VPS with Debian 13 installed
2. Root SSH access to both servers
3. DNS zone for your domain (e.g., `example.com`) with NS records pointing to your servers
4. Hetzner Storagebox for backups
5. Ansible 2.15+ on your control machine

## Step 1: Configure Inventory and Variables

```bash
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
cp ansible/group_vars/all.example.yml ansible/group_vars/all.yml
```

Edit both files with your server IPs, domain, and generated secrets. Leave `netbird_ip` fields empty for now -- they will be assigned after NetBird enrollment.

## Step 2: OS Hardening + Docker

Deploy the `common` role to both servers:

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml --tags common
# Or: ansible-playbook -i inventory/hosts.yml -l dns_servers -e role=common site.yml
```

This installs Docker, nftables, fail2ban, and hardens SSH.

## Step 3: PowerDNS

Deploy PowerDNS primary (ns1) and secondary (ns2):

```bash
ansible-playbook -i inventory/hosts.yml site.yml --limit powerdns_primary --tags powerdns
ansible-playbook -i inventory/hosts.yml site.yml --limit powerdns_secondary --tags powerdns
```

After deployment, create the DNS A records for your NetBird domain manually:

```bash
# On ns1:
docker exec powerdns-auth pdnsutil add-record example.com netbird A <NS1_PUBLIC_IP>
docker exec powerdns-auth pdnsutil add-record example.com netbird A <NS2_PUBLIC_IP>
docker exec powerdns-auth pdnsutil increase-serial example.com
docker exec powerdns-auth pdns_control notify example.com
```

## Step 4: Traefik

Deploy Traefik on both nodes. It needs the PowerDNS API for DNS-01 ACME challenges.

At this point, the PowerDNS nginx proxy hasn't been deployed yet (it binds to the NetBird IP which doesn't exist). Traefik can still start but cert issuance will fail until NetBird is up.

```bash
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml
```

## Step 5: PostgreSQL HA

Deploy PostgreSQL on both nodes. The primary node is set by `postgresql_primary_node` in `roles/postgresql_repmgr/defaults/main.yml`.

```bash
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml
```

**Important:** The `serial: 1` setting deploys one node at a time. The primary must come up first. If `postgresql_primary_node` is `ns2`, edit the inventory to list ns2 before ns1, or deploy manually:

```bash
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit ns2
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit ns1
```

## Step 6: NetBird Management Server

Deploy the NetBird management server on both nodes:

```bash
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml
```

### Manual Step: Initial NetBird Setup

After the first deployment, open `https://netbird.<your-domain>` in a browser to complete the setup wizard. This creates the admin user and Dex credentials.

Then:

1. Create a **Personal Access Token (PAT)** via the dashboard profile page
2. Create a **Reusable Setup Key** via Settings > Setup Keys (type: reusable, no expiry)
3. Update `group_vars/all.yml` with the PAT and setup key values

## Step 7: NetBird Peer Enrollment

Enroll both servers as NetBird peers:

```bash
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml
```

After enrollment, check the assigned NetBird IPs:

```bash
ssh root@<NS1_IP> "netbird status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"localPeerState\"][\"fqdn\"], json.load(sys.stdin)[\"localPeerState\"][\"ip\"])'"
ssh root@<NS2_IP> "netbird status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"localPeerState\"][\"fqdn\"], json.load(sys.stdin)[\"localPeerState\"][\"ip\"])'"
```

**Update** `inventory/hosts.yml` with the assigned `netbird_ip` values for both nodes, and update all NetBird IP references in `group_vars/all.yml`.

## Step 8: Redeploy with NetBird IPs

Now that NetBird IPs are known, redeploy components that depend on them:

```bash
# PowerDNS nginx proxy (binds to NetBird IP)
ansible-playbook -i inventory/hosts.yml site.yml --limit powerdns_primary --tags powerdns
ansible-playbook -i inventory/hosts.yml site.yml --limit powerdns_secondary --tags powerdns

# Traefik (uses PowerDNS API via NetBird IP for ACME)
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml

# Force-recreate containers to pick up new network bindings
ssh root@<NS1_IP> "cd /opt/powerdns && docker compose up -d --force-recreate nginx"
ssh root@<NS2_IP> "cd /opt/powerdns && docker compose up -d --force-recreate nginx"
```

## Step 9: Verify DNS Replication

```bash
dig @<NS1_IP> example.com SOA +short
dig @<NS2_IP> example.com SOA +short
# Both should return the same serial number
```

## Step 10: Deploy Backups

```bash
ansible-playbook -i inventory/hosts.yml deploy-backup.yml
```

**Manual step:** Register the SSH public key with your Hetzner Storagebox before the first backup run.

## Step 11: Verify Everything

```bash
# PowerDNS
dig @<NS1_IP> netbird.example.com A +short
dig @<NS2_IP> netbird.example.com A +short

# Traefik (valid TLS cert)
curl -I https://netbird.example.com

# PostgreSQL replication
ssh root@<NS1_IP> "docker exec postgresql repmgr cluster show"

# NetBird mesh
ssh root@<NS1_IP> "netbird status"
ssh root@<NS2_IP> "netbird status"

# Backup
ssh root@<NS1_IP> "systemctl status restic-backup.timer"
```

---

## Known Manual Steps

These steps cannot be automated and must be done manually:

1. **NetBird setup wizard** -- browser-based first-user setup
2. **PAT and setup key creation** -- via NetBird dashboard
3. **Storagebox SSH key registration** -- via Hetzner Robot panel
4. **NetBird IP discovery** -- IPs are assigned dynamically on enrollment
5. **DNS NS records** -- must be set at your domain registrar
