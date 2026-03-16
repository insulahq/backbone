# Traefik Role

Deploys Traefik v3.6 as a shared reverse proxy with automatic TLS via DNS-01 ACME challenges against the local PowerDNS API.

## Architecture

Each node runs its own Traefik instance that uses its **own local PowerDNS API** for DNS-01 challenges. No single point of failure -- if one node is down, the other renews certificates independently.

A shared `traefik_public` Docker network is created with a fixed subnet. Other stacks (NetBird, PowerDNS-Admin) attach to this network as `external: true` for TLS termination.

## What It Does

1. **Creates `traefik_public` Docker network** with fixed subnet (`172.31.0.0/24`)
2. **Creates `acme.json`** with mode `0600` for Let's Encrypt certificate storage
3. **Deploys Traefik container** with Docker provider, HTTP-to-HTTPS redirect, DNS-01 ACME
4. **Waits for port 443** to confirm Traefik is serving

## Dependencies

Must be deployed after:
1. `common` -- Docker CE

Should be deployed before:
- `netbird_management` -- NetBird needs Traefik for HTTPS
- `powerdns` -- PowerDNS-Admin UI routes through Traefik (optional)

## Key Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `traefik_version` | `v3.6` | Traefik Docker image tag |
| `traefik_install_dir` | `/opt/traefik` | Host directory for compose + acme.json |
| `traefik_public_network` | `traefik_public` | Shared Docker network name |
| `traefik_public_subnet` | `172.31.0.0/24` | Docker network subnet |
| `traefik_container_ip` | `172.31.0.254` | Fixed IP for Traefik (used as trustedHTTPProxy) |
| `traefik_pdns_api_url` | `http://{{ wireguard_ip }}:8081` | Local PowerDNS API endpoint |
| `traefik_acme_email` | `admin@{{ platform_domain }}` | Let's Encrypt registration email |
| `powerdns_api_key` | (external) | PowerDNS API key (passed as env var) |

## Network Topology

- **Port 80** -- HTTP, redirects to HTTPS
- **Port 443** -- HTTPS, TLS termination for all services
- **Docker provider** -- Auto-discovers services via labels (`exposedByDefault: false`)
- **DNS-01 ACME** -- Uses local PowerDNS API for certificate challenges
