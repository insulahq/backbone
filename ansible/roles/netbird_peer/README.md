# NetBird Peer Role

Installs the NetBird peer client and enrolls servers in the WireGuard VPN mesh.

## What It Does

1. Adds the official NetBird apt repository
2. Installs the `netbird` package
3. Enables the systemd service
4. Enrolls the peer with the management server using a setup key
5. Waits for the peer to reach `Connected` state

## Requirements

- `netbird_management` role deployed on ns1 and ns2
- A reusable setup key created via the NetBird dashboard
- `netbird_setup_key` and `netbird_management_url` set in `group_vars/all.yml`

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `netbird_install_method` | `apt` | Installation method |
| `netbird_autostart` | `true` | Start on boot |
| `netbird_log_level` | `info` | Log verbosity |
| `netbird_config_dir` | `/etc/netbird` | Config directory |
| `netbird_peer_hostname` | `{{ inventory_hostname }}` | Peer name in mesh |

## Usage

```bash
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml
```

## Post-Deployment

Check the assigned NetBird IP after enrollment:

```bash
netbird status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["localPeerState"]["ip"])'
```

Update `inventory/hosts.yml` with the `netbird_ip` value for each server.

## Gotchas

- NetBird IPs change on re-enrollment with a fresh database (gotcha 17)
- The NetBird SSH config at `/etc/ssh/ssh_config.d/99-netbird.conf` intercepts all SSH connections, not just NetBird peers (gotcha 9)
