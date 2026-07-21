#!/bin/sh
# ==========================================================================
# NetBird Self-Heal Guard — variant for CONTAINERIZED NetBird clients
# ==========================================================================
# For hosts that run the NetBird client as a Docker container (NAS boxes,
# appliances, docker-compose setups) instead of the native package. Same
# state machine as the systemd guard, but the check runs `netbird status`
# inside the container and the remedy is `docker restart` — a container
# restart IS the full engine restart (fresh DNS resolution + signal
# re-registration).
#
# POSIX sh + busybox compatible (no bash required). Run it from cron:
#
#   */2 * * * * /path/to/netbird-selfheal-docker.sh
#
# or, where /etc/cron.d exists:
#   echo '*/2 * * * * root /usr/local/bin/netbird-selfheal-docker.sh' \
#     > /etc/cron.d/netbird-selfheal
#
# No cron and no host access at all? Use the healthcheck + autoheal pattern
# in netbird-selfheal-compose.example.yml instead.
#
# Tunables (env vars, or edit the defaults below):
#   NB_CONTAINER                 container name       (default: netbird)
#   NB_SELFHEAL_STATE_DIR        state directory      (default: /tmp)
#   NB_SELFHEAL_FAIL_THRESHOLD   checks before restart (default: 3)
#   NB_SELFHEAL_COOLDOWN_SECS    min secs between restarts (default: 900)
#
# Project: https://github.com/insulahq/backbone
# ==========================================================================

set -u

NB_CONTAINER="${NB_CONTAINER:-netbird}"
STATE_DIR="${NB_SELFHEAL_STATE_DIR:-/tmp}"
FAIL_THRESHOLD="${NB_SELFHEAL_FAIL_THRESHOLD:-3}"
COOLDOWN_SECS="${NB_SELFHEAL_COOLDOWN_SECS:-900}"

FAIL_FILE="$STATE_DIR/netbird-selfheal.fails"
LAST_RESTART_FILE="$STATE_DIR/netbird-selfheal.last-restart"

log() { echo "$(date): $1"; logger -t netbird-selfheal "$1" 2>/dev/null || true; }

# Container not running — nothing to guard (restart loops are Docker's job
# via the container's restart policy, not ours)
STATE=$(docker inspect "$NB_CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
[ "$STATE" = "running" ] || exit 0

# Same criterion as the other guards; a hung client (exec times out or
# prints nothing) counts as unhealthy, which is exactly right.
STATUS_OUT=$(docker exec "$NB_CONTAINER" netbird status 2>/dev/null || true)
HEALTHY=false
if printf '%s\n' "$STATUS_OUT" | grep -q '^Management: Connected' \
   && printf '%s\n' "$STATUS_OUT" | grep -q '^Signal: Connected'; then
  HEALTHY=true
fi

if [ "$HEALTHY" = "true" ]; then
  rm -f "$FAIL_FILE"
  exit 0
fi

FAILS=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
FAILS=$((FAILS + 1))
echo "$FAILS" > "$FAIL_FILE"
log "management/signal disconnected in container '$NB_CONTAINER' (consecutive check $FAILS/$FAIL_THRESHOLD)"

[ "$FAILS" -lt "$FAIL_THRESHOLD" ] && exit 0

NOW=$(date +%s)
LAST_RESTART=$(cat "$LAST_RESTART_FILE" 2>/dev/null || echo 0)
if [ $((NOW - LAST_RESTART)) -lt "$COOLDOWN_SECS" ]; then
  log "still in cooldown ($((NOW - LAST_RESTART))s since last restart) — skipping"
  exit 0
fi

log "restarting NetBird container '$NB_CONTAINER' (full engine restart)"
echo "$NOW" > "$LAST_RESTART_FILE"
rm -f "$FAIL_FILE"

if docker restart --time 10 "$NB_CONTAINER" >/dev/null 2>&1; then
  log "container restart complete"
else
  log "ERROR — container restart failed"
fi
