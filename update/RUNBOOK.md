# Brain Update — RUNBOOK (self-contained)

Applies two improvements to a running **mcp-memory-service** brain (the "Everest" stack):

1. **Tag hygiene** — relocates date-pattern tags into `metadata['date_tags']` and appends a clean,
   owner-approved facet vocabulary (`project:`/`type:`/`status:`/`priority:`). Append-only; nothing is deleted.
2. **Date-aware retrieve (Piece C)** — when a query contains a date ("April 03", "November 03 2025"),
   the brain returns the memory that actually carries that date instead of a fuzzy semantic guess.
   Read-path only, behind a flag (`HYBRID_DATE_ENABLED`). The reranker is **not** part of this update.

**Target:** mcp-memory-service **10.26.5**, sqlite-vec backend, macOS + launchd.
**Safety:** the only data change is the append-only tag transform (asserts zero deletions); the date path
is read-only code. Everything is backed up first and is reversible (see §6).
**You do NOT need any knowledge outside this folder.** Every value you need is discovered in Step 0.

> Throughout, run commands in a terminal (Claude Code). `$VENV` is the brain's Python virtualenv.

---

## Step 0 — Discover your paths (copy the output; you'll reuse it)

```bash
# The brain's virtualenv python (adjust if your venv lives elsewhere):
VENV="$HOME/stanley-ai/memory-venv/bin/python3"
# The installed storage file that Piece C patches:
SQLITE_VEC_PY="$("$VENV" - <<'PY'
import importlib.util; s=importlib.util.find_spec("mcp_memory_service.storage.sqlite_vec"); print(s.origin)
PY
)"
# The live database, launch script, and launchd label:
DB="$HOME/Library/Application Support/mcp-memory/sqlite_vec.db"
SERVER_SH="$HOME/stanley-ai/memory-server.sh"
PLIST="$HOME/Library/LaunchAgents/com.stanleyai.memory-server.plist"
LABEL="com.stanleyai.memory-server"          # your launchd label; verify: launchctl list | grep memory
echo "VENV=$VENV"; echo "SQLITE_VEC_PY=$SQLITE_VEC_PY"; echo "DB=$DB"; echo "SERVER_SH=$SERVER_SH"; echo "LABEL=$LABEL"
ls -l "$DB" "$SERVER_SH" "$SQLITE_VEC_PY"   # all four must exist
"$VENV" -c "import mcp_memory_service, sqlite_vec, sentence_transformers; print('deps OK')"
```
If any path is wrong for your install, set the variable to the correct path before continuing.
Preview the active memory count (informational only — the **authoritative** count for verification is
captured *after* the pause in Step 3, so in-flight writes from a live multi-writer brain can't skew it):
```bash
"$VENV" - <<PY
import sqlite3; c=sqlite3.connect("file:$DB?mode=ro",uri=True)
print("ACTIVE_PREVIEW", c.execute("select count(*) from memories where deleted_at is null").fetchone()[0])
PY
```

## Step 1 — Back up everything (timestamped)

```bash
TS=$(date +%Y%m%d_%H%M%S); echo "BACKUP_TS=$TS"
mkdir -p "$HOME/brain-update-backups"
cp "$DB" "$HOME/brain-update-backups/sqlite_vec.$TS.db"
cp "$SQLITE_VEC_PY" "$HOME/brain-update-backups/sqlite_vec.py.$TS"
cp "$SERVER_SH" "$HOME/brain-update-backups/memory-server.sh.$TS"
ls -l "$HOME/brain-update-backups/"   # confirm three backups
```
Keep the `BACKUP_TS` value — rollback (§6) uses these three files.

## Step 2 — Propose a tag map, then APPROVE it (you decide the vocabulary)

The proposal tool reads your tags and suggests a facet map **derived from your own data**. It changes nothing.
```bash
cd <this package>/tools
"$VENV" tag_propose.py --db "$DB" --out "$HOME/brain-update-backups/proposed_tag_map.$TS.json"
```
Open `proposed_tag_map.$TS.json` and review it:
- **`project_facets`** — each is a cluster of your tags with a `canonical` name (the most-used tag in the
  cluster). **Rename** any canonical you don't like; **delete** clusters that aren't real projects.
- **`status_facets` / `priority_facets`** — only generic cue tags found in your data; remove any you disagree with.
- **`type_facets_from_memory_type`** — derived from the `memory_type` column; usually leave as-is.
- When satisfied, set **`"approved": true`** at the top of the file and save.

## Step 3 — Pause the service, then snapshot the quiesced DB (authoritative)

```bash
launchctl unload "$PLIST"
sleep 2; lsof -nP -iTCP:8765 -sTCP:LISTEN -t || echo "service stopped (no listener) — good"

# With the service stopped the DB is now QUIESCENT (no more writes). Take the authoritative DB
# backup and active count from THIS moment. Rollback (§6) and verify (Step 6) both use these — so
# writes that landed just before the pause can neither be lost by a rollback nor false-fail verify.
cp "$DB" "$HOME/brain-update-backups/sqlite_vec.$TS.paused.db"
"$VENV" - <<PY
import sqlite3; c=sqlite3.connect("file:$DB?mode=ro",uri=True)
print("ACTIVE_AT_PAUSE", c.execute("select count(*) from memories where deleted_at is null").fetchone()[0])
PY
```
**Record `ACTIVE_AT_PAUSE`** and note the `sqlite_vec.$TS.paused.db` path — Step 6 and §6 use the
post-pause snapshot/count, NOT the Step 1 (pre-pause) copy.

## Step 4 — Apply the approved tag map (append-only; asserts zero deletions)

```bash
"$VENV" tag_apply.py --db "$DB" --map "$HOME/brain-update-backups/proposed_tag_map.$TS.json"
```
It prints `deleted=0 (OK)` and aborts if any deletion is detected. If it aborts, restore the DB
backup (§6) before doing anything else.

## Step 5 — Install the date path (code patch + flag)

```bash
"$VENV" apply_pieceC.py --target "$SQLITE_VEC_PY" --server-sh "$SERVER_SH"
```
This backs the file up again, inserts the date-path code (idempotent; refuses to write a partial patch),
py_compile-checks it, and adds `export HYBRID_DATE_ENABLED=true` to the launch script. Re-running is a no-op.

## Step 6 — Restart and verify

```bash
launchctl load "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"   # forces start past launchd throttle
# The service reloads the embedding model on boot — first health can take ~30-40s.
for i in $(seq 1 25); do sleep 3; lsof -nP -iTCP:8765 -sTCP:LISTEN -t && break; done
curl -s http://127.0.0.1:8765/api/health    # expect {"status":"healthy", ...}
```
> **Restart gotchas (normal, not failures):** the service is `KeepAlive=true`, so always use
> `launchctl unload/load` (a plain `kill` just respawns it). If it doesn't come up within ~40s, run the
> `kickstart -k` line again. The `…/logs/memory-server.err` log can contain *stale* lines from past runs —
> trust `…/logs/memory-server.log` and the health check, not `.err`.

Run the gates (zero deletions, tag hygiene, date path works, absent date fails open):
```bash
"$VENV" verify.py --db "$DB" --expect-count <ACTIVE_AT_PAUSE from Step 3>
```
Expect `ALL GATES PASS`. Also sanity-check live: in your Claude, retrieve a memory using a date you know
exists in your brain — it should return that dated item.

---

## §6 — Rollback

- **Date path misbehaving (fastest, no data change):**
  ```bash
  ./rollback.sh flag-off
  ```
  Sets `HYBRID_DATE_ENABLED=false` and restarts; the patched branch becomes a no-op.

- **Undo everything (tags + code) — restore the POST-PAUSE snapshot from Step 3:**
  ```bash
  ./rollback.sh full \
    "$HOME/brain-update-backups/sqlite_vec.$TS.paused.db" \
    "$HOME/brain-update-backups/sqlite_vec.py.$TS" \
    "$HOME/brain-update-backups/memory-server.sh.$TS"
  ```
  Restores the DB (to the Step 3 quiesced snapshot), the pre-patch code, and the launch script, then restarts.

> ⚠️ **A full restore returns the brain to the backup moment (the Step 3 pause). Any memory stored *after*
> that snapshot is NOT in the restored DB.** Because the update is applied while the service is paused, a
> restore done *immediately* after a failed apply loses nothing. Rule of thumb:
> **`flag-off` is safe anytime (read-path only, no data change); `full` only right after a failed apply,
> before the service has accepted new writes.** If the service has been live for a while since the update,
> prefer `flag-off` and targeted correction over a `full` restore.

The tag transform is **append-only and idempotent** (re-running Step 4 changes nothing the second time),
and the date path is **read-only** — so a full restore done at the pause point returns the brain bit-for-bit
to its pre-update state.
