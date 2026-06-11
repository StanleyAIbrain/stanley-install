# Everest Brain — v1.5.3 Upgrade + Verify (the one guide)
**For:** the operator's Claude on the Everest island · **Target:** `stanley-install` @ tag **v1.5.3**
**What this does:** brings your already-installed brain up to the exact code the reference brain runs today — **security-hardened documents auth**, background **cognition** (safe mode), and document **ingestion** — then proves it with a parity probe.
**Time:** ~45–60 min, mostly waiting on checks. **Risk:** low — every step has its own undo, and Step 0 is a full restore point.

> **Trusted sender ≠ verified content.** Your Claude must review this entire guide and **print every code change it will make before executing anything.** Every install gets the same gates — this one included. The gates have caught a real issue on *every* prior update (this very guide was revised because a gated review caught its checkout step deleting the guide). That's the standard, not a slight. *(Standing header for all install guides, customer-facing ones included.)*

> **This is YOUR island.** Nothing here connects to, reports to, or depends on anyone else's system. You pull this on your own schedule; nothing was pushed to you. Every placeholder like `<INSTALL_DIR>`, `<PORT>`, `<YOUR_LABEL>`, `brain.<YOUR-DOMAIN>` is yours — substitute your real values. **Never paste a key's value into chat** — only ever reference it as `$(cat <path>)`.

> **How to work this guide:** top to bottom. Each step ends with a **CHECK** and a **confirm-back** — report the raw output to your operator and do not advance until it passes. If a CHECK fails, use that step's **UNDO** and stop. Nothing here deletes, rewrites, or compresses a memory — that's enforced by the code and you'll prove it.

The deep per-tool reference is `update/RUNBOOK-v1.4.md` in the repo. This guide is the single actionable entry point; the RUNBOOK is your detail companion if your machine looks different.

---

## STEP 0 — Backup (your nuclear undo). Do not skip.
Your DB uses WAL mode — a bare `cp` can capture a torn snapshot. Use the WAL-safe path.
```bash
mkdir -p ~/brain-update-backups
TS=$(date +%Y%m%d_%H%M%S)
# pause the service so the snapshot is quiescent (find your label first):
launchctl list | grep -i memory
launchctl unload ~/Library/LaunchAgents/<YOUR_LABEL>.plist ; sleep 5
# WAL-safe DB snapshot + launcher backup:
sqlite3 "<LIVE_DB_PATH>" ".backup '$HOME/brain-update-backups/sqlite_vec_pre_v150_$TS.db'"
cp <INSTALL_DIR>/memory-server.sh ~/brain-update-backups/memory-server.sh.pre_v150_$TS
# record the active count from the quiesced snapshot — this is YOUR_COUNT:
sqlite3 ~/brain-update-backups/sqlite_vec_pre_v150_$TS.db "select count(*) from memories where deleted_at is null"
# bring the service back for now:
launchctl load ~/Library/LaunchAgents/<YOUR_LABEL>.plist
```
**CHECK:** backup file exists, >1 MB; YOUR_COUNT written down.
**UNDO (nuclear, any later step):** stop service → copy the backup over the live DB → restore `memory-server.sh` → restart. Returns you to exactly this moment.
**Confirm back:** TS, backup paths, YOUR_COUNT.

## STEP 0.5 — Auth mode (1 min)
```bash
ls <INSTALL_DIR>/memory-server-api-key.txt 2>/dev/null && echo KEY-GATED || echo ANONYMOUS
```
If **KEY-GATED**, every `/api/*` call below needs `-H "X-API-Key: $(cat <INSTALL_DIR>/memory-server-api-key.txt)"`. The key works as **either** `X-API-Key` or `Authorization: Bearer` — this guide uses `X-API-Key`. The count lives in `/api/health/detailed` (key-gated); plain `/api/health` is liveness-only and carries no count.

## STEP 1 — Pull v1.5.3
```bash
cd <YOUR stanley-install clone>
git fetch --tags && git checkout v1.5.3
# self-test: you are exactly on the tag, AND this guide survived its own checkout:
[ "$(git rev-parse HEAD)" = "$(git rev-list -n1 v1.5.3)" ] && echo "on v1.5.3 ✓" || echo "NOT on v1.5.3 — stop"
ls update/EVEREST-v1.5.3-MEGA-GUIDE.md update/tools/apply_security_hardening.py update/RUNBOOK-v1.4.md   # all three must exist
```
`v1.5.3` is the current live-proven tag and contains this guide. (The `v1.5.0` tag predated the guide — checking it out would have deleted this file mid-install; **v1.5.2** fixed that, and **v1.5.3** corrected two stale audit-text contradictions.) Ignore older `v1.4-*` / `v1.4.1` / `v1.5.0` / `v1.5.2` tags.
**CHECK:** the self-test prints `on v1.5.3 ✓` and all three files exist (this guide included).
**UNDO:** `git checkout <previous tag>` — changes nothing on your running brain.

---

## STEP 2 — Security hardening (the critical one — close the documents door in your code)
The document routes (`/api/documents/*`) shipped in 10.26.5 with **no app-layer key check** — every other route had one. An unauthenticated stranger on your public hostname could POST a document into your brain (memory-poisoning) and read upload history. This patch makes the app itself enforce the key — no edge/WAF dependency.

```bash
source <INSTALL_DIR>/memory-venv/bin/activate
python update/tools/apply_security_hardening.py --dry-run     # preview (writes nothing)
python update/tools/apply_security_hardening.py               # apply
```
Expect three `PATCHED` lines (documents.py, middleware.py, app.py), each with a printed `.presec_<TS>` backup. The tool is idempotent and **aborts writing nothing** if your version isn't a clean 10.26.5 (that's the guard — if it aborts, stop and report; don't force).

Then tighten CORS — in `<INSTALL_DIR>/memory-server.sh` change the line:
```
export MCP_CORS_ORIGINS="...,*"   →   export MCP_CORS_ORIGINS="https://claude.ai,https://*.claude.ai"
```
**CHECK:** three `PATCHED` lines + backup names; CORS line no longer contains `*`.
**UNDO:** restore the three `.presec_<TS>` files over their originals; revert the CORS line.
**Confirm back:** the three PATCHED lines and backup filenames.

## STEP 3 — Turn on cognition (safe mode / "Variant B")
Add this block to **your** `<INSTALL_DIR>/memory-server.sh` immediately before the final `exec` line (edit in place; do **not** re-render from template):
```bash
# --- cognition SAFE MODE (Variant B) — do not change individual flags ---
export MCP_CONSOLIDATION_ENABLED=true     # master switch ON
export MCP_ASSOCIATIONS_ENABLED=false     # OFF — tested ON floods the brain with ~870 junk entries/run, compounding
export MCP_FORGETTING_ENABLED=false       # OFF — defaults true once master is on; would archive memories
export MCP_COMPRESSION_ENABLED=false      # OFF — defaults true once master is on; would rewrite memories
export MCP_CLUSTERING_ENABLED=true        # explicit ON — additive only
export MCP_DECAY_ENABLED=true             # explicit ON — metadata-only scoring; deletes nothing
export MCP_CONSOLIDATION_ARCHIVE_PATH="<YOUR EXISTING ARCHIVE PATH>"   # see note below
# --- end cognition block ---
```
**Archive path — keep yours (Expected-to-Differ, no migration).** A fresh install uses `<INSTALL_DIR>/data/consolidation_archive`; an existing install keeps whatever path it already has (e.g. `~/.mcp-memory/consolidation_archive`). **Do not move it** — relocating breaks your monitoring history for zero gain. The check is "archive **empty**," never "archive at a specific path."

The three `false` lines (ASSOCIATIONS / FORGETTING / COMPRESSION) are **load-bearing** — they are the zero-deletion covenant. Do not change them or you leave the tested path. The two `true` lines (CLUSTERING / DECAY) are explicit on purpose so a diff is unambiguous. **Any future edit to this launcher must diff-preview and confirm all five flags survived** before restart.

## STEP 4 — Restart and verify (cognition heartbeat + documents door SHUT)
```bash
launchctl unload ~/Library/LaunchAgents/<YOUR_LABEL>.plist ; launchctl load ~/Library/LaunchAgents/<YOUR_LABEL>.plist
launchctl kickstart -k gui/$(id -u)/<YOUR_LABEL> ; sleep 45     # kickstart needed — KeepAlive may not auto-spawn
KEY="$(cat <INSTALL_DIR>/memory-server-api-key.txt)"   # omit header use below if ANONYMOUS
curl -s http://127.0.0.1:<PORT>/api/health                                  # {"status":"healthy"}
curl -s http://127.0.0.1:<PORT>/api/consolidation/status -H "X-API-Key: $KEY"   # running:true, jobs_failed:0, next_daily set
# count unchanged:
curl -s http://127.0.0.1:<PORT>/api/health/detailed -H "X-API-Key: $KEY" | python3 -c "import json,sys;print(json.load(sys.stdin)['storage']['total_memories'])"   # == YOUR_COUNT
# THE security proof — LOCAL probes hit the app directly (bypass any edge), so this is
# the binding proof the app itself holds the door:
curl -s -o /dev/null -w "local docs upload no-key -> %{http_code} (expect 401 ALWAYS)\n" -X POST http://127.0.0.1:<PORT>/api/documents/upload
curl -s -o /dev/null -w "local docs upload keyed  -> %{http_code} (expect 422: auth ok, file missing)\n" -X POST http://127.0.0.1:<PORT>/api/documents/upload -H "X-API-Key: $KEY"
curl -s -o /dev/null -w "openapi.json             -> %{http_code} (expect 404)\n" http://127.0.0.1:<PORT>/openapi.json
curl -s -o /dev/null -w "mcp connector            -> %{http_code} (expect 200, must never break)\n" -X POST "http://127.0.0.1:<PORT>/mcp?api_key=$KEY" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -d '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"p","version":"1"}}}'
# PUBLIC probe (through your hostname) — see the two-posture note below:
curl -s -o /dev/null -w "public docs upload no-key -> %{http_code} (expect 401 OR 403)\n" --max-time 15 -X POST https://brain.<YOUR-DOMAIN>/api/documents/upload
```
**Two valid security postures (both PASS):**
- **local** no-key documents → **401 always** — this is the binding proof; the app enforces auth itself, no edge dependency.
- **public** no-key documents → **401** (bare hostname, app-layer only) **OR 403** (you also keep a Cloudflare WAF/Worker edge block as defense-in-depth). **Both are correct** — a 403 publicly means your edge block is *also* holding in front of the app's 401; that's belt-and-suspenders, not a failure. (The installer's own self-verify accepts `401|403` for exactly this reason.)

**CHECK (all):** health healthy · count == YOUR_COUNT · **local docs no-key = 401** · docs keyed = 422 · public docs no-key = 401 or 403 · openapi = 404 · connector = 200 · consolidation running, 0 failed.
**If LOCAL docs no-key is anything but 401:** STOP — the patch didn't take; restore the `.presec_` backups and report. (A public 422/200 with local 401 would instead mean an edge block is missing — fine for app-layer security, but note it.)
**UNDO (cognition only):** set `MCP_CONSOLIDATION_ENABLED=false`, restart. Nuclear = Step 0.
**Confirm back:** all the codes above verbatim.

## STEP 5 — Test document ingestion (web-API only; there is no MCP tool for it)
Supported: **PDF, TXT, MD, CSV, JSON** (DOCX/PPTX/XLSX excluded — they need a cloud parser; deferred). Use a **fingerprinted canary** padded well past the chunker's ~100-char minimum so it stores ≥1 chunk (a 35-char file chunks to 0), and **clean it up after** so it doesn't permanently offset your count and blunt the zero-deletion tripwire.
```bash
# record the pre-test count:
PRE=$(curl -s http://127.0.0.1:<PORT>/api/health/detailed -H "X-API-Key: $KEY" | python3 -c "import json,sys;print(json.load(sys.stdin)['storage']['total_memories'])")
# a padded canary (>100 chars) with a unique phrase:
printf 'Parity canary document. Unique phrase: violet-anchor-%s. This sentence pads the file well past the chunker minimum so ingestion stores at least one real chunk for the recall test below.\n' "$(date +%s)" > /tmp/canary.txt
curl -s -X POST http://127.0.0.1:<PORT>/api/documents/upload -H "X-API-Key: $KEY" \
  -F "file=@/tmp/canary.txt" -F "tags=project:<yours>,type:document"
sleep 5
curl -s http://127.0.0.1:<PORT>/api/documents/history -H "X-API-Key: $KEY"   # status:completed, chunks_stored >= 1
# recall it (ask your Claude, or search the unique phrase):
curl -s -X POST http://127.0.0.1:<PORT>/api/search -H "X-API-Key: $KEY" -H "Content-Type: application/json" -d '{"query":"violet-anchor canary","n_results":2}'
# CLEANUP — delete the canary by its auto source_file: tag, then confirm count returns EXACTLY to pre-test:
curl -s -X POST http://127.0.0.1:<PORT>/api/manage/bulk-delete -H "X-API-Key: $KEY" -H "Content-Type: application/json" -d '{"tag":"source_file:canary.txt"}'
POST=$(curl -s http://127.0.0.1:<PORT>/api/health/detailed -H "X-API-Key: $KEY" | python3 -c "import json,sys;print(json.load(sys.stdin)['storage']['total_memories'])")
echo "pre=$PRE post-cleanup=$POST  (must be EQUAL)"; rm -f /tmp/canary.txt
```
Chunks are auto-tagged `source_file:` / `file_type:`. **Why cleanup matters:** a permanent test doc offsets your memory count forever, which weakens the zero-deletion tripwire (count comparisons stop being exact).
**CHECK:** upload completed · chunks_stored ≥ 1 · the unique phrase is recalled · **post-cleanup count == pre-test count exactly**.
**Confirm back:** history JSON, the recall hit, and the `pre=… post-cleanup=…` equality line.

## STEP 6 — Morning-after (next day, 2 min)
```bash
curl -s http://127.0.0.1:<PORT>/api/consolidation/status -H "X-API-Key: $KEY"   # jobs_executed >= 1 since 02:00, 0 failed
ls <INSTALL_DIR>/data/consolidation_archive/ 2>/dev/null                         # MUST be empty
```
`jobs_executed` is **0 on install day** (a manual trigger doesn't tick it — only the 02:00 scheduler does); confirm ≥1 the morning after.
**CHECK:** jobs_executed ≥ 1 · 0 failed · archive empty · count still == YOUR_COUNT + your test-doc chunks.
**If the archive ever has a file or the count drops:** flip `MCP_CONSOLIDATION_ENABLED=false`, restart, report — a safety flag isn't holding.

---

## STEP 7 — Parity confirm (optional but recommended): prove you match the reference
Run the repo's `update/tools/verify.py` against a WAL-safe snapshot + your running server:
```bash
sqlite3 "<LIVE_DB_PATH>" ".backup '/tmp/verify_snapshot.db'"
python update/tools/verify.py --db /tmp/verify_snapshot.db \
  --server-url http://127.0.0.1:<PORT> --api-key-file <INSTALL_DIR>/memory-server-api-key.txt
```
Expect **ALL GATES PASS** (zero-deletion, facet coverage, date path #1, cognition heartbeat). For a full surface audit, run `update/PARITY-AUDIT-v1.5.3.md` (in this repo) — it probes every router. Your **must-not-be-open** result is `/api/documents/upload` no-key → **401 locally** (and 401 or 403 publicly, per the two-posture model in Step 4).

---

## Reference target (what "matches the reference" means)
| Item | Value |
|---|---|
| Engine | mcp-memory-service **10.26.5** (pinned) |
| Repo | `stanley-install` @ **v1.5.3** |
| Documents auth (local) | app-layer: no-key `/api/documents/*` → **401 always** (the binding proof) |
| Documents auth (public) | **401** (app-layer only) **OR 403** (edge WAF/Worker kept as defense-in-depth) — both PASS |
| Cognition | Variant B (consolidation ON; forgetting/compression/associations OFF; clustering/decay ON); nightly 02:00; archive permanently empty |
| Ingestion | web-API only; PDF/TXT/MD/CSV/JSON; auto `source_file:`/`file_type:` tags; DOCX excluded |
| CORS | `claude.ai` origins only (no `*`) |
| Key transport | header-only on `/api/*`; `?api_key=` preserved for `/mcp` connector |
| Schema/docs | `/openapi.json` + `/api/docs` → 404 |
| Archive path | **Expected-to-Differ**: fresh = `<INSTALL_DIR>/data/consolidation_archive`; existing keeps its own. Check is "empty," not a fixed path |
| Known cosmetic | bare date searches score the right memory ~0.95 but may not sort it to line 1 — correctness unaffected |

## Quick reference
| Situation | Action |
|---|---|
| Cognition off | `MCP_CONSOLIDATION_ENABLED=false` → restart |
| Undo security patch | restore the three `.presec_<TS>` files → restart (reopens the documents door) |
| Full restore | stop → Step 0 backup over live DB → restore `memory-server.sh` → restart |
| docs no-key ≠ 401 | patch didn't take — restore `.presec_`, report |
| Count dropped / archive not empty | cognition off → restore Step 0 → report |
| Connector broke | check `/mcp?api_key=` works; confirm CORS line + header-only patch didn't touch `/mcp` |

**Nothing auto-pushes to Everest.** You pulled v1.5.3 and ran this on your own schedule, with your own backups. When all steps are green, your brain runs exactly what the reference and future customers run.
