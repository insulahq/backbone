# Ansible Deployment

Ansible playbooks and roles for deploying the hosting platform infrastructure on two Debian 13 servers.

## Roles

| Role | Purpose | Servers |
|------|---------|---------|
| `common` | OS hardening, nftables, Docker CE, fail2ban, monitoring scripts | ns1, ns2 |
| `wireguard` | WireGuard infrastructure tunnel (backbone) | ns1, ns2 |
| `postgresql_repmgr` | PostgreSQL 18 + repmgr 5.5 HA + pgproxy + pg-role-watchdog | ns1, ns2 |
| `powerdns` | PowerDNS 5.0 (Native mode, shared PostgreSQL HA backend) | ns1, ns2 |
| `traefik` | Traefik v3.6 reverse proxy, DNS-01 ACME, rate limiting | ns1, ns2 |
| `zitadel` | Zitadel IAM (OIDC/OAuth2, multi-tenant) | ns1, ns2 |
| `netbird_management` | NetBird server (mgmt + signal + relay, embedded Dex IdP) | ns1, ns2 |
| `netbird_peer` | NetBird peer client enrollment | ns1, ns2 |
| `gatus` | Gatus HA monitoring dashboard + multi-channel alerting | ns1, ns2 |
| `portainer` | Portainer CE Docker management (VPN-only access) | ns1, ns2 |
| `backup` | Restic encrypted backup to SFTP or S3-compatible storage | ns1, ns2 |

## Usage

```bash
cd ansible

# Full deployment (phased: backbone → primary → secondary)
ansible-playbook -i inventory/hosts.yml site.yml

# Individual components
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml
ansible-playbook -i inventory/hosts.yml deploy-zitadel.yml
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml
ansible-playbook -i inventory/hosts.yml deploy-gatus.yml
ansible-playbook -i inventory/hosts.yml deploy-backup.yml

# Operations
ansible-playbook -i inventory/hosts.yml rolling-update.yml   # Zero-downtime updates
ansible-playbook -i inventory/hosts.yml test-suite.yml        # 87 infrastructure tests
ansible-playbook -i inventory/hosts.yml restore.yml           # Backup restore
```

## Configuration

```bash
# Interactive setup (recommended)
bash setup.sh

# Or copy example files manually
cp inventory/hosts.example.yml inventory/hosts.yml
cp group_vars/all.example.yml group_vars/all.yml
```

Both files are gitignored because they contain secrets and server addresses.

## Bootstrap

See [docs/BOOTSTRAP.md](../docs/BOOTSTRAP.md) for the step-by-step fresh deployment procedure.
