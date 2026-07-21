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
| `netbird_selfheal_enabled` | `true` | Deploy the self-heal guard (gotcha 148) |
| `netbird_selfheal_interval` | `2min` | Guard check cadence |
| `netbird_selfheal_fail_threshold` | `3` | Consecutive failed checks before engine restart |
| `netbird_selfheal_cooldown_secs` | `900` | Minimum seconds between restarts (flap guard) |
| `netbird_peer_min_version` | `""` | When set, upgrade clients below this version |

## Self-Heal Guard (gotcha 148)

`netbird-selfheal.timer` checks `netbird status` every 2 minutes. If management
or signal stay disconnected for 3 consecutive checks (~6 min), it runs the full
`netbird down && netbird up` cycle — the automated version of the manual
stranded-peer remedy. This is the only mechanism that recovers a peer after a
hard failure of the primary node, because it needs no server-side reachability.

For unmanaged machines (customer laptops/servers outside Ansible), install the
same guard with `scripts/netbird-selfheal-install.sh` from the repo root.

## Usage

```bash
ansible-playbook -i inventory/hosts.yml deploy-netbird-peers.yml
```

## Post-Deployment

Check the assigned NetBird IP after enrollment:

```bash
netbird status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["localPeerState"]["ip"])'
```

The NetBird IP is separate from the WireGuard infrastructure IP (`wireguard_ip` in inventory).

## Gotchas

- NetBird IPs change on re-enrollment with a fresh database (gotcha 17)
- The NetBird SSH config at `/etc/ssh/ssh_config.d/99-netbird.conf` intercepts all SSH connections, not just NetBird peers (gotcha 9)
