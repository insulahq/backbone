# Bootstrap Guide — Fresh Deployment

This guide walks through deploying the Hosting Platform infrastructure from scratch
on two Debian 13 servers.

The deployment uses a **three-phase approach**: infrastructure backbone on both nodes,
then all services on the primary node, then the secondary node joins as replica.
This ensures the primary is fully operational before the secondary is added.

## Prerequisites

1. Two VPS with Debian 13 (Trixie) installed
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
chmod 755 /path/to/hosting-platform-backbone/ansible
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
| **ns1 public IPv4** | `23.88.111.142` | From provider console |
| **ns1 public IPv6** | `2a01:4f8:1c1a:c11a::1` | From provider console |
| **ns2 public IPv4** | `89.167.125.29` | From provider console |
| **ns2 public IPv6** | `2a01:4f9:c014:523f::1` | From provider console |
| **Primary domain** | `example.com` | The domain this platform will serve |
| **Bootstrapping SSH key** | `~/hosting-platform.key` | Key provisioned by the provider or uploaded during server creation |
| **Server timezone** | `Europe/Berlin` | Applied to both servers |
| **NetBird peer DNS domain** | `netbird` | Internal mesh domain — peers resolve as `<host>.<domain>` (e.g., `ns1.netbird`). Default: `netbird` |
| **Backup SFTP credentials** | (optional) | SFTP backup server user/host; set `backup_enabled: false` to skip |

> **Note:** After Phase 2, you will need to back up the **Zitadel masterkey** from
> `.generated_secrets/zitadel_masterkey`. This key cannot be changed or recovered
> after initialization — see the "Manual Steps (before Phase 3)" section below.

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
> Note: ACME certificate issuance (Phase 2) queries the authoritative nameservers
> directly, so it works as soon as the glue records are resolvable — you don't need
> to wait for full global propagation.

## Step 1: Configure Inventory and Variables

Run the interactive setup script — it asks for your server IPs, domain, and
other details, then generates `inventory/hosts.yml` and `group_vars/all.yml`
with all secrets auto-generated locally:

```bash
cd ansible
bash setup.sh
```

> **Alternative (manual):** Copy the example files and edit by hand:
> ```bash
> cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
> cp ansible/group_vars/all.example.yml ansible/group_vars/all.yml
> ```
> Set server IPs, domain, and generate passwords with `openssl rand -base64 22`.

## Phase 1: Infrastructure Backbone (both nodes)

This phase hardens both servers, establishes the WireGuard tunnel, and deploys
PostgreSQL HA. All three components need both nodes to function.

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml site.yml --tags phase1 \
  -e "ansible_ssh_private_key_file=$HOME/hosting-platform.key"
```

> All subsequent commands assume you are in the `ansible/` directory.

After Phase 1:
- Per-server SSH keys are deployed (no more `-e` override needed)
- WireGuard tunnel is active between ns1 (`10.100.0.1`) and ns2 (`10.100.0.2`)
- PostgreSQL HA: ns1 is primary (read-write), ns2 is standby (read-only)

> **Verify:**
> ```bash
> ansible -i inventory/hosts.yml all -m ping
> ansible -i inventory/hosts.yml all -m command -a "ping -c 2 -W 2 10.100.0.2"
> ```

> **Security:** After verifying per-server SSH keys work (`ansible all -m ping`),
> remove the bootstrapping key from the servers to prevent a permanent backdoor:
> ```bash
> ansible-playbook -i inventory/hosts.yml remove-bootstrap-key.yml
> ```
> This is optional but strongly recommended. After removal, the bootstrap key
> can no longer access the servers — only the per-server keys work.

## Phase 2: Services on Primary Node (ns1)

Deploy all services to ns1 only. After this phase, ns1 is fully operational
and serving all traffic.

```bash
ansible-playbook -i inventory/hosts.yml site.yml --tags phase2
```

After Phase 2:
- PowerDNS: zone created, DNS records pointing to ns1
- Traefik: Let's Encrypt wildcard certificate issued (PowerDNS API available immediately)
- Zitadel: IAM running at `auth.<domain>` (DB migrations completed)
- NetBird: management server at `vpn.<domain>` with embedded Dex IdP
- Gatus: monitoring dashboard at `status.<domain>`
- Portainer: Docker management at `http://10.100.0.1:9000` (admin user auto-created)
- Backup: Restic timer configured (with nightly pg_dumpall)

> **Verify** (wait ~2 minutes for Let's Encrypt):
> ```bash
> echo | openssl s_client -connect <NS1_IP>:443 -servername auth.<domain> 2>/dev/null | openssl x509 -noout -subject -issuer
> ```
> Expected: `issuer=... Let's Encrypt ...`

### Manual Steps (before Phase 3)

**Zitadel admin login:**
1. `cat .generated_secrets/zitadel_admin_password`
2. Open `https://auth.<domain>`, log in with `admin` + password from step 1

> **CRITICAL — Back up the Zitadel masterkey:**
>
> The Zitadel masterkey encrypts all IAM data at rest. It **cannot be changed or
> recovered** after initialization. If this key is lost, all Zitadel data (users,
> OIDC apps, sessions) becomes permanently inaccessible.
>
> ```bash
> # Display the masterkey (copy to your password manager / offline vault)
> cat .generated_secrets/zitadel_masterkey
> ```
>
> Store this key in **at least two** offline locations:
> - Password manager (e.g., 1Password, Bitwarden)
> - Printed copy in a secure physical location
> - Encrypted USB drive in a safe
>
> Do NOT store it in the same infrastructure this platform manages.

**PowerDNS Admin setup:**
1. Open `http://10.100.0.1:8180/register` (via WireGuard or NetBird)
2. Create admin account (first registered user gets admin privileges)
3. Log in and configure the PowerDNS API connection:
   - **PowerDNS API URL:** `http://pdns:8081`
   - **PowerDNS API Key:** `cat .generated_secrets/powerdns_api_key`
   - **PowerDNS Version:** `5.0`
4. **Disable registration** to prevent unauthorized accounts:
   - Settings > Authentication > Local Authentication > disable "Allow users to signup"

> PowerDNS Admin runs on both nodes (port 8180, WireGuard + NetBird only).
> Shared PostgreSQL database — same credentials work on both.

**Portainer admin:**
- Auto-created during deployment. Password in `.generated_secrets/portainer_admin_password`
- Dashboard: `http://10.100.0.1:9000` (via WireGuard tunnel)

**NetBird admin account:**
1. Open `https://vpn.<domain>` — redirected to `/setup`
2. Create admin account (email + password)

**NetBird setup key (for peer enrollment in Phase 4):**
1. Log in to `https://vpn.<domain>`
2. Settings > Setup Keys > Add Key (Reusable, no usage limit)
3. Copy the key — you'll need it in Phase 4

## Phase 3: Services on Secondary Node (ns2)

Deploy the same services to ns2. DB migrations already ran on ns1 in Phase 2,
so ns2 just starts the services and connects to the PG primary via WireGuard.

```bash
ansible-playbook -i inventory/hosts.yml site.yml --tags phase3
```

After Phase 3:
- All services running on both nodes
- DNS active-passive: ns1 preferred, ns2 is failover
- Zitadel and Gatus use multi-host PG connections (`target_session_attrs=read-write`)
  to always reach the current PG primary, regardless of failover state

> **Note:** The NetBird embedded Dex IdP stores user credentials and OIDC
> connector config in PostgreSQL via the `authStore` config (since v0.66.1).
> Activity events are also stored in PostgreSQL via `activityStore`. Both
> are replicated automatically via the PostgreSQL HA cluster — no manual
> sync is needed between nodes.

## Phase 4: NetBird Peer Enrollment

Phase 4 installs the NetBird client on both servers. Enrollment is done
manually after the client is installed.

```bash
ansible-playbook -i inventory/hosts.yml site.yml --tags phase4
```

After the playbook completes, **SSH into each server** and enroll manually
using the setup key from Phase 2:

```bash
# On ns1:
netbird up --setup-key <KEY> --management-url https://vpn.<domain> --hostname ns1

# On ns2:
netbird up --setup-key <KEY> --management-url https://vpn.<domain> --hostname ns2
```

Verify enrollment:

```bash
netbird status
# Expected: Management: Connected, Signal: Connected
```

Peers resolve as `ns1.netbird.vpn`, `ns2.netbird.vpn` within the mesh.

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

After all manual steps are complete (including NetBird peer enrollment),
you can run `site.yml` without `--tags` to deploy or update everything at once:

```bash
ansible-playbook -i inventory/hosts.yml site.yml
```

This deploys Phase 1 → Phase 2 → Phase 3 → Phase 4 in order, ensuring the
primary node is always updated first.

## Troubleshooting

### Recovery from failed bootstrap

If a step fails partway through, it is safe to re-run the same command. All roles
are idempotent — they detect existing state and skip or update as needed.

If PostgreSQL fails on the standby node after the primary is running:
```bash
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml --limit ns2
```

OIDC integration for downstream services (Gatus, PowerDNS Admin, NetBird, Portainer)
is configured manually after all services are confirmed running. See Zitadel Console
documentation for creating OIDC applications.

### Existing deployment: switching PG primary from ns2 to ns1

If you have an existing deployment where ns2 is the PG primary, perform a
repmgr switchover before redeploying:

```bash
# On ns2 (current primary), inside the PG container:
docker exec -it postgresql repmgr standby switchover --siblings-follow

# Verify ns1 is now primary:
docker exec -it postgresql repmgr cluster show
```

Then redeploy with the updated `postgresql_primary_node: ns1` default.
