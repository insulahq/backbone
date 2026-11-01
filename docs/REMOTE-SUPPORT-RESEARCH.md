# Remote support (TeamViewer/AnyDesk-style) — research findings

Status: **dropped for now; nothing built or deployed.** Kept as a record so
the research does not have to be repeated. Constraints it was done under:
**no paid licences or certificates, FOSS preferred.** Checked against upstream
source, releases and docs in October 2026. RustDesk versions, CVEs and the
client's file-name config change often: re-check them before reviving this.

In short:

- **Feasible for free:** RustDesk's open-source server plus the official,
  signed RustDesk clients. On Windows the official exe picks up our server
  from its file name, so the client gets a one-click download. macOS, Linux
  and Android need one import step.
- **Not possible for free:** a white-labelled app. A rebranded build is
  unsigned, and Windows 11 Smart App Control blocks unsigned apps. Only the
  download page and the support flow can carry our brand.
- **No safe free console** (accounts, shared address book, OIDC). The most
  complete one has an unpatched device-takeover CVE.
- **Main risk:** the server key travels in every download's file name, so the
  relay is open to anyone who has it. Mitigated with bandwidth caps and a
  blocklist, not with authentication.
- **Rejected:** MeshCentral (Defender flags its agent, actively exploited),
  RustDesk Server Pro and the commercial products (paid), and the others
  under *Rejected*.
- **Effort if revived:** about 4 days in three phases (*Build plan*).

## Goal

A self-hosted remote-support service for client machines:

- a technician connects to a client's desktop: attended (the client reads out
  an ID and one-time password), optionally unattended for managed machines;
- the client gets **one download that runs and is already pointed at our
  server**: no server address or key to type;
- white-label where it is possible for free;
- runs on this platform, monitored, backed up and documented like the other
  services.

## Recommended approach: upstream RustDesk OSS server + official signed clients

**Server:** `hbbs` (ID/rendezvous) + `hbbr` (relay), RustDesk server 1.1.16,
AGPL-3.0.

**Clients:** the official RustDesk 1.5.x binaries, also AGPL-3.0, unmodified.
They are signed and notarized by RustDesk's publisher (PURSLANE, EV
certificate). We only control their *file name* and the config the user
imports.

Why:

- **One click on Windows, for free.** Since 1.5.0 the official exe reads a
  server config from its own file name:
  - `rustdesk-qs-licensed-<config>.exe`, where `<config>` is the client's own
    "Export Server Config" format: reversed URL-safe base64 of
    `{"host","key","api","relay"}`. It is accepted unsigned, so we generate
    it ourselves.
  - Renaming does not touch the Authenticode signature.
  - The parser tolerates the browser's " (1)" suffixes.
  - `-qs-` adds quick-support elevation: one UAC prompt, so the technician
    can also operate admin windows.
- **Sessions are end-to-end encrypted.** P2P over UDP with relay fallback,
  hardware video codecs, audio, file transfer. The relay sees only
  ciphertext.
- **€0:** no licence, no certificates, no Apple fee.

What we give up:

- **The app is branded RustDesk.** We brand the download page and the
  support flow, not the binary. A rebranded binary needs our own build (see
  *Rejected*), and an unsigned build defeats one-click: SmartScreen warns,
  Windows 11 Smart App Control blocks it with no bypass, and macOS needs a
  trip to System Settings. Free signing doesn't fit:
  - **SignPath Foundation** would show "SignPath Foundation" as the publisher
    and is very unlikely to accept a private support fork.
  - **Let's Encrypt** does not issue code-signing certificates.
- **No web console.** The open-source server has no accounts, shared address
  book, OIDC or audit log. Technicians keep their own address books in the
  client. Fine for attended support; see *Console (later, optional)*.
- **Client settings are defaults, not locks.** Without Pro, `approve-mode`,
  `verification-method` and similar can be preset, but the end user can
  change them back. Incoming-only mode and hidden settings pages are
  Pro-only.

## What the client sees

| OS | Steps |
|---|---|
| Windows | Click "Start support" → `rustdesk-qs-licensed-….exe` downloads (signed, verified publisher) → UAC "Yes" → window shows ID + one-time password on our server → reads them out, or clicks Accept. Nothing installed. |
| Windows, managed (unattended) | Technician runs one elevated PowerShell line from the page: downloads the same exe, `--silent-install` (keeps the server config), then `--password` set by the technician. |
| macOS | Download the official notarized DMG from our page, drag to Applications, confirm the first-open prompt. Click "Copy settings" on the page → RustDesk Settings → Network → Unlock → Import Server Config. Grant Screen Recording + Accessibility (step-by-step page; this click can never be skipped, not even with MDM, and macOS 15+ re-asks monthly). Alternative: one `sudo … --config …` line in Terminal. |
| Linux | Install the `.deb`, run one `sudo rustdesk --config …` line. X11 fully works; Wayland is experimental (portal prompt each session, login screen needs X11). |
| Android | Install the APK from our page (or F-Droid), scan the QR code on the page (`config=<string>`), allow screen capture and the RustDesk Input accessibility service. On Android 13+, a sideloaded app first needs "Allow restricted settings". |
| iOS | Cannot be remote-controlled (Apple restriction). |

## Rejected

- **RustDesk Server Pro:** paid. It is the only route to signed, *rebranded*
  RustDesk clients and a supported console.
- **MeshCentral** (Apache-2.0, free):
  - its self-signed Windows agent is flagged by Defender as
    `HackTool:Win32/Meshagent`, so no one-click without a paid certificate;
  - it was under active exploitation in Oct 2026 (emergency 1.3.1, root cause
    undisclosed);
  - weaker sessions: JPEG tiles, no audio.
- **Own rebranded RustDesk build** (rdgen, or a public fork with GitHub
  Actions; free for public repos, which also covers the AGPL source offer):
  - the build-time server variables were removed upstream in 2025, so it
    means patching hbb_common and fallback URLs, and maintaining a fork
    through RustDesk's frequent security releases;
  - unsigned, so blocked by Smart App Control.
  - Only worth it for machines we install ourselves, never for one-click.
- **ControlR:** no ad-hoc sessions yet, pre-1.0.
- **Tactical RMM:** licence limits commercial use, and remote control is
  MeshCentral underneath.
- **NetLock:** effectively closed source.
- **Aspia:** no branding, single maintainer.
- **Apache Guacamole:** no agent and no NAT traversal.
- **Commercial on-prem products:** all paid.

## Build plan (if revived)

### Phase 1 — server + download page

- **Role `rustdesk`**, built like `uptime_kuma`:
  - optional `rustdesk_enabled`, single node `rustdesk_node` (default: first
    DNS server);
  - `meta` dependencies `[]` (UPGRADING.md: meta deps redeploy Traefik/PG);
  - pinned image `rustdesk/rustdesk-server:<exact 1.1.16 tag>`;
  - data in `/opt/rustdesk/data`.
- **hbbs** keeps its default key enforcement (`-k -`). **hbbr gets `-k _`**:
  hbbr's default is an open relay anyone on the internet can use.
- **Ports:**
  - public: 21115/tcp, 21116/tcp+udp, 21117/tcp;
  - not exposed: 21114 and 21118/21119 (API and web-client WebSockets).
- **Networking — try bridge mode with published ports first.** Published
  ports bypass the nftables input chain (gotcha 1), and Docker's DNAT keeps
  the client's IPv4 source address and port, which hbbs needs for hole
  punching and per-IP limits.
  - Check in the hbbs log that real client addresses appear over IPv4 *and*
    IPv6.
  - If not, switch to `network_mode: host` and add input rules to
    `roles/common/templates/nftables.conf.j2` (gotcha 167: host-network
    ports need their own rule).
- **Key pair:**
  - Generate once with the image's `rustdesk-utils genkeypair`.
  - Store in `.generated_secrets/` like other role secrets and deploy it from
    there, so a rebuilt node or a standby serves the same key.
  - Every preconfigured download embeds the public key; losing the private
    key means every client must be reconfigured.
- **DNS:** A/AAAA record for `rd.<domain>` pointing at `rustdesk_node`, not
  `dns_failover_primary`. The service does not move on failover, so it stays
  out of `platform-dns-switch` (see Phase 3 for automatic failover).
- **Download page** `support.<domain>`:
  - Pinned nginx container behind Traefik (router labels, `ratelimit@file`).
  - Ansible template branded with our name and logo, in our language, with a
    consent/privacy note.
  - Detects the OS and shows the matching flow from the table above.
  - **Binaries:** Ansible downloads the official release assets for a pinned
    client version, verifies their SHA-256 (from GitHub's release metadata,
    pinned in role defaults) and serves them unmodified.
    - The Windows exe goes out with
      `Content-Disposition: attachment; filename="rustdesk-qs-licensed-<config>.exe"`.
    - Browsers ignore `download="…"` on cross-origin links, so serving it
      from our own domain is what makes the file name work.
  - **Config string:** Ansible generates it from host + public key; both are
    public. It also feeds the macOS "Copy settings" button, the Linux line
    and the Android QR code (rendered at deploy time, no client-side
    library).
  - **Managed install:** the page carries the elevated PowerShell one-liner
    for unattended installs.
- **Pilot** on real client networks (home router, mobile/CGNAT, corporate
  firewall) and on clean Windows 11 (SmartScreen, Smart App Control,
  Defender), macOS 15/26, Ubuntu (X11 and Wayland) and Android. Record:
  - what the client sees at each step;
  - the P2P vs relayed ratio;
  - relay bandwidth.

### Phase 2 — hardening, monitoring, docs

- **hbbr limits:** `TOTAL_BANDWIDTH` / `SINGLE_BANDWIDTH` sized to the node's
  link. `blocklist.txt` ready for abusers. hbbs's per-IP registration limit
  stays on.
- **fail2ban jail** on the failed-auth log lines hbbs writes since 1.1.15.
- **Gatus:** TCP checks on 21116 and 21117; HTTPS check on the download page.
- **test-suite:** containers healthy; ports reachable from the peer node
  (same pattern as the OpenZiti edge-port test); key present; download page
  serves the current Windows file with the licensed name.
- **Backup:** `/opt` is already in restic. Add a pre-backup `sqlite3 .backup`
  hook so the copy is consistent; Uptime Kuma's live SQLite benefits too.
- **Docs:**
  - `docs/RECOVERY.md`: restore on the other node, re-point DNS, key-loss
    consequences.
  - `docs/UPGRADING.md`: server bumps; client bumps = new pinned assets +
    SHA-256, with **clients ≥ 1.5.0 only** (2026 client CVEs).
  - AGENTS.md / README.md / ROADMAP.md tables and gotchas.
  - `all.example.yml` block.
- **Update sweep:** RustDesk ships security fixes often. Treat client
  releases as security updates for the download page.

### Phase 3 (optional) — automatic failover

Deploy on both nodes and fence hbbs/hbbr to the active node exactly like ntfy
(`enforce_<svc>_fence()` in `pg-role-watchdog.sh.j2`; gotcha 156). Then move
`rd.<domain>` onto the active-passive record and into `platform-dns-switch`.

- The same key pair is on both nodes (Phase 1), and hbbs rebuilds its online
  map from client heartbeats.
- Running sessions drop on failover; clients re-register within seconds.
- **Never run two hbbs at once** (key-mismatch errors): fencing guarantees
  that.
- Each node's SQLite keeps first registrations only, so a periodic
  copy-to-standby (like `ziti-db-sync`) avoids rare `UUID_MISMATCH` errors.
  Test before relying on it.

### Console (later, optional)

Not needed for attended support. If accounts, shared address books or OIDC
become necessary:

- **lejianwen/rustdesk-api** (MIT): generic OIDC (reported working with
  Zitadel), PostgreSQL, logs. But it has had no release since 2025-09 and
  has an **unpatched unauthenticated device-takeover CVE (CVE-2026-111324)**.
  Do not expose it as it stands.
- **sctgdesk-server** (AGPL, active): built into hbbs, SQLite only, API
  still "preliminary".

Re-evaluate both then. The client trusts its API server (it can push
settings), so a weak console is worse than none.

### Effort (rough)

- Phase 1: 2 days, including the pilot on real networks and VMs.
- Phase 2: 1 day.
- Phase 3: 1 day.

## Risks

- **Our key is effectively public.** It is in every download's file name, so
  anyone can use our ID server, and our relay too because hbbr only checks
  that key. The open-source server cannot require a login. Mitigations:
  relay bandwidth caps, blocklist, Gatus/alerting on relay traffic, and a key
  rotation runbook. Rotation means re-issuing the download names; installed
  managed clients need a new `--config`.
- **Scam reputation:** some clients' EDR or IT may block RustDesk. Keep a
  fallback: Windows Quick Assist, or a meeting tool's screen share.
- **The end user can change preset settings** (no Pro locks). Acceptable for
  attended support; for managed machines, re-apply settings with the
  install one-liner.
- **No automatic failover** until Phase 3; restore runbook until then.
- **GDPR:** remote access processes client data. Needed:
  - consent text on the download page;
  - a processing clause in client contracts;
  - visible session indicators left on.

## Key sources

- **Client config parser:** https://github.com/rustdesk/rustdesk/blob/master/src/custom_server.rs
- **Client deployment / CLI:** https://rustdesk.com/docs/en/self-host/client-deployment/
- **Quick-support elevation (`-qs-`):** https://rustdesk.com/docs/en/client/windows/windows-portable-elevation/
- **OSS server:**
  - env vars: https://github.com/rustdesk/rustdesk-server/blob/master/docs/environment-variables.md
  - 1.1.16 release: https://github.com/rustdesk/rustdesk-server/releases/tag/1.1.16
- **Key mismatch / HA FAQ:** https://github.com/rustdesk/rustdesk/wiki/FAQ
- **Android QR import:** https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/mobile/pages/scan_page.dart
- **Smart App Control:** https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/overview
- **SignPath Foundation terms:** https://signpath.org/terms
- **rdgen (own builds):** https://github.com/bryangerlach/rdgen
- **lejianwen/rustdesk-api CVE:** https://nvd.nist.gov/vuln/detail/CVE-2026-111324
