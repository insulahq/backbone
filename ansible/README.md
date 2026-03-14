# Ansible Deployment

Ansible playbooks and roles for deploying Phoenix Host infrastructure on two Debian 13 servers.

## Roles

| Role | Purpose | Servers |
|------|---------|---------|
| `common` | OS hardening, nftables, Docker CE, fail2ban | ns1, ns2 |
| `powerdns` | PowerDNS 4.9 (Native mode, shared PostgreSQL HA backend) | ns1, ns2 |
| `traefik` | Traefik v3.6 reverse proxy, DNS-01 ACME via local PowerDNS | ns1, ns2 |
| `postgresql_repmgr` | PostgreSQL 18 + repmgr 5.5 HA | ns1, ns2 |
| `netbird_management` | NetBird combined server (PostgreSQL backend) | ns1, ns2 |
| `netbird_peer` | NetBird peer client enrollment | ns1, ns2 |
| `backup` | Restic backup to Hetzner Storagebox | ns1, ns2 |

## Usage

```bash
cd ansible

# Full deployment (all roles in dependency order)
ansible-playbook -i inventory/hosts.yml site.yml

# Individual components
ansible-playbook -i inventory/hosts.yml deploy-traefik.yml
ansible-playbook -i inventory/hosts.yml deploy-postgresql.yml
ansible-playbook -i inventory/hosts.yml deploy-powerdns.yml
ansible-playbook -i inventory/hosts.yml deploy-netbird.yml
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml
ansible-playbook -i inventory/hosts.yml deploy-netbird-ha.yml
ansible-playbook -i inventory/hosts.yml deploy-backup.yml
```

## Configuration

Copy example files and fill in your values:

```bash
cp inventory/hosts.example.yml inventory/hosts.yml
cp group_vars/all.example.yml group_vars/all.yml
```

Both files are gitignored because they contain secrets and IP addresses.

## Bootstrap

Fresh deployment requires multiple runs due to circular dependencies.
See [docs/BOOTSTRAP.md](../docs/BOOTSTRAP.md) for the step-by-step procedure.
