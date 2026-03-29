# Backup Role

> **Status:** COMPLETE — Ready for deployment
> **Tool:** Restic 0.16.4
> **Backends:** SFTP or S3-compatible storage (AWS, MinIO, Wasabi, Backblaze B2)

## Overview

This role deploys encrypted incremental backups with:
- **Database:** `pg_dumpall` piped directly to restic (no plaintext on disk)
- **Files:** All service configs + data under `/opt`
- Automated daily backups via systemd timer
- Configurable retention policy (7 daily / 4 weekly / 12 monthly / 2 yearly)
- Weekly 5% data integrity verification
- Failure alerting via Gatus + optional webhook/email
- On-server restore helper script (`/etc/restic/restore.sh`)

**Supported backends:**
- **SFTP** (default) — any SSH/SFTP server (Hetzner Storage Box, rsync.net, etc.)
- **S3** — any S3-compatible service (AWS S3, MinIO, Wasabi, Backblaze B2, etc.)
- ✅ Encrypted backups (repository password)
- ✅ SSH key authentication to backup server

## Architecture

```
Each server (ns1, ns2):
├── Restic binary (/usr/local/bin/restic)
├── Backup script (/etc/restic/backup.sh)
├── Systemd timer (daily at 02:00 + random 5min delay)
├── Encrypted repository (backup server)
└── Logs (/var/log/restic/)

SFTP backup server:
└── /backups/
    ├── ns1/ (Restic repository for ns1)
    └── ns2/ (Restic repository for ns2)
```

## Backup Paths Per Server

Configure in `group_vars/all.yml` or `host_vars/<server>.yml`:

```yaml
# ns1 backup paths
ns1_backup_paths:
  - /opt/powerdns  # PowerDNS config + data
  - /opt/netbird   # NetBird config + SQLite database
  - /etc/restic    # Backup configuration (with password)
  - /root/.ssh     # SSH keys

# ns2 backup paths
ns2_backup_paths:
  - /opt/powerdns  # PowerDNS config + SQLite data
  - /opt/netbird   # NetBird config
  - /etc/restic
  - /root/.ssh
```

## Requirements

- SSH key configured for backup server access
- backup server credentials in group_vars

## Role Variables

### Required Variables

Set in `group_vars/all.yml`:

```yaml
# backup server credentials
backup_sftp_user: "user@example"
backup_sftp_host: "sftp.example.com"
backup_sftp_path: "/backups"

# Restic repository password (store in vault)
restic_password: "<64-char-random-string>"
```

### Default Variables

See `defaults/main.yml` for all options.

**Key defaults:**
- `restic_version: "0.16.4"`
- `restic_backup_time: "02:00"` (2 AM daily)
- `restic_keep_daily: 7`
- `restic_keep_weekly: 4`
- `restic_keep_monthly: 12`
- `restic_keep_yearly: 2`

## Dependencies

None (standalone role).

## Example Playbook

```yaml
- name: Deploy backup on all servers
  hosts: all
  roles:
    - backup
```

## Deployment

```bash
cd /config/hosting-platform-backbone/ansible

# Deploy to all servers
ansible-playbook site.yml --tags backup

# Or specific server
ansible-playbook site.yml --limit ns1 --tags backup
```

## Post-Deployment

### Verify Backup Configuration

```bash
# Check timer is enabled
systemctl status restic-backup.timer

# View next scheduled backup
systemctl list-timers restic-backup.timer

# Run manual backup
systemctl start restic-backup.service

# View backup logs
journalctl -u restic-backup.service -f
```

### List Snapshots

```bash
# Set environment
export RESTIC_REPOSITORY="sftp:user@example@sftp.example.com:/backups/ns1"
export RESTIC_PASSWORD_FILE="/etc/restic/password"

# List all snapshots
restic snapshots

# List snapshots for specific host
restic snapshots --host ns1
```

### Restore Files

```bash
# Restore latest snapshot to /tmp/restore
restic restore latest --target /tmp/restore

# Restore specific file
restic restore latest --target /tmp/restore --include /opt/powerdns/pdns.conf

# Restore specific snapshot
restic restore abc123 --target /tmp/restore
```

## Monitoring

Monitor backup success via:
- Systemd timer status: `systemctl status restic-backup.timer`
- Backup logs: `/var/log/restic/backup-<hostname>.log`
- Snapshot count: `restic snapshots | wc -l`
- Repository size: `restic stats`

## Troubleshooting

### Backup failing

```bash
# View detailed logs
journalctl -u restic-backup.service -n 100

# Test SSH connection
ssh user@example@sftp.example.com echo OK

# Test Restic repository
export RESTIC_REPOSITORY="sftp:user@example@sftp.example.com:/backups/ns1"
export RESTIC_PASSWORD_FILE="/etc/restic/password"
restic snapshots
```

### Repository corrupt

```bash
# Check repository integrity
restic check

# Repair repository (if needed)
restic repair index
restic repair snapshots
```

## License

Proprietary — Hosting Platform internal infrastructure

## Author

Hosting Platform Platform Team
