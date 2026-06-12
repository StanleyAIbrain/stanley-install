#!/bin/bash
# brain-tunnel-watchdog.sh — silent auto-fixer for the cloudflared tunnel (v1.5.6).
#
# WHY: your brain can be perfectly healthy locally while the PUBLIC side is dark —
# the cloudflared tunnel's connections to Cloudflare's edge can wedge (classic
# signature in the tunnel log: QUIC "timeout: no recent network activity").
# The brain watchdog can't see that (local health stays 200), and the off-box
# liveness Worker can only ALERT, not fix. This closes the gap: if the edge is
# unreachable while the local brain is fine, it restarts the tunnel.
#
# SPEAK-SPEC: this layer NEVER sends Telegram — nothing here touches any token.
# It is a silent mechanic with a local tick log. The off-box Worker remains the
# only loud voice for sustained edge-down (>=4 min = this fixer failed too).
#
# Jurisdiction rules (proven in sandbox + live):
#   - local brain not 200  -> exit silently (the BRAIN watchdog's job, not ours)
#   - edge 200             -> reset state, exit (healthy)
#   - edge down 2 consecutive ticks while local is 200 -> kickstart the tunnel
#     (bootstrap fallback if the job isn't loaded), 10-min cooldown between kicks
#
# Runs chained from brain-watchdog.sh on the same crontab line (see RUNBOOK) —
# no extra cron entry needed.
#
# ============================ CONFIG (edit for your install) ============================
# OPTIONAL but required to enable: your brain's PUBLIC health URL through the tunnel
# (e.g. https://brain.YOUR-DOMAIN/api/health). EMPTY = this watchdog is disabled
# and exits instantly — safe default so a half-configured install can never
# kick a tunnel based on a bad URL.
EDGE="${TW_EDGE_URL:-}"
LABEL="${TW_LABEL:-com.stanleyai.memory-tunnel}"   # your cloudflared launchd label (launchctl list | grep -i cloudflared)
PLIST="${TW_PLIST:-$HOME/Library/LaunchAgents/${LABEL}.plist}"
LOCAL_URL="${TW_LOCAL_URL:-http://127.0.0.1:8765/api/health}"
SDIR="${TW_STATE_DIR:-/tmp/brain-tunnel-watchdog}"
# =======================================================================================

COOLDOWN=600   # min seconds between tunnel kicks

set -u
[ -n "$EDGE" ] || exit 0   # not configured -> disabled, fully silent

mkdir -p "$SDIR"
TICK="$SDIR/tick.log"
F_FAILS="$SDIR/fails"
F_LASTKICK="$SDIR/lastkick"

NOW=$(date +%s)
STAMP=$(date '+%F %T')

log() { echo "$STAMP $1" >> "$TICK"; }

touch "$SDIR/lastrun"   # silent liveness stamp — mtime proves the chain is firing

LOCAL_CODE=$(curl -sS -m 5 -o /dev/null -w "%{http_code}" "$LOCAL_URL" 2>/dev/null)
if [ "$LOCAL_CODE" != "200" ]; then
    # brain itself is down — not a tunnel problem; stay out of the way
    rm -f "$F_FAILS"
    log "tick local=$LOCAL_CODE (brain down — deferring to brain watchdog)"
    exit 0
fi

EDGE_CODE=$(curl -sS -m 15 -o /dev/null -w "%{http_code}" "$EDGE" 2>/dev/null)
if [ "$EDGE_CODE" = "200" ]; then
    rm -f "$F_FAILS"
    exit 0
fi

FAILS=$(( $(cat "$F_FAILS" 2>/dev/null || echo 0) + 1 ))
echo "$FAILS" > "$F_FAILS"
log "tick local=200 edge=$EDGE_CODE consecutive=$FAILS"
[ "$FAILS" -lt 2 ] && exit 0

LASTKICK=$(cat "$F_LASTKICK" 2>/dev/null || echo 0)
[ $(( NOW - LASTKICK )) -lt "$COOLDOWN" ] && exit 0

UID_N=$(id -u)
if ! /bin/launchctl kickstart -k "gui/${UID_N}/${LABEL}" >> "$TICK" 2>&1; then
    log "kickstart failed — bootstrap fallback"
    /bin/launchctl bootstrap "gui/${UID_N}" "$PLIST" >> "$TICK" 2>&1
    /bin/launchctl kickstart "gui/${UID_N}/${LABEL}" >> "$TICK" 2>&1
fi
# KICK-VERIFY: on some Macs launchd ACKs bootstrap/kickstart while the spawn is
# silently PENDED ("pended nondemand spawn"). Trust only a real PID. Verified
# spawn -> cooldown set + fails cleared. Pended -> NO cooldown, fails kept, so
# the very next tick retries kickstart -k against the now-loaded job.
sleep 3
SPAWNED=$(/bin/launchctl list 2>/dev/null | awk -v l="$LABEL" '$3==l && $1 != "-" {print $1}')
if [ -n "$SPAWNED" ]; then
    echo "$NOW" > "$F_LASTKICK"
    rm -f "$F_FAILS"
    log "TUNNEL KICKSTARTED ${LABEL} pid=$SPAWNED (edge was $EDGE_CODE while local 200)"
else
    log "spawn PENDED (no pid) — no cooldown, retrying next tick"
fi
exit 0
