# Common Role

OS hardening, base packages, Docker CE, nftables firewall, fail2ban, and SSH hardening. This is the foundational role that all servers run before any application roles.

## What It Does

1. **Base packages** -- Installs system utilities, `dnsutils`, `nftables`, `fail2ban`, Python 3
2. **Timezone** -- Sets system timezone (default: UTC)
3. **Fail2ban** -- SSH brute-force protection (5 retries, 1h ban, 10min window)
4. **nftables** -- Simple INPUT-drop firewall (see below)
5. **Docker CE** -- Installs from official Docker repo (falls back to `bookworm` codename for Debian trixie)
6. **SSH hardening** -- Disables password auth, enforces pubkey-only

## Firewall Rules (nftables)

The firewall is deliberately simple (gotcha 7: complex NAT rules broke server access). Docker and NetBird manage their own NAT.

| Rule | Condition |
|------|-----------|
| Loopback, established, ICMP | Always |
| DNS (53/tcp+udp) | Host in `dns_servers` group |
| HTTPS (443/tcp) | Host in `dns_servers` group |
| TURN relay (10000/udp) | Host in `dns_servers` group |
| WireGuard (51810/udp) | Always |
| SSH | When `ssh_break_glass_enabled: true` |

**Critical:** After nftables reload, Docker is also restarted because `flush ruleset` wipes Docker's iptables chains (gotcha 2).

## Dependencies

None -- this is the first role in the deployment order.

## Key Variables

| Variable | Source | Purpose |
|----------|--------|---------|
| `timezone` | group_vars | System timezone |
| `ssh_port` | group_vars | SSH port for fail2ban and firewall |
| `ssh_break_glass_enabled` | group_vars | Whether to allow SSH through firewall |

## Gotchas

- Docker `0.0.0.0` port binding bypasses nftables INPUT chain; traffic goes through FORWARD chain (gotcha 1)
- `flush ruleset` in nftables wipes Docker's iptables chains; always restart Docker after nftables changes (gotcha 2)
- Docker repo has no `trixie` codename yet; role falls back to `bookworm` (gotcha in tasks)
