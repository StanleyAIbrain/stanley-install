# Brain Update v1.4 — RUNBOOK (cognition activation)

Written for the operator's Claude on any Everest island. Plain-English, gated:
**do each step, confirm the expected output back to your operator, and STOP at any
mismatch.** Nothing here deletes anything, ever. Nothing is pushed to you
automatically — you pulled this on your own schedule.

## What v1.4-cognition turns on
The consolidation engine ("cognition core") that ships in mcp-memory-service
10.26.5 but is OFF by default. With the v1.4 safety configuration it runs a
nightly self-maintenance cycle (daily 02:00, weekly Sunday 03:00, monthly on
the 1st) that scores memory health and keeps retrieval sharp — and is
configured so it can only ever ADD, never remove or rewrite:

- `MCP_FORGETTING_ENABLED=false` and `MCP_COMPRESSION_ENABLED=false` — the
  zero-deletion covenant. Non-negotiable.
- `MCP_ASSOCIATIONS_ENABLED=false` — in 10.26.5 associations are written as
  retrievable memories and re-minted every run (~870 per run on a ~1,000-memory
  store, compounding). Proven on the founding instance to pollute search
  results. Stays OFF until a safe path ships in Update 2.

## Step 1 — Back up (your own timestamped backups, before anything changes)
```bash
TS=$(date +%Y%m%d_%H%M%S); mkdir -p ~/brain-update-backups
# your rendered launch script (Step 0 of the v1.1 RUNBOOK found these paths):
cp "$SERVER_SH" ~/brain-update-backups/memory-server.sh.pre_v14_$TS
# pause the service, then snapshot the QUIESCED database:
launchctl unload "$PLIST"; sleep 5
cp "$DB" ~/brain-update-backups/sqlite_vec_pre_v14_$TS.db
sqlite3 ~/brain-update-backups/sqlite_vec_pre_v14_$TS.db \
  "select count(*) from memories where deleted_at is null"   # = ACTIVE_AT_PAUSE — record it
```
**Confirm back:** the TS, the two backup file paths, and ACTIVE_AT_PAUSE.

## Step 2 — Add the env block to YOUR rendered memory-server.sh
Do **not** re-render from the template (that would overwrite your local paths).
Open your `memory-server.sh` and paste these exact lines immediately BEFORE the
final `exec memory server --http` line — change only `<INSTALL_DIR>`:
```bash
# --- v1.4-cognition: consolidation ON with the zero-deletion safety config ---
export MCP_CONSOLIDATION_ENABLED=true
export MCP_ASSOCIATIONS_ENABLED=false
export MCP_FORGETTING_ENABLED=false
export MCP_COMPRESSION_ENABLED=false
export MCP_CONSOLIDATION_ARCHIVE_PATH=<INSTALL_DIR>/data/consolidation_archive
```
**Confirm back:** the inserted block, shown with 2 lines of context above and below.

## Step 3 — Restart and verify the heartbeat
```bash
launchctl load "$PLIST"
launchctl kickstart gui/$(id -u)/<YOUR_LABEL>   # if it doesn't start on its own
sleep 45
curl -s http://127.0.0.1:<PORT>/api/health      # expect {"status":"healthy"}
curl -s http://127.0.0.1:<PORT>/api/consolidation/status \
  -H "Authorization: Bearer $(cat <INSTALL_DIR>/memory-server-api-key.txt)"
```
Expected status: `"running":true` with `next_daily` / `next_weekly` /
`next_monthly` timestamps and `"jobs_failed":0`.
**Confirm back:** both JSON responses verbatim.

## Step 4 — Run the v1.4 gate
```bash
python3 update/tools/verify.py --db "$DB" --expect-count <ACTIVE_AT_PAUSE+any new> \
  --server-url http://127.0.0.1:<PORT> \
  --api-key-file <INSTALL_DIR>/memory-server-api-key.txt
```
Expect `ALL GATES PASS`, including
`[PASS] cognition heartbeat: scheduler running, next daily <48h, 0 failed jobs`.
(If you left consolidation off, the gate prints `skipped` and still passes —
that's intentional.)
**Confirm back:** the full gate output.

## Step 5 — The morning-after check (once, the day after activation)
```bash
ls <INSTALL_DIR>/data/consolidation_archive 2>/dev/null | wc -l   # MUST be 0
curl -s http://127.0.0.1:<PORT>/api/consolidation/status -H "Authorization: Bearer ..." 
```
`jobs_executed` should now be ≥1 and the archive dir must be EMPTY (an empty
archive is the proof that nothing was forgotten/compressed).
**Confirm back:** both values.

## Rollback lever (tested before this shipped)
Set `MCP_CONSOLIDATION_ENABLED=false` in your memory-server.sh (or delete the
whole block), then `launchctl unload` + `load` + kickstart. The scheduler stops
(`"running":false`), everything else is untouched. Nuclear option: `rollback.sh
full` with the Step-1 quiesced snapshot — returns the DB to the pause moment.

---

# v1.4-ingest — document ingestion (same gated style)

Nothing to enable: ingestion ships ON in 10.26.5. This entry is the proven
procedure + the gate.

## Step 1 — Sandbox first (a copy, never your live DB)
Stand up a throwaway brain on a spare port with `MCP_MEMORY_BASE_DIR` pointed
at a scratch copy of your DB (same pattern as every update). Ingest one
synthetic PDF/MD/CSV via the curl in the README's "Ingesting your documents"
section, tagged `ingest-test`. **Confirm back:** `/api/documents/history`
showing `status:completed` and `chunks_stored ≥ 1` per file.

## Step 2 — Prove zero impact
```bash
python3 update/tools/verify.py --db <sandbox-db> --expect-ingest-tag ingest-test
```
Expect ALL GATES PASS — the ingest gate plus all standing gates (your
pre-existing memories untouched).
**Confirm back:** full gate output.

## Step 3 — One live smoke document
Pick one small, harmless PDF. Upload it to your LIVE brain tagged
`ingest-smoke,project:<yours>,type:document`. The tag is permanent and
identifiable forever — that IS the rollback story (zero-deletion: we never
delete; we know exactly which memories came from the smoke test).
**Confirm back:** history JSON + a retrieval that quotes the document.

## Step 4 — Gate the live store
```bash
python3 update/tools/verify.py --db "$DB" --expect-ingest-tag ingest-smoke \
  --server-url http://127.0.0.1:<PORT> --api-key-file <INSTALL_DIR>/memory-server-api-key.txt
```
**Confirm back:** ALL GATES PASS including the ingest and heartbeat lines.

---

# v1.4.1-security — close the documents door (existing installs)

Fresh installs get this automatically. If your brain was installed BEFORE
v1.4.1, apply the portable patch to your running install. Gated, reversible,
zero data impact (it changes code, not memories).

## Step 1 — Pull v1.4.1 (or later)
```bash
cd ~/stanley-install && git fetch --tags && git checkout v1.4.1
```

## Step 2 — Apply the hardening to YOUR installed package
```bash
source <INSTALL_DIR>/memory-venv/bin/activate
python update/tools/apply_security_hardening.py        # add --dry-run first to preview
```
Expect: `[SEC_DOCAUTH_V1] PATCHED documents.py` (+ middleware.py, app.py), each
with a printed `.presec_<timestamp>` backup. Idempotent — safe to re-run.
**Confirm back:** the three PATCHED lines and the backup filenames.

## Step 3 — Tighten CORS in YOUR launcher (one line)
In `<INSTALL_DIR>/memory-server.sh`, change:
```
export MCP_CORS_ORIGINS="...,*"      ->   export MCP_CORS_ORIGINS="https://claude.ai,https://*.claude.ai"
```

## Step 4 — Restart and self-verify
```bash
launchctl unload "$PLIST"; launchctl load "$PLIST"
launchctl kickstart gui/$(id -u)/<YOUR_LABEL>; sleep 45
KEY=$(cat <INSTALL_DIR>/memory-server-api-key.txt)
# the door must be SHUT to no-key callers:
curl -s -o /dev/null -w "no-key documents/upload -> %{http_code} (expect 401)\n" -X POST http://127.0.0.1:<PORT>/api/documents/upload
curl -s -o /dev/null -w "keyed  documents/upload -> %{http_code} (expect 422)\n" -X POST http://127.0.0.1:<PORT>/api/documents/upload -H "X-API-Key: $KEY"
curl -s -o /dev/null -w "openapi.json            -> %{http_code} (expect 404)\n" http://127.0.0.1:<PORT>/openapi.json
```
**Confirm back:** 401 / 422 / 404. If the no-key probe is anything but 401/403,
STOP — the patch didn't take; restore the `.presec_*` backups and report.

## Rollback
Restore each `.presec_<timestamp>` backup over its file and restart. (Reopens the
documents door — only if the patch misbehaves.)
