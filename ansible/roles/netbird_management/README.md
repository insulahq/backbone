# NetBird Management Role

Deploys NetBird Management + Signal + Relay on both ns1 and ns2 with PostgreSQL HA backend.

## Architecture

Both ns1 and ns2 run the full NetBird stack behind Traefik (HTTPS). DNS round-robin on `vpn.<domain>` distributes clients between both nodes.

- **Database:** PostgreSQL HA (deployed by `postgresql_repmgr` role), multi-host DSN with `target_session_attrs=read-write`
- **IdP:** Zitadel (external OIDC provider). No embedded IdP — Zitadel is the sole authentication provider
- **Failover:** DNS round-robin (TTL 60s). If one node goes down, clients reconnect to the other within ~60s

## Dependencies

Must be deployed after:
1. `common` -- Docker CE
2. `traefik` -- HTTPS reverse proxy for dashboard/API
3. `postgresql_repmgr` -- PostgreSQL HA database

## Key Variables

Set in `group_vars/all.yml`:

| Variable | Description |
|----------|-------------|
| `netbird_management_url` | Dashboard URL (e.g., `https://vpn.example.com`) |
| `netbird_postgres_dsn` | Multi-host PostgreSQL DSN |
| `netbird_relay_auth_secret` | Relay authentication secret |
| `netbird_datastore_encryption_key` | Datastore encryption key |
| `powerdns_api_url` | PowerDNS API for DNS-01 ACME |
| `powerdns_api_key` | PowerDNS API key |

## Post-Deployment

After first deploy, complete the browser-based setup wizard at `https://vpn.<domain>`:
1. Create admin user
2. Create Personal Access Token (PAT) via profile page
3. Create reusable setup key via Settings > Setup Keys
4. Update `group_vars/all.yml` with PAT and setup key values

## Gotchas

- NetBird IPs change on re-enrollment with a fresh PostgreSQL database (gotcha 17)
- Boot-time circular dependency: netbird-server joins `postgresql_default` Docker network and uses `host=postgresql` DSN to avoid deadlock (gotcha 24)
- Each node lists itself first in the multi-host DSN to avoid 30s timeouts (gotcha 38)
- Dashboard auth breaks after restart; clear cookies and re-login (gotcha 36)
