#!/bin/bash
# brain-watchdog.sh — unattended self-heal for the Brain memory server.
#
# WHY: on some Macs launchd is degraded — KeepAlive/RunAtLoad do not reliably
# respawn the service after a crash/stop; only an explicit `launchctl kickstart`
# brings it back. Cron (com.vix.cron) ticks independently of launchd, so this
# watchdog lives in your crontab (every minute) and kickstarts the service if
# its health endpoint stops answering.
#
# SPEAK-SPEC — silent except exactly two cases:
#   DOWN -> FIXED        -> ONE Telegram: "<NAME> was down at HH:MM, restarted, back up."
#   DOWN -> FIX-FAILED   -> ONE Telegram: "<NAME> down, restart FAILED — needs you."
# No heartbeat, no daily ping, no "OK/healthy" — routine output goes only to the
# local tick log. 30-min outbound cooldown (flap guard). After FIX-FAILED it keeps
# re-kicking silently; the FIXED message that closes a FAILED incident is allowed
# even inside cooldown (retracting "needs you" beats silence).
#
# ============================ CONFIG (edit for your install) ============================
# All values are overridable by env vars so the same script serves prod + sandbox.
LABEL="${WD_LABEL:-com.stanleyai.memory-server}"                                   # your launchd label
PLIST="${WD_PLIST:-$HOME/Library/LaunchAgents/${LABEL}.plist}"
HEALTH="${WD_HEALTH:-http://127.0.0.1:8765/api/health}"                            # your brain's local health URL
NAME="${WD_NAME:-Brain}"                                                           # name used in alert text
# Telegram credentials file: a file containing TWO lines —
#   TELEGRAM_BOT_TOKEN=123:abc
#   TELEGRAM_CHAT_ID=123456789
# (the token is read from this file and passed to curl via -K, so it never appears
#  in `ps` output or on the command line). chmod 600 it.
CREDS="${WD_CREDS:-$HOME/.config/brain/telegram.env}"
SDIR="${WD_STATE_DIR:-/tmp/brain-watchdog}"
FAILWIN="${WD_FAILWIN:-180}"   # seconds after a kick before declaring FIX-FAILED (model load ~33s)
# =======================================================================================

REKICK=180                      # silent re-kick interval while still down
COOLDOWN=1800                   # 30-min outbound cooldown

set -u
mkdir -p "$SDIR"
TICK="$SDIR/tick.log"           # local log only — NEVER Telegram
F_FAILS="$SDIR/fails"           # consecutive failed checks (pre-incident)
F_DOWNSINCE="$SDIR/down_since"  # epoch of first failed check of open incident
F_KICKED="$SDIR/kicked_ts"      # epoch of last kickstart attempt
F_FAILEDSENT="$SDIR/failed_sent"
F_LASTOUT="$SDIR/last_out"

NOW=$(date +%s)
STAMP=$(date '+%F %T')
DOMAIN="gui/$(id -u)"

log() { echo "$STAMP $1" >> "$TICK"; }

tg() {
    local TOKEN CHAT RC
    TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$CREDS" 2>/dev/null | cut -d= -f2- | tr -d '"')
    CHAT=$(grep -E '^TELEGRAM_(CHAT_ID|JASON_CHAT_ID)=' "$CREDS" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
    [ -n "$TOKEN" ] && [ -n "$CHAT" ] || { log "tg SKIP (no creds in $CREDS)"; return 1; }
    # token goes through a -K config fd (process substitution), never argv or disk:
    RC=$(curl -sS -m 10 -o /dev/null -w "%{http_code}" \
         -K <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TOKEN") \
         --data-urlencode "chat_id=${CHAT}" --data-urlencode "text=$1" 2>/dev/null)
    log "tg sent rc=$RC: $1"
    echo "$NOW" > "$F_LASTOUT"
    [ "$RC" = "200" ]
}

cooldown_ok() {
    local LAST; LAST=$(cat "$F_LASTOUT" 2>/dev/null || echo 0)
    [ $(( NOW - LAST )) -ge "$COOLDOWN" ]
}

kick() {
    if ! /bin/launchctl kickstart -k "${DOMAIN}/${LABEL}" >> "$TICK" 2>&1; then
        log "kickstart failed — bootstrap fallback"
        /bin/launchctl bootstrap "$DOMAIN" "$PLIST" >> "$TICK" 2>&1
        /bin/launchctl kickstart "${DOMAIN}/${LABEL}" >> "$TICK" 2>&1
    fi
    echo "$NOW" > "$F_KICKED"
    log "KICKSTARTED ${LABEL}"
}

CODE=$(curl -sS -m 5 -o /dev/null -w "%{http_code}" "$HEALTH" 2>/dev/null)
log "tick health=$CODE"

if [ "$CODE" = "200" ]; then
    rm -f "$F_FAILS"
    if [ -f "$F_KICKED" ]; then
        DS=$(cat "$F_DOWNSINCE" 2>/dev/null || cat "$F_KICKED")
        SINCE=$(date -r "$DS" '+%H:%M' 2>/dev/null || echo "?")
        if cooldown_ok || [ -f "$F_FAILEDSENT" ]; then
            tg "${NAME} was down at ${SINCE}, restarted, back up."
        else
            log "FIXED (message suppressed by cooldown)"
        fi
        rm -f "$F_KICKED" "$F_DOWNSINCE" "$F_FAILEDSENT"
    fi
    exit 0
fi

# ---- failure path ----
if [ -f "$F_KICKED" ]; then
    KICKED=$(cat "$F_KICKED")
    if [ $(( NOW - KICKED )) -ge "$FAILWIN" ]; then
        if [ ! -f "$F_FAILEDSENT" ]; then
            if cooldown_ok; then tg "${NAME} down, restart FAILED — needs you."
            else log "FIX-FAILED (message suppressed by cooldown)"; fi
            echo "$NOW" > "$F_FAILEDSENT"
        fi
        [ $(( NOW - KICKED )) -ge "$REKICK" ] && kick
    fi
    exit 0
fi

FAILS=$(( $(cat "$F_FAILS" 2>/dev/null || echo 0) + 1 ))
echo "$FAILS" > "$F_FAILS"
if [ "$FAILS" -ge 2 ]; then
    date -v -1M +%s > "$F_DOWNSINCE" 2>/dev/null || echo "$NOW" > "$F_DOWNSINCE"
    rm -f "$F_FAILS"
    kick   # SILENT — the message comes on the outcome (FIXED or FIX-FAILED)
fi
exit 0
