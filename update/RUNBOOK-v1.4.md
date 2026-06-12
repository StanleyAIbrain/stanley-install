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

---

# Reliability / self-heal (v1.5.7) — keep the brain alive unattended

> **Install this from v1.5.7 or later — it is the complete reliability release.**
> (v1.5.4 orphan gap → v1.5.5 fixed; v1.5.6 added tunnel hardening; v1.5.7 adds
> access-log API-key redaction — the HTTP access log no longer writes keys in
> plaintext. All carry forward.)

launchd on some Macs is **degraded**: KeepAlive and `launchctl load` do not reliably
respawn the memory server after a crash or a `launchctl unload`. Only `launchctl
kickstart` brings it back. The reliability bundle (`update/reliability/`) closes that
gap. All of it runs on YOUR machine and YOUR accounts.

## Step 1 — Telegram creds file (chmod 600)
```bash
mkdir -p ~/.config/brain
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' '<your-bot-token>' '<your-chat-id>' > ~/.config/brain/telegram.env
chmod 600 ~/.config/brain/telegram.env
```
**Confirm back:** `ls -l ~/.config/brain/telegram.env` shows `-rw-------`.

## Step 2 — Install the scripts
```bash
mkdir -p ~/bin
cp update/reliability/brain-watchdog.sh update/reliability/brain-restart.sh update/reliability/brain-tunnel-watchdog.sh ~/bin/
chmod +x ~/bin/brain-watchdog.sh ~/bin/brain-restart.sh ~/bin/brain-tunnel-watchdog.sh
# if your label/port differ from the stock defaults, edit the CONFIG block at the top of each.
```

## Step 3 — Watchdog cron (the run mechanism; cron, not launchd)
```bash
( crontab -l 2>/dev/null; echo '* * * * * /bin/bash $HOME/bin/brain-watchdog.sh' ) | crontab -
crontab -l | grep brain-watchdog   # confirm the line is present
```
The watchdog is **silent** except on a real incident (one "down→back up" text, or one
"restart FAILED — needs you"). No heartbeat/OK noise. State + a local tick log live in
`/tmp/brain-watchdog/`.

**Orphan reaping (v1.5.5):** before every kickstart the watchdog kills any process
LISTENING on the brain's port that launchd does NOT track AND whose command matches
the `PROCSIG` signature (default `memory server --http`). A port-holder that does not
match the signature is logged as a WARNING and never killed — the watchdog will not
kill the wrong thing. Override port/signature via `WD_PORT` / `WD_PROCSIG`.

## Step 4 — Safe restart tool (use it for every stop/start)
```bash
~/bin/brain-restart.sh verify     # local (+ optional edge) health + row count, no changes
~/bin/brain-restart.sh restart    # kickstart -k + verify-or-alert (never exits 0 without local 200)
# DB maintenance pattern:  ~/bin/brain-restart.sh stop  ->  (offline work)  ->  ~/bin/brain-restart.sh start
```
**Never** use a bare `launchctl unload`/`load` for maintenance — `load` may not spawn.
`brain-restart.sh start` is the only thing that verifies the brain actually came back.

## Step 5 — (Optional, recommended) Off-box liveness Worker
Deploy `update/reliability/liveness-worker/` to YOUR Cloudflare account:
```bash
cd update/reliability/liveness-worker
# edit wrangler.toml: set CHECK_URL to YOUR public health URL
wrangler secret put TG_TOKEN     # your Telegram bot token (entered as a secret, never typed in a command)
wrangler secret put TG_CHAT      # your Telegram chat id
wrangler deploy
```
It escalates ONLY if the brain is down ≥4 min and the watchdog hasn't recovered it
(e.g. the machine is off). No "OK" noise.

## Step 5b — Tunnel auto-fixer + http2 (v1.5.6)

Your brain can be healthy locally while the PUBLIC side is dark — the cloudflared
tunnel's connections can wedge. Two-part fix:

**(a) Enable the tunnel auto-fixer** (already copied to `~/bin` in Step 2; it runs
chained off the SAME crontab line as the brain watchdog — no new cron entry):
edit the CONFIG block at the top of `~/bin/brain-tunnel-watchdog.sh` and set
`TW_EDGE_URL` to your public health URL (e.g. `https://brain.YOUR-DOMAIN/api/health`)
and `TW_LABEL` to your cloudflared launchd label (`launchctl list | grep -i cloudflared`).
Until `TW_EDGE_URL` is set the fixer is disabled and fully silent — safe default.
Behavior: edge down 2 checks in a row while local is 200 → restart the tunnel,
10-min cooldown. It NEVER texts (the off-box Worker stays the only loud voice).

**(b) If (and only if) your tunnel log shows repeated QUIC timeouts** — lines like
`failed to accept QUIC stream: timeout: no recent network activity` — switch the
tunnel to TCP transport. In YOUR tunnel config file (commonly `~/.cloudflared/config.yml`,
or wherever your install keeps it) add:
```yaml
protocol: http2
```
then restart the tunnel (`launchctl kickstart -k gui/$(id -u)/<your-cloudflared-label>`)
and confirm the log registers connections with `protocol=http2`. If your QUIC is
stable, skip this — you still get the auto-fixer.

## Step 5c — Access-log key redaction (v1.5.7)

The HTTP access log records request URLs, and connector requests carry the API
key as `?api_key=...` — so the key lands in the log in plaintext. v1.5.7 masks
it at the logging layer, **before it is written**, with zero change to how
requests are authenticated (a valid key still authenticates; an invalid key
still 401s — the log just stops showing the value).

Wire the redaction shim onto your server's Python path (engine source untouched):
```bash
mkdir -p ~/bin/log-redact
cp update/reliability/log-redact/sitecustomize.py ~/bin/log-redact/
```
Then add ONE line to your `<INSTALL_DIR>/memory-server.sh`, right after the
`source .../activate` line (Python auto-imports `sitecustomize` from PYTHONPATH
at interpreter start, installing a logging filter that redacts
`api_key`/`token`/`secret`/`password` values):
```bash
export PYTHONPATH="$HOME/bin/log-redact${PYTHONPATH:+:$PYTHONPATH}"
```
Restart with the safe tool and confirm:
```bash
~/bin/brain-restart.sh restart
# fire one authed request, then check the log shows api_key=REDACTED, not the key:
grep -c 'api_key=REDACTED' <your access log>     # > 0
```
**Scrub the history + tighten perms** (the existing log already holds past keys):
```bash
python3 - "$HOME/path/to/your/access.log" <<'PY'
import re,sys
pat=re.compile(r'((?:api_key|apikey|api-key|access_token|token|secret|password)=)([^&\s"\'\\]+)',re.I)
p=sys.argv[1]; d=open(p,errors='replace').read()
with open(p,'r+') as f:          # inode-preserving so the live server keeps appending
    f.seek(0); f.write(pat.sub(r'\1REDACTED',d)); f.truncate()
PY
chmod 600 <your access log>
```
> Safety: this only changes what is written to the log. It never touches request
> handling. If the shim ever fails to import, the server still starts and still
> authenticates — you just lose redaction (caught by the grep check above).

## Step 6 — Prove it heals (do this once)
```bash
~/bin/brain-restart.sh stop       # take it down on purpose
# hands off — within ~2 min the watchdog should kickstart it and you get ONE text.
~/bin/brain-restart.sh verify     # confirm local=200 again
```
You should get **exactly one** text. A stream of messages = misconfig; stop and check
the CONFIG blocks. If it doesn't recover in ~4 min, run `~/bin/brain-restart.sh start`
by hand.

## launchd-degraded note (why cron, why kickstart)
- Kill-tested: KeepAlive did **not** respawn (0/2); `launchctl kickstart` did (5/5).
- `launchctl load`/`bootstrap` alone defer the spawn ("pended speculative/inefficient").
- Therefore: cron is the run mechanism (ticks independent of launchd), kickstart is the
  spawn, and every stop is treated as "down until kickstart + verified 200."
- Reboot-retest is optional defense-in-depth: after a reboot, confirm the brain comes
  back (cron + watchdog will kickstart it within a minute even if launchd doesn't).
