# Bootstrap Guide — Fresh Deployment

This guide walks through deploying the Hosting Platform infrastructure from scratch
on two Debian 13 servers.

The deployment follows a **strictly linear** order with **no circular dependencies**.
WireGuard provides the private backbone from Step 2, so all subsequent services
can bind to stable internal IPs from the start.

> **WARNING:** Do NOT run `site.yml` without `--tags` during initial bootstrap.
> Steps 7-8 require manual input (`zitadel_service_pat`, `netbird_setup_key`)
> that is only available after Step 6. Run each step individually as documented below.

## Prerequisites

1. Two Hetzner VPS with Debian 13 (Trixie) installed
2. Root SSH access to both servers (via a bootstrapping SSH key, e.g., `~/hosting-platform.key`)
3. **Ansible control machine** with:
   - Ansible 2.15+
   - `wireguard-tools` — needed to generate WireGuard keys on the controller
   - `openssl` — needed to generate the NetBird datastore encryption key
   - Python 3

4. Ansible Galaxy collections installed:

```bash
ansible-galaxy install -r ansible/requirements.yml
```

5. Project directory must NOT be world-writable (gotcha #73):

```bash
chmod 755 /path/to/hosting-platform/ansible
```

### Installing controller prerequisites

```bash
# Debian/Ubuntu
sudo apt install wireguard-tools openssl python3

# macOS
brew install wireguard-tools openssl python3

# Arch Linux
sudo pacman -S wireguard-tools openssl python
```

## Required Information

Before starting, gather the following:

| Item | Example | Notes |
|------|---------|-------|
| **ns1 public IPv4** | `23.88.111.142` | From Hetzner console |
| **ns1 public IPv6** | `2a01:4f8:1c1a:c11a::1` | From Hetzner console |
| **ns2 public IPv4** | `89.167.125.29` | From Hetzner console |
| **ns2 public IPv6** | `2a01:4f9:c014:523f::1` | From Hetzner console |
| **Primary domain** | `example.com` | The domain this platform will serve |
| **Bootstrapping SSH key** | `~/hosting-platform.key` | Key provisioned by Hetzner or uploaded during server creation |
| **Server timezone** | `Europe/Berlin` | Applied to both servers |
| **NetBird peer DNS domain** | `netbird` | Internal mesh domain — peers resolve as `<host>.<domain>` (e.g., `ns1.netbird`). Default: `netbird` |
| **Backup SFTP credentials** | (optional) | Hetzner Storagebox user/host; set `backup_enabled: false` to skip |

> **CRITICAL — DNS Glue Records:** Before deploying, you MUST configure **glue records**
> at your domain registrar. These servers will host the authoritative DNS for your domain.
> Set the following at your registrar:
>
> - `ns1.example.com` -> `<NS1_PUBLIC_IPV4>` (A record)
> - `ns2.example.com` -> `<NS2_PUBLIC_IPV4>` (A record)
> - `ns1.example.com` -> `<NS1_PUBLIC_IPV6>` (AAAA record, if available)
> - `ns2.example.com` -> `<NS2_PUBLIC_IPV6>` (AAAA record, if available)
> - Set `example.com` NS records to `ns1.example.com` and `ns2.example.com`
>
> DNS propagation takes 24-48 hours. Configure this BEFORE starting deployment.
> Note: ACME certificate issuance (Step 5) queries the authoritative nameservers
> directly, so it works as soon as the glue records are resolvable — you don't need
> to wait for full global propagation.

## Step 1: Configure Inventory and Variables

```bash
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
cp ansible/group_vars/all.example.yml ansible/group_vars/all.yml
```

Edit both files:
- Set `ansible_host` and `public_ipv6` for each server in `inventory/hosts.yml`
- WireGuard IPs are pre-assigned: ns1=`10.100.0.1`, ns2=`10.100.0.2` (adjust if needed)
- Set `platform_domain`, `timezone`, and PostgreSQL passwords in `group_vars/all.yml`

## Step 2: Deploy Common + WireGuard

This step hardens the OS, installs Docker, generates per-server SSH keys, and
establishes the WireGuard tunnel between both servers.

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml --tags common,wireguard \
  -e 'ansible_ssh_private_key_file=~/hosting-platform.key'
```

> All subsequent commands assume you are in the `ansible/` directory.

After this step:
- Per-server SSH keys are deployed (no more `-e` override needed)
- WireGuard tunnel is active between ns1 (`10.100.0.1`) and ns2 (`10.100.0.2`)

> **Verify:**
> ```bash
> ansible -i inventory/hosts.yml all -m ping
> ansible -i inventory/hosts.yml all -m command -a "ping -c 2 -W 2 10.100.0.2"
> ```

> **Note:** The bootstrapping SSH key is NOT removed from `authorized_keys` — it
> remains as a recovery fallback (`exclusive: false`).

## Step 3: Deploy PostgreSQL HA

PostgreSQL binds to WireGuard IPs. Replication works immediately.

```bash
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml
```

The primary (default: ns2) starts first, then the standby clones from it via the
WireGuard tunnel.

## Step 4: Deploy PowerDNS

Both nodes run PowerDNS in Native mode, sharing the same PostgreSQL HA backend.
Zone data replicates automatically via PostgreSQL streaming replication.

```bash
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml
```

The role creates the platform DNS zone and all required records (A, AAAA, NS glue).
The API is accessible only via the WireGuard IP (not publicly exposed).

## Step 5: Deploy Traefik + ACME Wildcard Certificate

Traefik uses the PowerDNS API (via WireGuard IP) for DNS-01 ACME challenges.
Since both nodes share the same zone via PostgreSQL, the certificate issues
successfully on the first attempt.

```bash
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml
```

> **Verify** (wait ~2 minutes for Let's Encrypt):
> ```bash
> echo | openssl s_client -connect <NS1_IP>:443 -servername auth.<domain> 2>/dev/null | openssl x509 -noout -subject -issuer
> ```
> Expected: `issuer=... Let's Encrypt ...`
>
> **If the certificate doesn't appear after 2 minutes**, check Traefik logs:
> ```bash
> ansible -i inventory/hosts.yml ns1 -m command -a "docker logs traefik --tail 50"
> ```
> Common issues:
> - `context deadline exceeded` — Traefik can't reach the PowerDNS API
> - `NXDOMAIN` — DNS zone not created (re-run Step 4)
> - `rate limited` — too many failed attempts, wait 1 hour

## Step 6: Deploy Zitadel IAM

Zitadel provides OIDC/OAuth2 for all services (NetBird, PowerDNS Admin, Portainer, Gatus).

```bash
ansible-playbook -i inventory/hosts.yml deploy-zitadel.yml
```

### Manual Step: Create Zitadel Service Account

After deployment, you need to create a service account with a Personal Access Token (PAT)
that enables automated OIDC app creation for downstream services.

1. Find the admin credentials:
   ```bash
   cat .generated_secrets/zitadel_admin_password
   ```

2. Open `https://auth.<domain>` in your browser

3. Log in with username `admin` and the password from step 1.
   You may be prompted to change the password on first login.

4. Navigate to: **Users** (left sidebar) -> **Service Users** -> **New**

5. Create a service user:
   - **Username:** `platform-automation`
   - **Name:** `Platform Automation`
   - Click **Create**

6. Assign the **IAM_OWNER** role:
   - On the service user page, go to the **Authorizations** tab
   - Click **New**
   - Select **ZITADEL** as the project
   - Select **IAM_OWNER** as the role
   - Click **Save**

7. Generate a Personal Access Token:
   - Go to the **Personal Access Tokens** section (same service user page)
   - Click **New**
   - Set an expiry (or leave unlimited)
   - Click **Add** -> copy the token value

8. Set the token in your config:
   ```bash
   # Add to group_vars/all.yml:
   zitadel_service_pat: "<PASTE_TOKEN_HERE>"
   ```

> **Important:** The `IAM_OWNER` role is required so the service account can create
> OIDC applications and projects via the Management API. Without it, Steps 7-10
> will fail with `403 Forbidden` errors.

## Step 7: Deploy NetBird VPN Mesh

NetBird uses an embedded Dex IdP for local authentication. External identity
providers (Zitadel, Google, etc.) can be added later through the dashboard
Settings > Identity Providers.

```bash
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml
```

The NetBird dashboard is available at `https://vpn.<domain>`.

### Manual Step: Create Admin Account

1. Open `https://vpn.<domain>` — you'll be redirected to `/setup`
2. Create your admin account (email + password)
3. Log in with the new credentials

### Manual Step: Sync `idp.db` to the second node

The embedded Dex IdP stores user credentials in `/var/lib/netbird/idp.db`
(a SQLite file inside the Docker volume). This file is **NOT replicated** via
PostgreSQL — it exists only on the node where the admin account was created.
Without syncing it, logins on the other node will fail.

```bash
# Copy idp.db from ns2 (where admin was created) to ns1:
ssh root@<NS2_IP> "docker cp netbird-server:/var/lib/netbird/idp.db /tmp/idp.db"
scp root@<NS2_IP>:/tmp/idp.db /tmp/idp.db
scp /tmp/idp.db root@<NS1_IP>:/tmp/idp.db
ssh root@<NS1_IP> "docker cp /tmp/idp.db netbird-server:/var/lib/netbird/idp.db && docker restart netbird-server"
```

> **Note:** Repeat this sync whenever new local users are created. If you add
> Zitadel as an external IdP (via Settings > Identity Providers), SSO users
> authenticate against Zitadel directly and don't need `idp.db` sync.

## Step 8: Enroll NetBird Peers

### Manual Step: Create Setup Key

1. Log in to `https://vpn.<domain>`
2. Go to Settings > Setup Keys > Add Key
3. Type: Reusable, no usage limit
4. Set `netbird_setup_key` in `group_vars/all.yml`

Then enroll the peers:

```bash
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml
```

Peers resolve as `ns1.netbird`, `ns2.netbird` within the mesh.

## Step 9: Deploy Portainer

Docker management UI, accessible only via WireGuard IP (`http://10.100.0.x:9000`).

```bash
ansible-playbook -i inventory/hosts.yml deploy-portainer.yml
```

## Step 10: Deploy Gatus Monitoring

HA monitoring dashboard with push alerting.

```bash
ansible-playbook -i inventory/hosts.yml deploy-gatus.yml
```

## Step 11: Deploy Backup

Restic incremental backup to Hetzner Storagebox.

```bash
ansible-playbook -i inventory/hosts.yml deploy-backup.yml
```

> **Manual step:** Register the SSH public key with Hetzner Storagebox
> (displayed by the playbook, add via Hetzner Robot console).

## Post-Deployment Verification

Run the full test suite:

```bash
ansible-playbook -i inventory/hosts.yml test-suite.yml
```

Destructive failover tests (opt-in):

```bash
ansible-playbook -i inventory/hosts.yml test-suite.yml --tags failover
```

## Subsequent Runs

After all manual steps are complete and `group_vars/all.yml` has `zitadel_service_pat`
and `netbird_setup_key` set, you can run `site.yml` without `--tags` to deploy
or update everything at once:

```bash
ansible-playbook -i inventory/hosts.yml site.yml
```

## Troubleshooting

### Recovery from failed bootstrap

If a step fails partway through, it is safe to re-run the same command. All roles
are idempotent — they detect existing state and skip or update as needed.

If PostgreSQL fails on the standby node after the primary is running:
```bash
# Re-run just the standby
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit <STANDBY_NODE>
```

If OIDC app creation fails (e.g., wrong PAT permissions):
1. Fix the service user permissions in Zitadel Console (see Step 6)
2. Re-run the affected deploy playbook — it will retry OIDC creation
