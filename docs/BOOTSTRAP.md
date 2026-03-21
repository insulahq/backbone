# Bootstrap Guide — Fresh Deployment

This guide walks through deploying the Hosting Platform infrastructure from scratch
on two Debian 13 servers.

The deployment uses a **three-phase approach**: infrastructure backbone on both nodes,
then all services on the primary node, then the secondary node joins as replica.
This ensures the primary is fully operational before the secondary is added.

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
> Note: ACME certificate issuance (Phase 2) queries the authoritative nameservers
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

> **Note:** The bootstrapping SSH key is NOT removed from `authorized_keys` — it
> remains as a recovery fallback (`exclusive: false`).

## Phase 2: Services on Primary Node (ns1)

Deploy all services to ns1 only. After this phase, ns1 is fully operational
and serving all traffic.

```bash
ansible-playbook -i inventory/hosts.yml site.yml --tags phase2
```

After Phase 2:
- PowerDNS: zone created, DNS records pointing to ns1
- Traefik: Let's Encrypt wildcard certificate issued
- Zitadel: IAM running at `auth.<domain>` (DB migrations completed)
- NetBird: management server at `vpn.<domain>` with embedded Dex IdP
- Gatus: monitoring dashboard at `status.<domain>`
- Portainer: Docker management at `http://10.100.0.1:9000`
- Backup: Restic timer configured

> **Verify** (wait ~2 minutes for Let's Encrypt):
> ```bash
> echo | openssl s_client -connect <NS1_IP>:443 -servername auth.<domain> 2>/dev/null | openssl x509 -noout -subject -issuer
> ```
> Expected: `issuer=... Let's Encrypt ...`

### Manual Steps (before Phase 3)

**Zitadel admin login:**
1. `cat .generated_secrets/zitadel_admin_password`
2. Open `https://auth.<domain>`, log in with `admin` + password from step 1

**NetBird admin account:**
1. Open `https://vpn.<domain>` — redirected to `/setup`
2. Create admin account (email + password)

**NetBird setup key (required for peer enrollment):**
1. Log in to `https://vpn.<domain>`
2. Settings > Setup Keys > Add Key (Reusable, no usage limit)
3. Set `netbird_setup_key` in `group_vars/all.yml`

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

### Manual Step: Sync NetBird `idp.db` to ns2

The embedded Dex IdP stores user credentials in `/var/lib/netbird/idp.db`
(SQLite inside the Docker volume). This file is **NOT replicated** via
PostgreSQL — it exists only on the node where the admin account was created.

```bash
ssh root@<NS1_IP> "docker cp netbird-server:/var/lib/netbird/idp.db /tmp/idp.db"
scp root@<NS1_IP>:/tmp/idp.db /tmp/idp.db
scp /tmp/idp.db root@<NS2_IP>:/tmp/idp.db
ssh root@<NS2_IP> "docker cp /tmp/idp.db netbird-server:/var/lib/netbird/idp.db && docker restart netbird-server"
```

> **Note:** Repeat this sync whenever new local users are created. If you add
> Zitadel as an external IdP (via Settings > Identity Providers), SSO users
> authenticate against Zitadel directly and don't need `idp.db` sync.

## Phase 4: NetBird Peer Enrollment

Enroll both servers as NetBird peers (requires `netbird_setup_key` from Phase 2).

```bash
ansible-playbook -i inventory/hosts.yml site.yml --tags phase4
```

Peers resolve as `ns1.netbird`, `ns2.netbird` within the mesh.

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

After all manual steps are complete and `group_vars/all.yml` has `netbird_setup_key`
set, you can run `site.yml` without `--tags` to deploy or update everything at once:

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
