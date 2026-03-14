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
```

This installs Docker, nftables, fail2ban, and hardens SSH.

## Step 3: Traefik

Deploy Traefik on both nodes. It creates the `traefik_public` Docker network needed by NetBird.

At this point, cert issuance via DNS-01 will fail (PowerDNS API not yet available). Traefik starts but certs come later.

```bash
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml
```

## Step 4: PostgreSQL HA

Deploy PostgreSQL on both nodes. The primary node is set by `postgresql_primary_node` in `roles/postgresql_repmgr/defaults/main.yml` (default: ns2).

```bash
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml
```

**Important:** The `serial: 1` setting deploys one node at a time. The primary must come up first. If `postgresql_primary_node` is `ns2`, the playbook should be run with ns2 listed first in inventory, or deploy manually:

```bash
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit ns2
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit ns1
```

## Step 5: PowerDNS

Deploy PowerDNS on both nodes. Both connect to the shared PostgreSQL HA cluster (Native mode — both read-write). No AXFR/NOTIFY needed; zone data replicates via PostgreSQL streaming replication.

```bash
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml
```

After deployment, create the DNS A and AAAA records for your NetBird domain:

```bash
# On either node (both have write access):
docker exec powerdns-auth pdnsutil add-record example.com netbird A <NS1_PUBLIC_IP>
docker exec powerdns-auth pdnsutil add-record example.com netbird A <NS2_PUBLIC_IP>

# IPv6 (if your servers have public IPv6 addresses — Hetzner VPS always do)
docker exec powerdns-auth pdnsutil add-record example.com netbird AAAA <NS1_PUBLIC_IPV6>
docker exec powerdns-auth pdnsutil add-record example.com netbird AAAA <NS2_PUBLIC_IPV6>

docker exec powerdns-auth pdnsutil increase-serial example.com
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

Now that NetBird IPs are known, redeploy components that bind to them:

```bash
# Full redeploy (PowerDNS nginx binds to NetBird IP, Traefik uses PowerDNS API via NetBird IP, PostgreSQL binds to NetBird IP)
ansible-playbook -i inventory/hosts.yml deploy-netbird-ha.yml
```

## Step 9: Deploy Zitadel IAM

Deploy Zitadel as the central identity provider. It uses the existing PostgreSQL HA cluster and sits behind Traefik. Deployed with `serial: 1` so the first node runs database migrations before the second starts.

```bash
ansible-playbook -i inventory/hosts.yml deploy-zitadel.yml
```

Zitadel automatically:
- Creates its database and schema in the PostgreSQL HA cluster
- Creates the first instance with the admin user from `group_vars/all.yml`
- Creates DNS A/AAAA records for `auth.example.com` via the PowerDNS API
- Obtains a TLS certificate via Traefik (DNS-01 ACME)

After deployment, verify:

```bash
# Console should be accessible
curl -I https://auth.example.com/ui/console

# OIDC discovery endpoint
curl -s https://auth.example.com/.well-known/openid-configuration | python3 -m json.tool
```

**First login:** Open `https://auth.example.com/ui/console` in a browser. Log in with the admin username from `group_vars/all.yml` and the password from `ansible/.generated_secrets/zitadel_admin_password`. You will be prompted to change the password.

**Important:** The masterkey in `ansible/.generated_secrets/zitadel_masterkey` **cannot be changed** after initialization. Back it up securely.

## Step 10: Deploy Gatus Monitoring

Deploy Gatus as the HA status dashboard and alert receiver. Both servers run Gatus with a shared PostgreSQL backend. Deployed with `serial: 1` so the first node creates the database before the second starts.

```bash
ansible-playbook -i inventory/hosts.yml deploy-gatus.yml
```

Gatus automatically:
- Creates its database in the PostgreSQL HA cluster
- Creates DNS A/AAAA records for `status.example.com` via the PowerDNS API
- Starts receiving push events from all maintenance scripts

After deployment, verify:

```bash
curl -I https://status.example.com
```

**Notification targets:** To forward alerts to Slack, Discord, ntfy, email, etc., set `gatus_alerting_*` variables in `group_vars/all.yml` and re-deploy:

```bash
ansible-playbook -i inventory/hosts.yml deploy-gatus.yml
```

## Step 11: Verify Everything

```bash
# PowerDNS (both nodes serve DNS)
dig @<NS1_IP> example.com SOA +short
dig @<NS2_IP> example.com SOA +short
# Both should return the same SOA (shared database)

# PowerDNS API (both nodes have write access)
curl -s -H "X-API-Key: $KEY" http://<NS1_NETBIRD_IP>:8081/api/v1/servers/localhost/zones
curl -s -H "X-API-Key: $KEY" http://<NS2_NETBIRD_IP>:8081/api/v1/servers/localhost/zones

# Traefik (valid TLS cert)
curl -I https://netbird.example.com

# Zitadel OIDC
curl -s https://auth.example.com/.well-known/openid-configuration | python3 -m json.tool

# PostgreSQL replication
ssh root@<NS1_IP> "docker exec postgresql repmgr cluster show"

# NetBird mesh
ssh root@<NS1_IP> "netbird status"
ssh root@<NS2_IP> "netbird status"

# Backup
ssh root@<NS1_IP> "systemctl status restic-backup.timer"
```

## Step 12: Deploy Backups

```bash
ansible-playbook -i inventory/hosts.yml deploy-backup.yml
```

**Manual step:** Register the SSH public key with your Hetzner Storagebox before the first backup run.

---

## Known Manual Steps

These steps cannot be automated and must be done manually:

1. **NetBird setup wizard** -- browser-based first-user setup
2. **PAT and setup key creation** -- via NetBird dashboard
3. **Storagebox SSH key registration** -- via Hetzner Robot panel
4. **NetBird IP discovery** -- IPs are assigned dynamically on enrollment
5. **DNS NS records** -- must be set at your domain registrar
