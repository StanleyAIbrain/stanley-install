#!/bin/bash
# rollback.sh — undo the brain update. Two modes:
#   ./rollback.sh flag-off
#       Instantly disables the date path (sets HYBRID_DATE_ENABLED=false) and restarts.
#       Leaves code + DB as-is; the patched branch becomes a no-op. Use this FIRST if the
#       date path misbehaves — it is the fastest, safest reversal.
#   ./rollback.sh full <DB_BACKUP> <CODE_BACKUP> [LAUNCH_BACKUP]
#       Full restore: copies the DB backup over the live DB, restores the pre-patch
#       sqlite_vec.py and (optionally) the pre-patch launch script, then restarts.
#
# Override these if your layout differs (defaults = the Everest/Jordan layout):
LABEL="${LABEL:-com.stanleyai.memory-server}"
PLIST="${PLIST:-$HOME/Library/LaunchAgents/com.stanleyai.memory-server.plist}"
SERVER_SH="${SERVER_SH:-$HOME/stanley-ai/memory-server.sh}"
DB="${DB:-$HOME/Library/Application Support/mcp-memory/sqlite_vec.db}"
# Locate the storage file with the BRAIN's venv python (system python3 lacks the module).
VENV_PY="${VENV_PY:-$HOME/stanley-ai/memory-venv/bin/python3}"
[ -x "$VENV_PY" ] || VENV_PY="python3"
SQLITE_VEC_PY="${SQLITE_VEC_PY:-$("$VENV_PY" - <<'PY'
import importlib.util
s = importlib.util.find_spec("mcp_memory_service.storage.sqlite_vec")
print(s.origin if s else "")
PY
)}"

restart() {
  echo ">> restarting service ($LABEL)…"
  launchctl unload "$PLIST" 2>/dev/null
  launchctl load "$PLIST" 2>/dev/null
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null
  for i in $(seq 1 25); do
    sleep 3
    if lsof -nP -iTCP:8765 -sTCP:LISTEN -t >/dev/null 2>&1; then echo ">> service is up."; return 0; fi
  done
  echo ">> WARNING: service not listening after ~75s — check $HOME/stanley-ai/logs/memory-server.log"
}

case "$1" in
  flag-off)
    cp "$SERVER_SH" "$SERVER_SH.rollback_$(date +%Y%m%d_%H%M%S)" 2>/dev/null
    # set the flag to false (or remove it); idempotent
    if grep -q "HYBRID_DATE_ENABLED" "$SERVER_SH"; then
      sed -i '' 's/export HYBRID_DATE_ENABLED=.*/export HYBRID_DATE_ENABLED=false/' "$SERVER_SH"
    fi
    echo ">> HYBRID_DATE_ENABLED set false in $SERVER_SH"
    restart ;;
  full)
    DB_BAK="$2"; CODE_BAK="$3"; LAUNCH_BAK="$4"
    [ -f "$DB_BAK" ] || { echo "ERROR: DB backup '$DB_BAK' not found"; exit 2; }
    [ -f "$CODE_BAK" ] || { echo "ERROR: code backup '$CODE_BAK' not found"; exit 2; }
    echo ">> pausing service…"; launchctl unload "$PLIST" 2>/dev/null; sleep 2
    echo ">> restoring DB from $DB_BAK"
    cp "$DB_BAK" "$DB"; rm -f "$DB-wal" "$DB-shm"
    echo ">> restoring code from $CODE_BAK"
    cp "$CODE_BAK" "$SQLITE_VEC_PY"
    if [ -n "$LAUNCH_BAK" ] && [ -f "$LAUNCH_BAK" ]; then echo ">> restoring launch script"; cp "$LAUNCH_BAK" "$SERVER_SH"; fi
    restart ;;
  *)
    echo "usage: $0 flag-off            # instant date-path disable (recommended first)"
    echo "       $0 full <DB_BACKUP> <CODE_BACKUP> [LAUNCH_BACKUP]   # full restore"
    exit 1 ;;
esac
