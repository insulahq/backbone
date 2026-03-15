# Bootstrap: Fresh Deployment from Scratch

This document describes how to deploy the infrastructure on two fresh Debian 13 servers.

A single `site.yml` run will **not** work from scratch due to circular dependencies between components. Follow these steps in order.

---

## Prerequisites

1. Two Hetzner VPS with Debian 13 installed
2. Root SSH access to both servers (via a bootstrapping SSH key, e.g., `~/hosting-platform.key`)
3. DNS zone for your domain (e.g., `example.com`) with NS records pointing to your servers
4. Hetzner Storagebox for backups
5. Ansible 2.15+ on your control machine
6. Ansible Galaxy collections installed:

```bash
ansible-galaxy install -r ansible/requirements.yml
```

7. Project directory must NOT be world-writable (Ansible ignores `ansible.cfg` otherwise):

```bash
chmod 755 /path/to/hosting-platform/ansible
```

## Step 1: Configure Inventory and Variables

Before starting, gather the following information:

- **ns1 public IPv4 and IPv6** addresses (from Hetzner console)
- **ns2 public IPv4 and IPv6** addresses (from Hetzner console)
- **Primary domain name** to use for the platform (e.g., `example.com`)
- **Bootstrapping SSH key** file path (e.g., `~/hosting-platform.key`) — the key provisioned by Hetzner or uploaded during server creation
- **Backup SFTP/SSH credentials** (optional) — Hetzner Storagebox username, hostname, and path. If not available, the backup role will be skipped during bootstrap and can be enabled later.

```bash
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
cp ansible/group_vars/all.example.yml ansible/group_vars/all.yml
```

Edit both files:
- Set `ansible_host` and `public_ipv6` for each server in `inventory/hosts.yml`
- Set `platform_domain` in `group_vars/all.yml`
- Update all domain references (e.g., `netbird_dns_records`) to use your domain
- If you have Storagebox credentials, set `backup_storagebox_user`, `backup_storagebox_host`, and `backup_storagebox_path` in `group_vars/all.yml`. If not, set `backup_enabled: false` to skip the backup role.
- Leave `netbird_ip` fields empty for now -- they will be assigned after NetBird enrollment

> **SSH keys:** The `ansible_ssh_private_key_file` in `group_vars/all.yml` points to auto-generated per-server keys in `.generated_secrets/ssh/`. These are created on first run. For this initial bootstrap, you must override with your bootstrapping SSH key using `-e` (see Step 2).

## Step 2: OS Hardening + Docker

Deploy the `common` role to both servers. Use `-e` to override the SSH key with your bootstrapping SSH key (the per-server keys don't exist on the servers yet):

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml --tags common \
  -e 'ansible_ssh_private_key_file=~/hosting-platform.key'
```

This run:
1. **Generates per-server ED25519 keypairs** locally in `.generated_secrets/ssh/` (idempotent)
2. **Deploys each server's public key** to `/root/.ssh/authorized_keys`
3. Installs Docker, nftables, fail2ban, and hardens SSH

After this step, all subsequent `ansible-playbook` commands use the per-server keys automatically -- no more `-e` override needed.

> **Note:** The bootstrapping SSH key is NOT removed from `authorized_keys` — it remains as a recovery fallback alongside the per-server key (`exclusive: false`). Do not manually remove old keys from `authorized_keys` during bootstrap; the bootstrapping SSH key and any Hetzner-provisioned keys are needed for disaster recovery (see `docs/RECOVERY.md`).

> **Verify:** Confirm the per-server key works before proceeding:
> ```bash
> ansible -i inventory/hosts.yml all -m ping
> ```

## Step 3: Traefik

Deploy Traefik on both nodes. It creates the `traefik_public` Docker network needed by NetBird.

> **What to expect:** DNS-01 cert issuance will fail because PowerDNS isn't running yet and Traefik can't reach the API from inside its container (127.0.0.1 is the container, not the host). Traefik starts with a **self-signed default certificate**. All HTTPS services will work but browsers will show security warnings until Step 8 when Traefik is redeployed with the correct PowerDNS API URL.

```bash
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml
```

## Step 4: PostgreSQL HA

Deploy PostgreSQL on the **primary node only** first. The standby cannot start until NetBird IPs are assigned (Step 8).

> **What to expect:** Without NetBird IPs, PostgreSQL binds to 127.0.0.1 (local only). The standby will fail to connect to the primary. Deploy only the primary now; the standby connects after Step 8.

```bash
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit ns2
```

> **Bootstrap workaround:** ns1 needs a local PostgreSQL for PowerDNS (Step 5). Since ns1 can't replicate from ns2 yet, temporarily start ns1's PostgreSQL as an independent primary:
> ```bash
> # On ns1: override REPMGR_INITIAL_ROLE in /opt/postgresql/docker-compose.yml
> # Change: REPMGR_INITIAL_ROLE: "standby" → REPMGR_INITIAL_ROLE: "primary"
> # Then: docker compose up -d
> # After Step 8, this will be redeployed as a proper standby.
> ```

## Step 5: PowerDNS

Deploy PowerDNS on **both nodes**. Each node connects to its own local PostgreSQL. The databases are independent until PG replication is established in Step 8.

> **Important:** Both nodes MUST have PowerDNS running before Traefik can issue ACME certificates. The DNS-01 propagation check queries ALL authoritative nameservers (gotcha #77).

```bash
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml --limit ns2
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml --limit ns1
```

> **Bootstrap workaround — ACME TXT record sync (gotcha #78):** Since ns1 and ns2 have independent PostgreSQL databases, ACME TXT records created by Traefik on ns2's PowerDNS won't be visible on ns1. After Traefik creates the challenge, manually sync the `_acme-challenge` TXT records from ns2 to ns1's PowerDNS API before the propagation check times out (4 minutes).

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

Enroll both servers as NetBird peers. **Enroll ns1 first**, then ns2 with a workaround:

```bash
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml --limit ns1
```

> **Bootstrap workaround for ns2 (gotcha #79):** ns2's NetBird peer can't connect to management when DNS round-robin resolves `netbird.<domain>` to itself (circular dependency). Temporarily force resolution to ns1:
> ```bash
> # On ns2:
> echo '<NS1_PUBLIC_IP> netbird.<your-domain>' >> /etc/hosts
> netbird up --setup-key <SETUP_KEY> --management-url https://netbird.<your-domain> --hostname ns2
> sed -i '/netbird\.<your-domain>/d' /etc/hosts
> ```

After enrollment, check the assigned NetBird IPs:

```bash
ssh root@<NS1_IP> "netbird status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"localPeerState\"][\"fqdn\"], d[\"localPeerState\"][\"ip\"])'"
ssh root@<NS2_IP> "netbird status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"localPeerState\"][\"fqdn\"], d[\"localPeerState\"][\"ip\"])'"
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

The roles auto-create OIDC applications in Zitadel ("Hosting Platform" project) and configure SSO. Each service's login page shows a "Platform OIDC" button alongside local auth.

**Zitadel token settings:** For each OIDC application created in Zitadel (visible in the Hosting Platform project), navigate to **Token Settings** and enable **"Include user's profile info in the ID Token"**. This ensures claim mapping (name, email) works correctly in PowerDNS Admin and NetBird.

## Step 13: Deploy Backups

```bash
ansible-playbook -i inventory/hosts.yml deploy-backup.yml
```

**Manual step:** Register the SSH public key with your Hetzner Storagebox before the first backup run.

> **Important:** The Storagebox SSH key (`restic_ssh_key_src` in `group_vars/all.yml`) is separate from the per-server Ansible SSH keys. By default it points to `~/hosting-platform.key`. If your Storagebox uses a different key, set `restic_ssh_key_src` in `group_vars/all.yml`.

## Step 14: Run System Test Suite

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

---

## Known Manual Steps

These steps cannot be automated and must be done manually:

1. **NetBird setup wizard** -- browser-based first-user setup
2. **PAT and setup key creation** -- via NetBird dashboard
3. **Zitadel service account + PAT** -- via Zitadel Console (enables OIDC for all services)
4. **Zitadel token settings** -- enable "Include user's profile info in the ID Token" per OIDC app
5. **Storagebox SSH key registration** -- via Hetzner Robot panel
6. **NetBird IP discovery** -- IPs are assigned dynamically on enrollment
7. **DNS NS records** -- must be set at your domain registrar
