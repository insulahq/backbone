# NS Servers Operations Guide

**Applies to:** ns1 (`23.88.111.142`, Hetzner Falkenstein) and ns2 (`89.167.125.29`, Hetzner Helsinki)  
**Last Updated:** 2026-03-09 (TSIG added)  
**Status:** Live — both servers provisioned and operational

---

## Overview

ns1 and ns2 are the two external VPS nodes that form the DNS and NetBird mesh foundation of the
platform. They are provisioned entirely via Ansible. **Do not make manual changes** — rerun the
playbook instead.

| Server | Role | NetBird IP | Public IP |
|--------|------|-----------|-----------|
| ns1 | PowerDNS primary + NetBird management | `100.76.182.198` | `23.88.111.142` |
| ns2 | PowerDNS secondary + NetBird peer | `100.76.92.172` | `89.167.125.29` |

**OS:** Debian 13 (trixie)  
**SSH key:** `~/phoenix-host.key`  
**Ansible playbooks:** `ansible/dns.yml`, `ansible/netbird.yml`

---

## Quick Reference

### Run the DNS playbook

```bash
cd ansible
ansible-playbook dns.yml
```

### Run the NetBird playbook

```bash
cd ansible
ansible-playbook netbird.yml
```

### SSH to a server

```bash
ssh -i ~/phoenix-host.key root@23.88.111.142   # ns1
ssh -i ~/phoenix-host.key root@89.167.125.29   # ns2
```

### Check PowerDNS stack on ns1

```bash
ssh -i ~/phoenix-host.key root@23.88.111.142 'docker compose -f /opt/powerdns/docker-compose.yml ps'
```

### Check NetBird peer status

```bash
ssh -i ~/phoenix-host.key root@23.88.111.142 'netbird status'
ssh -i ~/phoenix-host.key root@89.167.125.29 'netbird status'
```

### Access pdns-admin web UI

Browse to `http://100.76.182.198:8082/` from any machine enrolled in the NetBird mesh.
Credentials: created on first login via the setup flow.

---

## Docker Compose Stacks

### ns1 — `/opt/powerdns/`

| Service | Image | Purpose | Ports |
|---------|-------|---------|-------|
| `postgres` | `postgres:16-alpine` | PowerDNS + pdns-admin database backend | internal |
| `pdns` | `powerdns/pdns-auth-49:latest` | Authoritative DNS primary | `0.0.0.0:53` (UDP+TCP), `127.0.0.1:8081` (API) |
| `pdns-admin` | `powerdnsadmin/pda-legacy:latest` | Web UI for DNS zone management | `127.0.0.1:8082` (loopback; DNAT'd from `wt0:8082`) |

### ns2 — `/opt/powerdns/`

| Service | Image | Purpose | Ports |
|---------|-------|---------|-------|
| `pdns` | `powerdns/pdns-auth-49:latest` | Authoritative DNS secondary | `0.0.0.0:53` (UDP+TCP) |

---

## Known Gotchas and Solutions

These are hard-won discoveries from the provisioning process. Each has a corresponding ADR.

---

### 1. Docker `DOCKER` chain wiped by nftables reload

**Symptom:** After `ansible-playbook dns.yml` changes the nftables config, the next container
start (or restart) fails with:

```
iptables: No chain/target/match by that name
```

**Root cause:** `nft -f /etc/nftables.conf` runs `flush ruleset` which wipes all iptables chains
including Docker's `DOCKER`, `DOCKER-USER`, and `DOCKER-ISOLATION-*` chains. When Docker then
tries to add a port mapping, it references a chain that no longer exists.

**Fix (already in place):** The `common/handlers/main.yml` has a handler that listens for
`Reload nftables` and restarts Docker immediately after:

```yaml
- name: Restart Docker after nftables reload
  ansible.builtin.systemd:
    name: docker
    state: restarted
  failed_when: false
  listen: Reload nftables
```

**If you hit this manually:**

```bash
ssh -i ~/phoenix-host.key root@23.88.111.142 \
  'systemctl restart docker && docker compose -f /opt/powerdns/docker-compose.yml down'
# Then re-run the playbook
ansible-playbook dns.yml
```

See: **ADR-018**

---

### 2. DNAT-to-loopback silently dropped (`route_localnet`)

**Symptom:** pdns-admin is confirmed healthy on `127.0.0.1:8082`, the nftables DNAT rule for
`wt0:8082 → 127.0.0.1:8082` is present, but `curl http://100.76.182.198:8082/` from another
NetBird peer returns `000` (no response).

**Root cause:** Linux default `net.ipv4.conf.all.route_localnet = 0` causes the kernel to drop
packets destined for `127.0.0.0/8` that arrive on a non-loopback interface (`wt0`), even after
prerouting DNAT rewrites the destination.

**Fix (already in place):** `ansible.posix.sysctl` sets `route_localnet = 1` on dns_master in
`common/tasks/main.yml`.

**Verify on ns1:**

```bash
sysctl net.ipv4.conf.all.route_localnet
# Expected: net.ipv4.conf.all.route_localnet = 1
```

See: **ADR-019**

---

### 3. Docker binding to specific non-loopback IP fails

**Symptom:** Docker Compose port binding of the form `{{ specific_ip }}:8082:80` fails at
container start when `specific_ip` is a NetBird WireGuard address (e.g. `100.76.182.198`).

**Root cause:** Docker initialises its `DOCKER` iptables chain only for interfaces known when
the daemon starts. A WireGuard-managed IP on `wt0` is not known to Docker's iptables backend,
so the DNAT rule addition fails.

**Fix:** Bind to `127.0.0.1` and use nftables DNAT from `wt0`. See ADR-017.

---

### 4. `psql` connects to wrong default database

**Symptom:** Ansible task running `psql -U pdns` fails with:

```
FATAL: database "pdns" does not exist
```

**Root cause:** `psql` defaults the database name to the username when `-d` is not specified.
The PowerDNS database user is named `pdns` but the maintenance database is `postgres`.

**Fix:** Always use `-d postgres` for admin queries (checking/creating databases):

```bash
docker compose exec -T postgres psql -U pdns -d postgres -tAc \
  "SELECT 1 FROM pg_database WHERE datname='powerdns_admin'"
```

---

### 5. Stale container network state after Docker restart

**Symptom:** After restarting Docker (e.g. to recover from wiped iptables chains), a `docker
compose up` fails trying to "Recreate" a container that already exists in a partially broken
state.

**Fix:** Bring the stack fully down before restarting Docker and running the playbook:

```bash
ssh -i ~/phoenix-host.key root@23.88.111.142 \
  'docker compose -f /opt/powerdns/docker-compose.yml down && systemctl restart docker'
```

---

### 6. nftables DNAT rule and Docker PREROUTING chain coexist

The nftables config adds a `table ip nat { chain prerouting {...} }` block and Docker also
creates a `PREROUTING` chain via `iptables-nft`. Both operate at the `dstnat` priority. This
works because:

- Our `prerouting` chain handles `wt0` traffic and DNATs to `127.0.0.1:8082`
- Docker's `PREROUTING` chain (via iptables-nft) then sees the rewritten destination and jumps
  to `DOCKER` which has its own DNAT rule: `ip daddr 127.0.0.1 tcp dport 8082 → container_ip:80`

The packet is double-DNAT'd (`100.76.182.198:8082` → `127.0.0.1:8082` → `172.18.x.x:80`), which
the kernel connection-tracking handles correctly.

**Verify the full chain:**

```bash
ssh -i ~/phoenix-host.key root@23.88.111.142 'nft list table ip nat'
# Look for: iifname "wt0" tcp dport 8082 dnat to 127.0.0.1:8082
# And:      ip daddr 127.0.0.1 iifname != "br-*" tcp dport 8082 dnat to 172.18.x.x:80
```

---

### 7. ns2 has `/32` Hetzner interface route via internal `enp7s0`

ns2's primary network interface (`eth0`) is a `/32` address. The default gateway is reached via
an internal Hetzner interface (`enp7s0`). This is a Hetzner network topology specific to the
Helsinki location.

NetBird on ns2 reports `connection_ip: 172.19.0.1` (Docker bridge gateway) in `netbird status
--json` output — this is cosmetic. The actual WireGuard P2P tunnel uses the correct public IP
`89.167.125.29` for key exchange.

**Verify P2P is working despite the cosmetic IP:**

```bash
ssh -i ~/phoenix-host.key root@89.167.125.29 'ping -c1 100.76.182.198'
# Should succeed with ~24ms latency (Helsinki → Falkenstein direct)
```

---

### 8. PowerDNS container config file must be mode `0644`

The `powerdns/pdns-auth-49` image runs PowerDNS as uid `953`. The config file mounted at
`/etc/powerdns/pdns.conf` must be mode `0644` — not `0640` — or PowerDNS will fail to read it
at startup with a permissions error.

Ansible template task already enforces `mode: '0644'`.

---

### 9. NetBird `IFaceBlackList` must exclude Docker bridges

NetBird by default advertises all local IPs as WireGuard endpoint candidates, including Docker
bridge IPs (`172.17.x.x`, `172.18.x.x`, etc.). This causes the management server to see
incorrect `connection_ip` values and can interfere with peer connectivity.

The `netbird-client.json.j2` template explicitly blacklists Docker bridge interfaces:

```json
"IFaceBlackList": ["docker0", "br-*", "veth*"]
```

---

### 10. NetBird `store.encryptionKey` must be standard base64

The NetBird management server `config.yaml` requires `store.encryptionKey` to be standard
(not URL-safe) base64-encoded 32 random bytes, **with `=` padding**.

Generate with:

```bash
python3 -c "import base64,os; print(base64.b64encode(os.urandom(32)).decode())"
```

URL-safe base64 (using `-` and `_`) or keys without `=` padding cause the management server to
fail at startup with a cryptic decryption error.

---

### 11. `autosecondary` NOTIFY silently ignored without supermasters entry

**Symptom:** ns2 log shows:
```
Received NOTIFY for phoenix-host.net from 23.88.111.142 for which we are not authoritative, trying autoprimary
Unable to find backend willing to host phoenix-host.net for potential autoprimary 23.88.111.142.
```
Zone never appears on ns2 despite repeated NOTIFY.

**Root cause:** PowerDNS `autosecondary=yes` mode requires the sending primary to be registered
in the `supermasters` (4.9 renamed: `autoprimaries`) table. Without this row, ns2 rejects all
autoprimary NOTIFYs regardless of IP whitelist config.

**Fix (already in place):** Ansible runs `pdnsutil add-autoprimary {{ ns1_public_ip }} ns1.{{ platform_domain }}` on ns2. Verify:

```bash
docker compose -f /opt/powerdns/docker-compose.yml exec -T pdns pdnsutil list-autoprimaries
# Expected: 23.88.111.142  ns1.phoenix-host.net  (account field empty)
```

---

### 12. `pdnsutil import-tsig-key` is not idempotent

**Symptom:** Second Ansible run fails with:
```
ERROR:  duplicate key value violates unique constraint "namealgoindex"
```

**Root cause:** `import-tsig-key` does a plain `INSERT`. Running it again on an existing key
raises a PostgreSQL unique constraint violation (or SQLite equivalent).

**Fix (already in place):** Ansible checks `list-tsig-keys` first and only imports if the key
name is absent.

---

### 13. TSIG key must be activated after every new zone is created

**Symptom:** A new zone created via the Management API transfers to ns2 without TSIG, meaning
ns2 accepts unsigned AXFR for that zone.

**Root cause:** `activate-tsig-key` is zone-level — it must be called for each zone separately
after the zone is created. The Ansible playbook does this for existing zones at deploy time, but
the Management API must also call it for zones it creates.

**Required Management API action:**

After `POST /api/v1/zones` on ns1:
```
pdnsutil activate-tsig-key <zone> axfr-tsig primary   # on ns1
pdnsutil activate-tsig-key <zone> axfr-tsig secondary  # on ns2 (after AXFR)
```

---

## TSIG Zone Transfer Security

AXFR/NOTIFY between ns1 and ns2 is authenticated with HMAC-SHA256 TSIG (key: `axfr-tsig`).

| Property | Status |
|---|---|
| Authenticity | **Yes** — HMAC-SHA256 signed |
| Integrity | **Yes** — any modification invalidates signature |
| Confidentiality | No — zone data is cleartext (it's public DNS data) |
| Replay protection | Yes — 300s timestamp window |

**Verify TSIG is active on a zone:**

```bash
# On ns1:
docker compose -f /opt/powerdns/docker-compose.yml exec -T pdns \
  pdnsutil show-zone phoenix-host.net | grep -i tsig
# Expected: TSIG-ALLOW-AXFR  axfr-tsig

# On ns2:
docker compose -f /opt/powerdns/docker-compose.yml exec -T pdns \
  pdnsutil show-zone phoenix-host.net | grep -i tsig
# Expected: AXFR-MASTER-TSIG  axfr-tsig
```

**Rotate the TSIG key:**

1. Generate new key: `python3 -c "import base64,os; print(base64.b64encode(os.urandom(32)).decode())"`
2. Update `pdns_tsig_key_secret` in `ansible/group_vars/all.yml`
3. Delete old key on both servers: `pdnsutil delete-tsig-key axfr-tsig`
4. Re-run `ansible-playbook dns.yml` — imports new key and re-activates on all zones

---

## Firewall Rules Summary (ns1)

| Port | Proto | Source | Purpose |
|------|-------|--------|---------|
| 22 | TCP | `160.242.115.95` (admin) + rate limit | SSH |
| 53 | UDP+TCP | `0.0.0.0/0` | DNS authoritative |
| 80 | TCP | `0.0.0.0/0` | NetBird ACME HTTP challenge |
| 443 | TCP | `0.0.0.0/0` | NetBird HTTPS (management + dashboard) |
| 3478 | UDP+TCP | `0.0.0.0/0` | NetBird STUN/TURN relay |
| 51820 | UDP | `0.0.0.0/0` | WireGuard data plane |
| 8081 | TCP | `127.0.0.1` | PowerDNS API (localhost only) |
| 8082 | TCP | `wt0` (NetBird) | pdns-admin UI (DNAT'd from wt0) |

## Firewall Rules Summary (ns2)

| Port | Proto | Source | Purpose |
|------|-------|--------|---------|
| 22 | TCP | `160.242.115.95` (admin) + rate limit | SSH |
| 53 | UDP+TCP | `0.0.0.0/0` | DNS secondary |
| 51820 | UDP | `0.0.0.0/0` | WireGuard data plane |

---

## Troubleshooting

### pdns-admin not loading in browser

1. Check the container is healthy: `docker compose -f /opt/powerdns/docker-compose.yml ps`
2. Check it binds to `127.0.0.1:8082`: ports column should show `127.0.0.1:8082->80/tcp`
3. Check route_localnet: `sysctl net.ipv4.conf.all.route_localnet` → must be `1`
4. Check nftables DNAT: `nft list table ip nat` → look for `wt0 tcp dport 8082 dnat to 127.0.0.1:8082`
5. Test from another NetBird peer: `curl -v http://100.76.182.198:8082/`

### DNS not resolving

```bash
# On ns1 or ns2:
dig @23.88.111.142 phoenix-host.net A    # query ns1 directly
dig @89.167.125.29 phoenix-host.net A    # query ns2 directly
# Check container logs:
docker compose -f /opt/powerdns/docker-compose.yml logs pdns
```

### Zone not on ns2 / AXFR not working

```bash
# Check autoprimary is registered on ns2:
docker compose -f /opt/powerdns/docker-compose.yml exec -T pdns pdnsutil list-autoprimaries

# Trigger manual NOTIFY from ns1:
docker compose -f /opt/powerdns/docker-compose.yml exec -T pdns pdns_control notify phoenix-host.net

# Watch ns2 logs for AXFR:
docker compose -f /opt/powerdns/docker-compose.yml logs --tail=20 pdns

# Verify zone exists on ns2:
docker compose -f /opt/powerdns/docker-compose.yml exec -T pdns pdnsutil list-all-zones
```

### NetBird peers not connected

```bash
netbird status   # on each peer
# Look for: Management: Connected, Signal: Connected
# Check peer list for 2/2 Connected
```

### Full re-provision from scratch

If a server is rebuilt from snapshot, the NetBird peer token will be stale. The peer role
generates a one-time setup key via API and re-enrolls only if the peer is not already enrolled.
Force re-enrollment by removing the NetBird state:

```bash
ssh -i ~/phoenix-host.key root@<server_ip> 'netbird down; rm -f /etc/netbird/config.json'
ansible-playbook netbird.yml
```
