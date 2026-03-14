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
6. Ansible Galaxy collections installed:

```bash
ansible-galaxy install -r ansible/requirements.yml
```

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

> **What to expect:** DNS-01 cert issuance will fail because PowerDNS isn't running yet and Traefik can't reach the API from inside its container (127.0.0.1 is the container, not the host). Traefik starts with a **self-signed default certificate**. All HTTPS services will work but browsers will show security warnings until Step 8 when Traefik is redeployed with the correct PowerDNS API URL.

```bash
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml
```

## Step 4: PostgreSQL HA

Deploy PostgreSQL on both nodes. The primary node is set by `postgresql_primary_node` in `roles/postgresql_repmgr/defaults/main.yml` (default: ns2).

> **What to expect:** Without NetBird IPs, PostgreSQL binds to 127.0.0.1 (local only) and the peer's `extra_hosts` entry falls back to its public IP. Cross-node replication won't work until Step 8 when NetBird IPs are assigned. The primary starts standalone; the standby starts but can't stream from the primary yet. This is expected.

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

The role automatically creates:
- Base domain A/AAAA records for `example.com` (both server IPs)
- NS glue records for `ns1.example.com` and `ns2.example.com`
- Health-checked LUA records when `dns_health_check_enabled` is true (default)

## Step 6: NetBird Management Server

Deploy the NetBird management server on both nodes:

```bash
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml
```

### Manual Step: Initial NetBird Setup

> **What to expect:** The browser will show a self-signed certificate warning (Traefik doesn't have valid certs yet). Accept the warning and proceed.

After the first deployment, open `https://netbird.<your-domain>` in a browser to complete the setup wizard. This creates the admin user.

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

Now that NetBird IPs are known, redeploy components that bind to them. This is the step where everything comes together: PostgreSQL binds to NetBird IPs (replication starts), Traefik gets the correct PowerDNS API URL (Let's Encrypt certs are issued), and PowerDNS nginx binds to NetBird IPs.

> **What to expect:** After this step, valid TLS certificates should be issued within a few minutes. Browser security warnings should disappear. PostgreSQL replication between nodes should begin.

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

The Gatus role automatically restarts PostgreSQL containers so they can deliver alerts to the Gatus endpoint.

## Step 11: Deploy Portainer

Deploy Portainer CE for Docker management. Bound to NetBird IP only — not publicly accessible.

```bash
ansible-playbook -i inventory/hosts.yml deploy-portainer.yml
```

Access via NetBird mesh: `http://<netbird-ip>:9000`

## Step 12: Zitadel Service Account (enables OIDC for all services)

Create a service account in Zitadel for API access. This enables automated OIDC application creation for Gatus, Portainer, PowerDNS Admin, and NetBird.

1. Open `https://auth.example.com/ui/console` in a browser
2. Go to **Users** → **Service Users** → **New**
3. Create a user (e.g., `platform-admin`)
4. Go to **Personal Access Tokens** → **Generate**
5. Copy the token and add to `group_vars/all.yml`:
   ```yaml
   zitadel_service_pat: "<paste token here>"
   ```
6. Re-deploy all OIDC-enabled services:
   ```bash
   ansible-playbook -i inventory/hosts.yml deploy-gatus.yml
   ansible-playbook -i inventory/hosts.yml deploy-portainer.yml
   ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml
   ansible-playbook -i inventory/hosts.yml deploy-netbird.yml
   ```

The roles auto-create OIDC applications in Zitadel ("Phoenix Host" project) and configure SSO. Each service's login page shows a "Platform OIDC" button alongside local auth.

**Zitadel token settings:** For each OIDC application created in Zitadel (visible in the Phoenix Host project), navigate to **Token Settings** and enable **"Include user's profile info in the ID Token"**. This ensures claim mapping (name, email) works correctly in PowerDNS Admin and NetBird.

## Step 13: Run System Test Suite

Run the comprehensive test suite to verify all components:

```bash
# Full test suite (DNS, TLS, PostgreSQL, NetBird, Zitadel, OIDC, Gatus, Portainer, backup, maintenance)
ansible-playbook -i inventory/hosts.yml test-suite.yml
```

The test suite verifies:
- DNS resolution and SOA consistency across both nodes
- Valid TLS certificates for all public domains
- PostgreSQL HA replication status and application databases
- NetBird peer connectivity and mesh health
- Zitadel OIDC discovery and PAT authentication
- OIDC redirect chains on Gatus, Portainer, PowerDNS Admin, NetBird
- Gatus dashboard health and external push endpoints
- Portainer API accessibility via NetBird
- Backup timer and Storagebox connectivity
- All maintenance timers (Docker cleanup, disk monitor, PG maintenance)
- Container health status (no unhealthy containers)

It prints a pass/fail summary table and exits non-zero on any failure.

To run only specific test groups:
```bash
ansible-playbook -i inventory/hosts.yml test-suite.yml --tags dns
ansible-playbook -i inventory/hosts.yml test-suite.yml --tags postgresql
ansible-playbook -i inventory/hosts.yml test-suite.yml --tags oidc
```

For destructive failover tests (temporarily stops services, then restores):
```bash
ansible-playbook -i inventory/hosts.yml test-suite.yml --tags failover
```

## Step 14: Deploy Backups

```bash
ansible-playbook -i inventory/hosts.yml deploy-backup.yml
```

**Manual step:** Register the SSH public key with your Hetzner Storagebox before the first backup run.

---

## Known Manual Steps

These steps cannot be automated and must be done manually:

1. **NetBird setup wizard** -- browser-based first-user setup
2. **PAT and setup key creation** -- via NetBird dashboard
3. **Zitadel service account + PAT** -- via Zitadel Console (enables OIDC for all services)
7. **Zitadel token settings** -- enable "Include user's profile info in the ID Token" per OIDC app
4. **Storagebox SSH key registration** -- via Hetzner Robot panel
5. **NetBird IP discovery** -- IPs are assigned dynamically on enrollment
6. **DNS NS records** -- must be set at your domain registrar
