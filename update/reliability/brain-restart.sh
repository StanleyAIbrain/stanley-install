#!/bin/bash
# brain-restart.sh — THE one way to stop/start/restart the Brain memory server.
#
# WHY this exists: on some Macs `launchctl load`/`bootstrap` alone does NOT spawn
# the service (launchd defers nondemand spawns), and KeepAlive does not reliably
# respawn after a kill. The lesson, learned the hard way: a maintenance session
# that did `launchctl unload -> work -> launchctl load` left the brain DOWN because
# `load` never spawned it. Use THIS script for every stop/start so that:
#   - `start`/`restart` use `kickstart` (the reliable spawn) and NEVER exit 0
#     without a verified local HTTP 200;
#   - failure alerts you (Telegram) and exits non-zero instead of silently leaving
#     the brain down.
#
# ============================ CONFIG (edit for your install) ============================
LABEL="${BR_LABEL:-com.stanleyai.memory-server}"
PLIST="${BR_PLIST:-$HOME/Library/LaunchAgents/${LABEL}.plist}"
HEALTH="${BR_HEALTH:-http://127.0.0.1:8765/api/health}"
EDGE="${BR_EDGE_URL:-}"          # OPTIONAL: your public health URL (e.g. https://brain.YOUR-DOMAIN/api/health). Empty = skip edge check.
DB="${BR_DB:-$HOME/Library/Application Support/mcp-memory/sqlite_vec.db}"
CREDS="${BR_CREDS:-$HOME/.config/brain/telegram.env}"   # file with TELEGRAM_BOT_TOKEN= + TELEGRAM_CHAT_ID=
# =======================================================================================

set -u
DOMAIN="gui/$(id -u)"

tg() {
    [ -f "$CREDS" ] || return 0
    local TOKEN CHAT
    TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$CREDS" | cut -d= -f2- | tr -d '"')
    CHAT=$(grep -E '^TELEGRAM_(CHAT_ID|JASON_CHAT_ID)=' "$CREDS" | head -1 | cut -d= -f2- | tr -d '"')
    [ -n "$TOKEN" ] && [ -n "$CHAT" ] || return 0
    # token via -K config fd — never in argv/ps:
    curl -sS -m 10 -o /dev/null \
        -K <(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TOKEN") \
        --data-urlencode "chat_id=${CHAT}" --data-urlencode "text=$1" 2>/dev/null
}

health_code() { curl -sS -m 5 -o /dev/null -w "%{http_code}" "$HEALTH" 2>/dev/null; }

wait_healthy() {  # up to ~100s (model load ~33s)
    for i in $(seq 1 20); do
        [ "$(health_code)" = "200" ] && return 0
        sleep 5
    done
    return 1
}

do_start() {
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null   # idempotent-ish; errors are fine if already loaded
    launchctl kickstart "${DOMAIN}/${LABEL}" 2>/dev/null || launchctl kickstart -k "${DOMAIN}/${LABEL}"
    if wait_healthy; then
        echo "OK: brain up — local $(health_code), pid $(launchctl list | awk -v l="$LABEL" '$3==l{print $1}')"
        return 0
    fi
    echo "FAILED: brain did NOT come up after kickstart (last health=$(health_code))"
    tg "${NAME:-Brain}: brain-restart.sh start FAILED — server not answering after kickstart. Needs a human on the machine."
    return 1
}

case "${1:-restart}" in
    stop)
        echo "Quiescing ${LABEL} (REMEMBER: run '$0 start' when done — nothing else restarts it)"
        launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null
        sleep 3
        echo "stopped (health=$(health_code))"
        ;;
    start)
        do_start || exit 1
        ;;
    restart)
        launchctl kickstart -k "${DOMAIN}/${LABEL}" 2>/dev/null || do_start || exit 1
        if wait_healthy; then echo "OK: restarted, local 200"; else
            echo "FAILED: not healthy after restart"; tg "${NAME:-Brain}: brain-restart.sh restart FAILED — needs a human."; exit 1
        fi
        ;;
    verify)
        L=$(health_code)
        if [ -n "$EDGE" ]; then E=$(curl -sS -m 15 -o /dev/null -w "%{http_code}" "$EDGE" 2>/dev/null); else E="(skipped)"; fi
        # WAL-safe row count via a snapshot (a hot-WAL direct read can spuriously error):
        SNAP=$(mktemp); R=$(sqlite3 "$DB" ".backup '$SNAP'" >/dev/null 2>&1 && sqlite3 "file:$SNAP?mode=ro" "SELECT count(*) FROM memories;" 2>/dev/null); rm -f "$SNAP"
        echo "local=$L edge=$E rows=${R:-?}"
        [ "$L" = "200" ] && { [ -z "$EDGE" ] || [ "$E" = "200" ]; }
        ;;
    *)
        echo "usage: $0 stop|start|restart|verify"; exit 2
        ;;
esac
