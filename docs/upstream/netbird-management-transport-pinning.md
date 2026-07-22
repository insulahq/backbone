# Draft upstream issue — netbirdio/netbird

## Title

Management client pins forever to a live-but-wrong HTTP endpoint (gRPC
`Unimplemented`/404): never resets the READY channel, never re-resolves DNS;
signal + relay recover, management requires a client restart

## Summary

When the management gRPC channel becomes connected to an endpoint that
answers HTTP but does not serve `management.ManagementService` (typical
self-hosted case: a reverse proxy / LB with valid TLS whose management
backend is down or moved — it answers `404` with the dashboard SPA), the
client wedges **permanently**:

- the gRPC channel reports `management connection state READY` in a loop,
- every RPC (`GetServerKey`, health checks) fails with
  `code = Unimplemented desc = unexpected HTTP status code received from
  server: 404 (Not Found); transport: received unexpected content-type
  "text/html"`,
- because the 404 is a *valid HTTP response over a healthy h2 transport*,
  no transport error ever occurs → the channel never enters
  TRANSIENT_FAILURE, never re-resolves DNS, never dials a different address,
- **signal and relay clients recover on their own** through the very same
  hostname once the fault clears; management stays wedged indefinitely
  (observed 5.5 h in production, 30 min in a controlled test with zero
  recovery) until `netbird down && netbird up`.

The practical impact for self-hosted HA setups is severe: any failover in
which a client briefly reaches an LB without the management backend
(DNS-TTL window, LB up before backend, standby node answering with a
dashboard route) permanently strands that peer.

## Environment

- netbird client **0.74.7** (reproduced; also observed in production on
  0.66.2, 0.71.2, 0.74.2, 0.74.3 — version-independent), Debian 13
- netbird-server (combined image) 0.74.7 behind Traefik v3.7,
  self-hosted, embedded Dex IdP, PostgreSQL store
- Management URL of the form `https://vpn.example.com` (port 443)

## Production incident (what led us here)

Two-node HA platform, active-passive DNS (TTL 30). During a failover drill
the primary's Traefik was stopped for 90 s, later the management server
moved to the other node. Six external peers (client versions 0.66.2 →
0.74.7) froze with the `Unimplemented`/404 error at that moment and stayed
management-disconnected for 5.5 hours — through the failover, the failback,
and multiple management restarts — while their signal/relay/p2p sessions
kept half-working. All were fixed instantly by `netbird down && up`.
The management DB still showed them `connected=true` with
`peer_status_last_seen` frozen at the drill timestamp.

## Controlled reproduction (client 0.74.7)

Two experiments on the same idle peer, guard timers disabled, debug logs on:

**A. Clean outage (control): client behaves correctly.**
Reject (`tcp reset`) all traffic to the management endpoint for 2 min.
Client retries ~every 60 s during the outage (`code = Unavailable`),
reconnects **unaided ~30 s after** the rule is removed. No bug.

**B. Live-but-wrong endpoint: permanent wedge.**
DNAT the management endpoint's :443 to a local Traefik that has a valid
cert for the hostname but no management route (a dashboard container
answers `404 text/html` — gRPC `Unimplemented`), and RST the pre-existing
flows so the client redials into it. Hold 5 minutes, then remove the DNAT
(endpoint verified reachable, `HTTP 200`).

Result: management **never recovers** (observed 30 min, error string frozen
at the stale 404 reason). Signal reconnects within seconds of restore;
relay reconnects within seconds; management channel loops
`state READY → GetServerKey → Unimplemented`:

```
08:44:00 DEBG shared/management/client/grpc.go:210: management connection state READY
08:44:00 DEBG shared/management/client/grpc.go:222: failed getting Management Service public key: ... code = Unimplemented ... 404 ... text/html
08:44:02 DEBG shared/signal/client/grpc.go:174: signal connection state READY
08:44:03 DEBG client/internal/engine.go:2200: signal health check: healthy=true
08:44:03 WARN shared/management/client/grpc.go:547: health check returned: ... Unimplemented ... 404 ...
08:44:03 DEBG client/internal/engine.go:2203: management health check: healthy=false
08:44:03 DEBG client/internal/engine.go:2231: relay health check: healthy=true
08:44:05 DEBG shared/management/client/grpc.go:210: management connection state READY
08:44:05 DEBG shared/management/client/grpc.go:222: failed getting Management Service public key: ... Unimplemented ...
...repeats unchanged for 30 minutes...
```

`netbird down && netbird up` recovers immediately (fresh channel → fresh
DNS resolution → correct server).

## Analysis

The transport under the management channel is healthy (TCP + TLS + h2 to a
server that politely answers every request with 404 and h2 keepalive PINGs)
— so from grpc-go's perspective nothing is wrong with the *connection*, only
with every *call*. Nothing in the management client escalates repeated
`Unimplemented` health-check failures into a channel teardown, so the
poisoned transport is reused forever and DNS is never re-resolved. Signal
apparently recreates its connection on health-check failure, which is why
it escapes; management does not.

## Suggested fix

After N consecutive management health-check failures with a non-transport
error (`Unimplemented`/unexpected HTTP status), force-close the client
connection (`ClientConn.Close()` + rebuild, or `ResetConnectBackoff` +
enter idle) so the channel re-resolves and redials. Alternatively treat an
unexpected-HTTP-status response as a transport-level failure.

## Workaround for other self-hosted users

A watchdog that restarts the engine when management stays disconnected
(`netbird status` parsing + `netbird down && up`, cooldown-guarded) — we
ship one as a systemd timer / scheduled task / container healthcheck.

---
*Internal references: repro harness `/var/tmp/wedge-test{,4}.sh` on ns2,
logs `/var/tmp/wedge-test4.log`, pcaps `/var/tmp/wedge-test4.pcap`,
client log `/var/log/netbird/client.log` (window 2026-07-22 08:38–09:15
+02:00). Platform gotchas 148–150.*
