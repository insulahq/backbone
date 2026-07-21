#!/bin/sh
# ==========================================================================
# NetBird Self-Heal Guard — standalone installer for unmanaged peers
# ==========================================================================
# Installs a systemd timer that restarts the NetBird engine (netbird down &&
# netbird up) when management/signal stay disconnected — so the peer recovers
# automatically after a NetBird server failover instead of dangling until
# someone runs the restart by hand.
#
# Managed platform nodes get the same guard via the netbird_peer Ansible role;
# this script is for customer/external machines outside Ansible's reach.
#
# Requirements: Linux with systemd, NetBird client installed.
# Usage:        sudo ./netbird-selfheal-install.sh
#
# Tunables (set as env vars before running):
#   NB_SELFHEAL_INTERVAL        check cadence          (default: 2min)
#   NB_SELFHEAL_FAIL_THRESHOLD  checks before restart  (default: 3)
#   NB_SELFHEAL_COOLDOWN_SECS   min secs between restarts (default: 900)
#
# Project: https://github.com/insulahq/backbone
# ==========================================================================

set -eu

INTERVAL="${NB_SELFHEAL_INTERVAL:-2min}"
FAIL_THRESHOLD="${NB_SELFHEAL_FAIL_THRESHOLD:-3}"
COOLDOWN_SECS="${NB_SELFHEAL_COOLDOWN_SECS:-900}"

if [ "$(id -u)" != "0" ]; then
  echo "ERROR: must run as root (sudo)" >&2
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemd is required" >&2
  exit 1
fi
if ! command -v netbird >/dev/null 2>&1; then
  echo "ERROR: netbird client not found — install it first (https://netbird.io)" >&2
  exit 1
fi

cat > /usr/local/bin/netbird-selfheal.sh <<EOF
#!/bin/bash
# NetBird Self-Heal Guard — restarts the engine when management/signal stay
# disconnected. Installed by netbird-selfheal-install.sh
# (https://github.com/insulahq/backbone).
set -u

FAIL_FILE=/run/netbird-selfheal.fails
LAST_RESTART_FILE=/run/netbird-selfheal.last-restart
FAIL_THRESHOLD=${FAIL_THRESHOLD}
COOLDOWN_SECS=${COOLDOWN_SECS}

log() { echo "\$(date): \$1"; logger -t netbird-selfheal "\$1" 2>/dev/null || true; }

systemctl is-active netbird >/dev/null 2>&1 || exit 0
[ -f /etc/netbird/config.json ] || exit 0

STATUS_OUT=\$(timeout 15 netbird status 2>/dev/null || true)
HEALTHY=false
if printf '%s\n' "\$STATUS_OUT" | grep -q '^Management: Connected' \\
   && printf '%s\n' "\$STATUS_OUT" | grep -q '^Signal: Connected'; then
  HEALTHY=true
fi

if [ "\$HEALTHY" = "true" ]; then
  rm -f "\$FAIL_FILE"
  exit 0
fi

FAILS=\$(cat "\$FAIL_FILE" 2>/dev/null || echo 0)
FAILS=\$((FAILS + 1))
echo "\$FAILS" > "\$FAIL_FILE"
log "management/signal disconnected (consecutive check \$FAILS/\$FAIL_THRESHOLD)"

[ "\$FAILS" -lt "\$FAIL_THRESHOLD" ] && exit 0

NOW=\$(date +%s)
LAST_RESTART=\$(cat "\$LAST_RESTART_FILE" 2>/dev/null || echo 0)
if [ \$((NOW - LAST_RESTART)) -lt "\$COOLDOWN_SECS" ]; then
  log "still in cooldown (\$((NOW - LAST_RESTART))s since last restart) — skipping"
  exit 0
fi

log "restarting NetBird engine (netbird down && netbird up)"
echo "\$NOW" > "\$LAST_RESTART_FILE"
rm -f "\$FAIL_FILE"

if ! { timeout 30 netbird down; sleep 2; timeout 90 netbird up; }; then
  log "engine restart failed — falling back to daemon restart"
  systemctl restart netbird 2>&1 || log "ERROR — daemon restart failed too"
fi

log "engine restart complete"
EOF
chmod 0755 /usr/local/bin/netbird-selfheal.sh

cat > /etc/systemd/system/netbird-selfheal.service <<EOF
[Unit]
Description=NetBird Self-Heal Guard
After=netbird.service

[Service]
Type=oneshot
TimeoutStartSec=180
ExecStart=/usr/local/bin/netbird-selfheal.sh
EOF

cat > /etc/systemd/system/netbird-selfheal.timer <<EOF
[Unit]
Description=NetBird Self-Heal Guard (stranded-peer recovery)
After=netbird.service

[Timer]
OnBootSec=3min
OnUnitActiveSec=${INTERVAL}
AccuracySec=30
RandomizedDelaySec=20

[Install]
WantedBy=timers.target multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now netbird-selfheal.timer

echo "OK: netbird-selfheal.timer installed and running (every ${INTERVAL},"
echo "    restart after ${FAIL_THRESHOLD} failed checks, ${COOLDOWN_SECS}s cooldown)."
echo "    Watch it with: journalctl -t netbird-selfheal -f"
