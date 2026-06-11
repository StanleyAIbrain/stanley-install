# Install Parity Audit — v1.5.2 Reference
**Operator: hand this entire file to your Claude and say: "Run this audit top to bottom and produce the report."**
**Purpose: verify your install is functionally identical to the proven reference install — every line of code, every setting, every safety flag, every working function — and produce one report file to send back for analysis.**
**Mode: READ-ONLY except for two tiny, reversible functional tests (clearly marked). Nothing in this audit deletes, rewrites, or reconfigures anything.**
**Time: ~30–45 minutes of Claude work.**

> **Trusted sender ≠ verified content.** Your Claude must review this entire audit and **print every command it will run before executing anything.** Every install gets the same gates — this one included. The gates have caught a real issue on every prior update; that's the standard, not a slight. *(Standing header for all install/audit guides, customer-facing ones included.)*

---

## RULES FOR THE AUDITING CLAUDE (read first, follow absolutely)

1. **Read-only by default.** You inspect, you do not fix. If you find something wrong, you RECORD it — you do not repair, patch, upgrade, or "improve" anything during this audit. Fixes come later, gated, after analysis.
2. **Never print secret values.** API keys, tokens, tunnel credentials, OTP codes: never echo their contents. When a check involves a secret, report only: exists yes/no, file permissions, and `sha256sum` of the file (a fingerprint proves possession without exposure).
3. **Every check gets a verdict line** in this exact machine-parsable format so the analysis on the other side can diff it automatically:
   `CHECK-ID | PASS/FAIL/DIFFERS/SKIP | <observed value> | <one-line note>`
   - **PASS** = matches reference exactly
   - **DIFFERS** = doesn't match but is on the Expected-to-Differ list (Section 0) — not a failure
   - **FAIL** = doesn't match and is NOT on that list
   - **SKIP** = couldn't run; say why
4. **Capture raw evidence.** Every command's actual output goes in the report's appendix under its CHECK-ID. The verdict table is the summary; the appendix is the proof.
5. **Output = one file:** `AUDIT-REPORT-YYYY-MM-DD.md` containing: (a) a 10-line executive summary, (b) the full verdict table, (c) the raw-evidence appendix. Send that file back to your provider for analysis.
6. If any single check errors, **continue the audit** — never abort the whole run for one failure. The point is a complete picture.

---

## SECTION 0 — Expected-to-Differ list (these are NOT failures)

Your install is a fully isolated island. The following WILL differ from the reference and must be marked **DIFFERS**, never FAIL:

- **Domain/hostnames** (your brain URL, dashboard URL, tunnel hostnames)
- **Memory counts and memory contents** (your data is yours)
- **Tag namespaces** (your chosen project namespace (e.g. `project:<yourname>`) is yours by design)
- **DB file path** — the reference brain's DB lives at `~/Library/Application Support/mcp-memory/sqlite_vec.db`; installs have also used `~/stanley-ai/data/sqlite_vec.db`. Either is fine — what matters is that the launcher, the backups, and the rollback tooling all point at the SAME path. (Checks below verify that internal consistency.)
- **macOS username and home paths**
- **Auth mode** — key-gated vs anonymous. Both are valid configurations; the audit determines which one you're running and verifies it's *internally consistent and properly gated*. (If your mode was never explicitly confirmed, this audit settles it.)
- **Cloudflare account, Access team domain, allowlisted email** (yours, not anyone else's)
- **Edge security posture (v1.5.2 two-posture model)** — as of v1.5.2 the `/api/documents/*` routes enforce the API key **in the app itself** (router-level `require_read_access`), so they are no longer open regardless of edge config. Valid postures: **(A)** public hostname, app-layer key-gating, liveness-only public health — so the claude.ai MCP connector at `/mcp` works; public no-key documents → **401 from the app**. **(B)** same, plus a Cloudflare WAF/Worker edge block on `/api/documents/*` kept as defense-in-depth → public no-key documents → **403 at the edge** (the app's 401 still sits behind it). Both PASS. The fatal finding (FAIL-CRITICAL) is now only a **LOCAL** no-key documents route that reaches the app (2xx/422) — that means the app-layer patch didn't take. A public 403 is **not** a failure; it's belt-and-suspenders.
- **Consolidation archive path** — `MCP_CONSOLIDATION_ARCHIVE_PATH` differs by install: fresh = `<INSTALL_DIR>/data/consolidation_archive`; existing installs keep their own (e.g. `~/.mcp-memory/consolidation_archive`). **No migration** — the check is "archive is **empty**," never "archive at a specific path."

Everything else — software version, code at the tag, env flags, safety settings, endpoint behavior, gate results — is expected to MATCH.

---

## SECTION 1 — Identity & Version (the foundation)

```bash
# 1.1 The exact installed brain version — must be 10.26.5
source ~/stanley-ai/memory-venv/bin/activate 2>/dev/null || true
pip show mcp-memory-service | head -3
python -c "import mcp_memory_service; print(mcp_memory_service.__file__)"
```
`AUD-1.1 | ? | <version> | reference = 10.26.5 exactly — any other version is FAIL`

```bash
# 1.2 Full dependency freeze (the appendix copy lets analysis diff every package)
pip freeze > /tmp/install_pip_freeze.txt && wc -l /tmp/install_pip_freeze.txt
# Spot-check the two that make cognition + ingestion work:
pip show apscheduler | head -2     # reference: 3.11.2
pip show pypdf | head -2           # reference: 6.9.1
```
`AUD-1.2 | ? | apscheduler=<v>, pypdf=<v> | full freeze in appendix`

```bash
# 1.3 Python version
python --version
```
`AUD-1.3 | ? | <version> | record for analysis`

---

## SECTION 2 — Repo & Code Parity ("every line of code")

This is the literal every-line check. If the working tree at tag v1.5.2 has **zero diff**, then every line of code in your install package is byte-identical to the reference. Any local modification shows up here.

```bash
cd ~/stanley-install   # or wherever your clone lives — record the actual path
git remote -v                          # must point at StanleyAIbrain/stanley-install
git fetch --tags
git describe --tags                    # what you're actually on
git rev-parse HEAD                     # full commit
git rev-parse HEAD; git rev-list -n1 v1.5.2   # the two must match (you are on the tag)
```
`AUD-2.1 | ? | tag=<tag>, HEAD==rev-list? | reference = v1.5.2 (HEAD must equal `git rev-list -n1 v1.5.2`). An older tag = a FINDING (record it, don't upgrade mid-audit)`

```bash
# 2.2 THE every-line check: zero diff between your tree and the tag
git status --porcelain                 # must be EMPTY
git diff v1.5.2 --stat                 # must be EMPTY
git diff v1.5.2 | head -200            # if anything appears, capture ALL of it in the appendix
```
`AUD-2.2 | ? | <empty / N files differ / mode-only> | empty = every line identical. A **mode-only** change (e.g. 100644→100755 from a local chmod +x during dashboard setup, 0 content bytes) is **DIFFERS, not FAIL** — note which files. A content diff (any insertions/deletions) = FAIL with full diff in appendix.`

```bash
# 2.3 The Piece-C date-retrieval patch must be present in the RUNNING code (not just the repo)
grep -rn "HYBRID_DATE_ENABLED" ~/stanley-ai/memory-venv/lib/python*/site-packages/mcp_memory_service/ | head -5
```
`AUD-2.3 | ? | <N matches> | reference: present. Zero matches = the date-retrieval patch never reached your running install = FAIL`

```bash
# 2.4 Key tooling files exist and are the fixed versions
ls -la update/RUNBOOK-v1.4.md
python3 <<'PY'
src = open('update/tools/verify.py').read()
# real-fix detector (NOT a substring that exists in the broken file too):
fixed = ('_FULL_MONTHS' in src) and ('sept' in src) and ('_MNAME = {i+1' in src)
print('may-fix-present:', fixed)
PY
grep -n "memory-server.sh" update/tools/rollback.sh | head -3   # rollback derives path from launcher, not hardcoded
```
`AUD-2.4 | ? | runbook=<y/n>, verify-fixed=<y/n>, rollback-derives=<y/n> | all three must be yes. verify-fixed checks for the ACTUAL fix (_FULL_MONTHS table incl. may + sept-shadow handling), NOT the substring "may" which is present even in the broken file.`

---

## SECTION 3 — Launcher & Environment ("every setting")

The launcher is where installs silently drift. This section dumps your **entire effective configuration**.

```bash
# 3.1 Capture the full launcher with secret VALUES redacted (keep variable NAMES)
sed -E 's/(API_KEY|TOKEN|SECRET)([A-Z_]*)=.*/\1\2=<REDACTED>/' ~/stanley-ai/memory-server.sh
```
Put the full redacted launcher in the appendix.
`AUD-3.1 | ? | <line count> | full redacted launcher in appendix`

```bash
# 3.2 The Variant B cognition block — all six flags, exact values
grep -E "MCP_(CONSOLIDATION_ENABLED|ASSOCIATIONS_ENABLED|FORGETTING_ENABLED|COMPRESSION_ENABLED|CLUSTERING_ENABLED|DECAY_ENABLED|CONSOLIDATION_ARCHIVE_PATH)" ~/stanley-ai/memory-server.sh
```
Reference values — these are the safety covenant, any deviation is a FAIL:
| Flag | Required |
|---|---|
| MCP_CONSOLIDATION_ENABLED | **true** |
| MCP_ASSOCIATIONS_ENABLED | **false** (tested ON: mints ~870 junk memories per run, compounding) |
| MCP_FORGETTING_ENABLED | **false** (defaults true once master is on — would archive memories) |
| MCP_COMPRESSION_ENABLED | **false** (defaults true once master is on — would rewrite memories) |
| MCP_CLUSTERING_ENABLED | true |
| MCP_DECAY_ENABLED | true |
| MCP_CONSOLIDATION_ARCHIVE_PATH | set explicitly |

**Special case:** if MCP_CONSOLIDATION_ENABLED is absent/false, you haven't installed v1.5.2 yet — record `AUD-3.2 | SKIP | not yet installed | audit still valuable as pre-install baseline` and skip Section 8.
`AUD-3.2 | ? | <all 7 observed values> | compare table above`

```bash
# 3.3 Date-aware retrieval flag (Piece C from Update 1 — set by Update 1; confirm it survived)
grep "HYBRID_DATE_ENABLED" ~/stanley-ai/memory-server.sh
```
`AUD-3.3 | ? | <value> | reference = true. Missing = a known historical parity risk on cloned installs`

```bash
# 3.4 Auth-mode declaration in the launcher
grep -E "MCP_(API_KEY|ALLOW_ANONYMOUS_ACCESS)" ~/stanley-ai/memory-server.sh | sed -E 's/(API_KEY)=.*/\1=<REDACTED>/'
ls -la ~/stanley-ai/memory-server-api-key.txt 2>/dev/null && sha256sum ~/stanley-ai/memory-server-api-key.txt || echo "NO KEY FILE"
```
`AUD-3.4 | ? | mode=<key-gated/anonymous>, keyfile=<exists+perms+sha256 / none> | DIFFERS allowed, but mode must be internally consistent (verified in 6.x)`

```bash
# 3.5 Anything ELSE exported in the launcher that the reference doesn't have (drift detector)
grep -E "^\s*export" ~/stanley-ai/memory-server.sh | sed -E 's/(API_KEY|TOKEN|SECRET)([A-Z_]*)=.*/\1\2=<REDACTED>/'
```
`AUD-3.5 | ? | <count> exports | full list in appendix for side-by-side diff`

---

## SECTION 4 — Service & Launch Chain

```bash
# 4.1 launchd services present and loaded
launchctl list | grep -i -E "memory|stanley|tunnel"
```
`AUD-4.1 | ? | <labels found> | reference: com.stanleyai.memory-server + a tunnel service, both running (PID present)`

```bash
# 4.2 KeepAlive (auto-restart on crash) — read the plists
for p in ~/Library/LaunchAgents/com.stanleyai.*.plist; do echo "== $p"; plutil -p "$p" | grep -E "KeepAlive|Program|Label"; done
```
`AUD-4.2 | ? | KeepAlive=<true/false> per service | reference = true on the memory server`

```bash
# 4.3 The plist launches THE launcher you audited in Section 3 (not a stale copy)
plutil -p ~/Library/LaunchAgents/com.stanleyai.memory-server.plist | grep -A3 Program
```
`AUD-4.3 | ? | <path> | must be the same memory-server.sh from 3.1`

```bash
# 4.4 Service responds locally
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8765/api/health
```
`AUD-4.4 | ? | <code> | reference = 200 on port 8765`

---

## SECTION 5 — Database Integrity

```bash
# 5.1 Resolve the REAL DB path from the running config, then verify the file
DB=$(grep -E "SQLITE|DB_PATH|DATA" ~/stanley-ai/memory-server.sh | grep -v REDACTED | head -3)
echo "$DB"
ls -la ~/stanley-ai/data/sqlite_vec.db* 2>/dev/null
ls -la "$HOME/Library/Application Support/mcp-memory/"sqlite_vec.db* 2>/dev/null
```
`AUD-5.1 | ? | live DB path = <path> | DIFFERS ok, but exactly ONE location should be live — two populated locations = FAIL (split-brain risk)`

```bash
# 5.2 WAL mode + integrity (read-only pragmas, safe on a live DB)
sqlite3 "<LIVE_DB_PATH>" "PRAGMA journal_mode; PRAGMA integrity_check; SELECT count(*) FROM sqlite_master WHERE type='table';"
```
`AUD-5.2 | ? | journal=<wal>, integrity=<ok>, tables=<N> | reference: wal / ok`

```bash
# 5.3 Embedding model + dimensions + count via the API
# NOTE: /api/health is liveness-only ({"status":"healthy"}) — model/dims/count live in /api/health/detailed (key-gated):
curl -s http://127.0.0.1:8765/api/health/detailed -H "X-API-Key: $(cat ~/stanley-ai/memory-server-api-key.txt)"
```
(Key-gated: add `-H "X-API-Key: $(cat ~/stanley-ai/memory-server-api-key.txt)"` to every `/api/*` call in this audit. NOTE: 10.26.5 accepts the key three ways by route — `X-API-Key` header on `/api/*` data routes, `Authorization: Bearer` on `/mcp`, and `?api_key=` query param on the public connector URL. For THIS audit, every `/api/*` call uses `X-API-Key`.)
`AUD-5.3 | ? | model=<name>, dims=<N>, active=<count> | reference: all-MiniLM-L6-v2 / 384. Count DIFFERS by design — record it as YOUR_COUNT for Section 8`

```bash
# 5.4 Backup spine exists and the newest backup is real
ls -la ~/brain-update-backups/ | tail -5
```
`AUD-5.4 | ? | newest=<file+date+size> | must exist, >1MB, from a WAL-safe method. Empty folder = FAIL (no nuclear undo)`

---

## SECTION 6 — Auth & Security ("the proper API safety settings")

This section settles the auth question permanently and probes the real attack surface.

```bash
# 6.1 What does the API do WITHOUT credentials, from the machine itself?
curl -s -o /dev/null -w "health:%{http_code}\n"  http://127.0.0.1:8765/api/health
curl -s -o /dev/null -w "search:%{http_code}\n"  -X POST http://127.0.0.1:8765/api/search -H "Content-Type: application/json" -d '{"query":"audit-probe","n_results":1}'
```
`AUD-6.1 | ? | health=<code>, search=<code> | health is 200 in BOTH modes (liveness route carries no auth dependency) — the SEARCH code is the mode indicator: search 401 = key-gated, search 200 = anonymous. Record the definitive answer.`

```bash
# 6.2 Internal consistency: declared mode (3.4) matches observed behavior (6.1)
# key file exists + 401 without key = consistent key-gated
# no key file + 200 without key = consistent anonymous
# ANY mixed state = FAIL
```
`AUD-6.2 | ? | <consistent/inconsistent> | mixed state means the install is half-configured`

```bash
# 6.3 THE critical external probes — verify the brain is protected, by EITHER supported posture.
# Posture A (key-gated, the default installer ships): brain hostname is public, NO Access.
#   /api/health returns liveness JSON (200) by design, but every DATA route demands the key.
# Posture B (Access-on-hostname): an Access challenge fronts everything.
# This install passes if it cleanly matches ONE posture. The fatal finding is a DATA route
# answering publicly with no key AND no Access — that is the real open door.

# (1) public health — liveness only, carries no memory data:
curl -s -o /dev/null -w "health:%{http_code}\n" --max-time 15 https://<YOUR-BRAIN-HOSTNAME>/api/health
# (2) THE real test — a public DATA route with NO key and NO Access session:
curl -s -o /dev/null -w "search-nokey:%{http_code}\n" --max-time 15 -X POST https://<YOUR-BRAIN-HOSTNAME>/api/search -H "Content-Type: application/json" -d '{"query":"probe","n_results":1}'
```
**Pass conditions (either posture):**
- **Posture A (key-gated):** health 200 liveness JSON = **PASS (DIFFERS-by-design)**; search-nokey **401** = PASS. The data route is walled by the app-layer key even though the hostname is public — this is exactly what the stock installer verifies ("brain reachable publicly, key-gated, no Cloudflare Access in front").
- **Posture B (Access):** both return an Access challenge / 302 / 403 = PASS.
- **FAIL-CRITICAL only if:** a DATA route (`/api/search`, `/api/documents/*`) returns real data with **no key and no Access** — that is a genuinely open brain.
`AUD-6.3 | ? | health=<code>, search-nokey=<code>, posture=<A/B> | A: health 200 + search-nokey 401 = PASS · B: both Access-challenged = PASS · data route open w/o key+Access = FAIL-CRITICAL`

```bash
# 6.4 Same probe against the documents upload endpoint (it has NO app-layer auth of its own —
# an edge block is its ONLY lock: Access challenge on Posture B, or a WAF/firewall 403 on Posture A)
curl -s -o /dev/null -w "%{http_code}\n" --max-time 15 -X POST https://<YOUR-BRAIN-HOSTNAME>/api/documents/upload
```
`AUD-6.4 | ? | <code> | PASS = Access challenge (302/403 to login) on Posture B, or WAF/firewall 403 on Posture A. FAIL-CRITICAL = anything that reaches the app (e.g. 400/422 validation error or a working upload response) — the upload door is publicly open; mitigate immediately (WAF rule for /api/documents/* or Access on the hostname).`

```bash
# 6.5 Dashboard fail-closed + OTP-only check
curl -s -o /dev/null -w "%{http_code}\n" --max-time 15 https://<YOUR-DASHBOARD-HOSTNAME>/
# Then the operator manually: open the dashboard in a private browser window.
# Confirm: (a) it demands an email one-time code (NOT a Google sign-in button),
# (b) ONLY your email receives a working code, (c) after login it works,
# (d) view page source / devtools network tab: your API key must NEVER appear client-side.
```
`AUD-6.5 | ? | otp-only=<y/n>, single-email=<y/n>, no-key-client-side=<y/n> | all yes. A Google IdP button present = FAIL (reference removed Google IdP deliberately)`

```bash
# 6.6 No secrets leaked into logs or shell history
grep -riE "api[_-]?key\s*[:=]\s*[A-Za-z0-9]{8,}" ~/stanley-ai/*.log 2>/dev/null | head -3
grep -c "Bearer" ~/.zsh_history 2>/dev/null; grep -c "Bearer" ~/.bash_history 2>/dev/null
ls -la ~/stanley-ai/*.log 2>/dev/null | head -5
```
`AUD-6.6 | ? | log-leaks=<N>, history-bearer=<N> | report counts only — NEVER paste the matching lines`

```bash
# 6.7 Secret scan of the repo working tree (nothing sensitive staged to ever be pushed)
cd ~/stanley-install && grep -riE "(api[_-]?key|token|secret)\s*[:=]\s*['\"]?[A-Za-z0-9]{16,}" --include="*.py" --include="*.sh" --include="*.md" . | grep -v REDACTED | head -5
```
`AUD-6.7 | ? | <N hits> | reference = 0. Any hit: report file+line number only, never the value`

```bash
# 6.8 Key file permissions (key-gated mode only; SKIP if anonymous)
stat -f "%Sp %Su" ~/stanley-ai/memory-server-api-key.txt 2>/dev/null
```
`AUD-6.8 | ? | <perms owner> | should be readable by your user only (-rw------- ideal)`

---

## SECTION 7 — API Surface Matrix ("every function exists")

Run each against `http://127.0.0.1:8765` (add the `X-API-Key` header if key-gated). Record the status code for every row:

```bash
for ep in "GET /api/health" "GET /api/consolidation/status" "GET /api/documents/history" "GET /api/backup/list" "GET /recommendations"; do
  m=${ep%% *}; p=${ep#* }
  printf "%-32s %s\n" "$p" "$(curl -s -o /dev/null -w '%{http_code}' -X $m http://127.0.0.1:8765$p)"
done
curl -s -o /dev/null -w "POST /api/search                  %{http_code}\n" -X POST http://127.0.0.1:8765/api/search -H "Content-Type: application/json" -d '{"query":"probe","n_results":1}'
curl -s -o /dev/null -w "GET  /api/documents/upload        %{http_code}\n" http://127.0.0.1:8765/api/documents/upload
```
Reference matrix: health 200 · consolidation/status 200 · documents/history 200 · backup/list 200 · search 200 · documents/upload via GET **405** (route exists, wrong method — correct) · **/recommendations 404 (known cosmetic — PASS).** NOTE: a bare `GET /api/documents/status` correctly **404s** in 10.26.5 — the real route is `GET /api/documents/status/{id}`; use `/api/documents/history` for a parameterless liveness check (above). Do NOT expect 200 on bare `/documents/status`.
`AUD-7.1 | ? | <full matrix> | any endpoint deviating from the reference column = FAIL for that row`

---

## SECTION 8 — Cognition Functional Test (FUNCTIONAL TEST #1 — additive-only, reversible)

This proves cognition doesn't just exist — it runs, and runs SAFELY. Skip if 3.2 was SKIP.

```bash
# 8.1 Pre-state — count via /api/health/detailed (liveness /api/health carries no count; key-gated: X-API-Key)
curl -s http://127.0.0.1:8765/api/health/detailed -H "X-API-Key: $(cat ~/stanley-ai/memory-server-api-key.txt)" | python3 -c "import json,sys; print(json.load(sys.stdin)['storage']['total_memories'])"   # note count — must equal post-state
# 8.2 Trigger one daily-horizon consolidation run NOW
curl -s -X POST http://127.0.0.1:8765/api/consolidation/trigger -H "Content-Type: application/json" -d '{"time_horizon":"daily"}'
sleep 60
# 8.3 The four safety verdicts
curl -s http://127.0.0.1:8765/api/consolidation/status     # scheduler alive, failed = 0 (jobs_executed counts SCHEDULER runs only — see below)
curl -s http://127.0.0.1:8765/api/health/detailed -H "X-API-Key: $(cat ~/stanley-ai/memory-server-api-key.txt)" | python3 -c "import json,sys; print(json.load(sys.stdin)['storage']['total_memories'])"   # count UNCHANGED vs 8.1
ls -la "$(grep CONSOLIDATION_ARCHIVE_PATH ~/stanley-ai/memory-server.sh | cut -d'"' -f2)" 2>/dev/null   # archive EMPTY
```
`AUD-8.1 | ? | trigger-status=<completed?>, heartbeat=<y/n>, jobs_executed=<n>, failed=<n>, count-delta=<0?>, archive=<empty?> | required ON INSTALL DAY: the trigger response says "status":"completed" (THIS is the execution proof, not the counter), heartbeat yes, failed 0, delta 0, archive empty. jobs_executed will be 0 today — a MANUAL trigger does NOT tick it; only the 02:00 scheduler does. Defer the jobs_executed ≥ 1 check to the morning-after (Section 4). A non-empty archive or dropped count = FAIL-CRITICAL — stop and report immediately.`

```bash
# 8.2 Nightly schedule confirmation
curl -s http://127.0.0.1:8765/api/consolidation/status   # next-run timestamps
```
`AUD-8.2 | ? | next daily=<ts> | reference schedule: daily 02:00 / weekly Sun 03:00 / monthly 1st 04:00`

---

## SECTION 9 — Ingestion Functional Test (FUNCTIONAL TEST #2 — adds ~a few memories, tagged for findability)

```bash
# 9.1 Create a harmless fingerprinted test file and ingest it.
# PAD it past the chunker's ~100-char minimum, or it stores 0 chunks and the recall test is meaningless.
printf 'Parity audit test document. Unique canary phrase: violet-anchor-%s. This extra sentence pads the file well beyond the chunker minimum so that ingestion produces at least one real, retrievable chunk for the recall check below.\n' "$(date +%s)" > /tmp/audit_canary.txt
wc -c /tmp/audit_canary.txt   # confirm > 100 bytes
cat /tmp/audit_canary.txt   # record the exact canary phrase
# key-gated installs: add -H "X-API-Key: $(cat ~/stanley-ai/memory-server-api-key.txt)"
curl -s -X POST http://127.0.0.1:8765/api/documents/upload -F "file=@/tmp/audit_canary.txt"
sleep 10
curl -s http://127.0.0.1:8765/api/documents/history | head -20   # (bare /documents/status 404s in 10.26.5 — per-upload status is /status/{upload_id})
# 9.2 Recall the canary
curl -s -X POST http://127.0.0.1:8765/api/search -H "Content-Type: application/json" -d '{"query":"violet-anchor canary phrase audit","n_results":3}'
```
`AUD-9.1 | ? | upload=<ok?>, chunks=<≥1?>, recalled=<y/n>, auto-tags=<source_file present y/n> | all yes = ingestion fully functional.`

```bash
# 9.3 MANDATORY cleanup — the canary must not permanently inflate the brain.
# Record count before delete, delete by tag, confirm count returns to pre-test value:
# Count source: /api/health/detailed (liveness /api/health has no count). Key-gated: X-API-Key header as below.
curl -s http://127.0.0.1:8765/api/health/detailed -H "X-API-Key: $(cat ~/stanley-ai/memory-server-api-key.txt)" | python3 -c "import json,sys; print(json.load(sys.stdin)['storage']['total_memories'])"   # note count (should be pre-test + chunk count)
# NOTE: there is no /api/memories/delete-by-tag route in 10.26.5. The real route is /api/manage/bulk-delete
# with a singular "tag" field (BulkDeleteRequest). It returns affected_count — record it.
curl -s -X POST http://127.0.0.1:8765/api/manage/bulk-delete -H "Content-Type: application/json" -H "X-API-Key: $(cat ~/stanley-ai/memory-server-api-key.txt)" -d '{"tag":"source_file:audit_canary.txt"}'
curl -s http://127.0.0.1:8765/api/health/detailed -H "X-API-Key: $(cat ~/stanley-ai/memory-server-api-key.txt)" | python3 -c "import json,sys; print(json.load(sys.stdin)['storage']['total_memories'])"   # count MUST equal the pre-Section-9 value
rm -f /tmp/audit_canary.txt
```
`AUD-9.2 | ? | before=<n>, after-delete=<n> | after MUST equal the count from before Step 9.1 (zero-deletion of YOUR data proven by the count returning exactly to baseline). Record before/after.`

---

## SECTION 10 — Retrieval Quality Gates (the same gates the reference passed 7/7)

```bash
# 10.1 Run the repo's own verify suite. IMPORTANT: pass --server-url so the suite queries
# through the running server (the correct path). Do NOT let verify.py open the live WAL DB
# file directly — a hot-WAL read under concurrent writes can throw "database disk image is
# malformed" even when PRAGMA integrity_check says ok (a live-read artifact, not corruption).
# If your verify.py build reads the DB file directly, run it against a WAL-safe snapshot instead:
#   sqlite3 "<LIVE_DB_PATH>" ".backup '/tmp/verify_snapshot.db'"   # then point verify.py at the snapshot
cd ~/stanley-install
# verify.py REQUIRES --db (it errors without it). Point it at a WAL-safe snapshot, and pass
# --server-url (+ --api-key-file on key-gated installs) so the date + heartbeat gates test the
# RUNNING server:
sqlite3 "<LIVE_DB_PATH>" ".backup '/tmp/verify_snapshot.db'"
python3 update/tools/verify.py --db /tmp/verify_snapshot.db \
  --server-url http://127.0.0.1:8765 \
  --api-key-file ~/stanley-ai/memory-server-api-key.txt 2>&1 | tail -30
echo "exit: $?"
# (Anonymous installs: omit --api-key-file.)
```
`AUD-10.1 | ? | <gates passed>/<total>, exit=<code> | reference = ALL PASS, exit 0. If you hit "database disk image is malformed", that is the hot-WAL read artifact (DF-8) — re-run against a WAL-safe .backup snapshot of the same data and record that result; it is NOT corruption (integrity_check=ok confirms). Each genuinely failed gate = its own FAIL line.`

```bash
# 10.2 Date-aware retrieval live check (Piece C working end-to-end)
# Pick a date you KNOW has a memory (any date your update runs stored a memory):
curl -s -X POST http://127.0.0.1:8765/api/search -H "Content-Type: application/json" -d '{"query":"record from June 8, 2026","n_results":3}'
```
`AUD-10.2 | ? | dated-entry-rank=<1?>, score=<~0.95?> | reference behavior: the dated memory at/near top with the date-match boost`

```bash
# 10.3 Ten-query spot check: run 10 searches across your real topics; confirm sane results, no garbage/"Association between" entries in any top-5
```
`AUD-10.3 | ? | 10/10 sane, association-spam=<0> | any "Association between X and Y" entry in results = FAIL (associations leaked on at some point)`

---

## SECTION 11 — Tunnel Configuration

```bash
# 11.1 Tunnel config (redact credentials/tunnel ID to first 8 chars)
sed -E 's/(credentials-file:.*|tunnel: [a-f0-9-]{8})[a-f0-9-]*/\1<REDACTED>/' ~/.cloudflared/config.yml 2>/dev/null
launchctl list | grep -i cloudflared
```
`AUD-11.1 | ? | hostnames=<list>, service-running=<y/n>, posture=<A/B> | each hostname must be protected by ITS posture: Posture A = app-key on data routes + WAF on /api/documents/* (health may be public liveness); Posture B = Access policy. A data-serving hostname with neither key-gating NOR Access = FAIL-CRITICAL. NOTE: tunnel config may live at ~/stanley-ai/config-memory.yml, not ~/.cloudflared/config.yml — check both.

---

## SECTION 12 — Report Assembly

Produce `AUDIT-REPORT-YYYY-MM-DD.md`:

1. **Executive summary (≤10 lines):** overall verdict (IDENTICAL / DRIFTED / AT-RISK), the auth-mode answer, count of PASS / DIFFERS / FAIL / FAIL-CRITICAL, and the single most important finding.
2. **Full verdict table** — every CHECK-ID line from above, in order.
3. **Raw evidence appendix** — every command's actual output under its CHECK-ID, secrets redacted per Rule 2, including the full pip freeze, the redacted launcher, any git diff, and the complete verify.py output.
4. **Findings list** — every FAIL/FAIL-CRITICAL restated with: what was observed, what the reference expects, and your best one-line hypothesis of how the drift happened. **Do not fix anything.**

Send that one file back. The analysis on this side diffs it against the reference state line by line, and any fixes come back as a gated, backed-up runbook — same discipline as every update so far.

---

## Reference fingerprint (what "identical" means, for the record)

| Item | Reference value |
|---|---|
| Brain version | mcp-memory-service **10.26.5** (pinned) |
| Repo | StanleyAIbrain/stanley-install @ **v1.5.2**, zero local diff |
| Embeddings | all-MiniLM-L6-v2, **384-dim**, sqlite-vec, WAL |
| Cognition | Variant B exactly (table in 3.2), nightly 02:00, archive permanently empty |
| Date retrieval | HYBRID_DATE_ENABLED=true, dated queries boosted ~0.95 |
| Ingestion | web-API only, PDF/TXT/MD/CSV/JSON, auto source_file:/file_type: tags, DOCX excluded |
| Security posture | **Two valid postures.** A: public hostname, key-gated `/api/*` data routes (key accepted as `X-API-Key` OR `Authorization: Bearer` — both verified live), **manually-added** WAF/firewall 403 on `/api/documents/*` (REQUIRED — the installer does not create it and those routes have no app-layer key check), public `/api/health` liveness only, connector via `/mcp?api_key=`. B: Cloudflare Access fronts the hostname (needs `/mcp` bypass/service-token). Both: **dashboard** always behind Access (email OTP only, single-email allowlist, no Google IdP), fail-closed, server-side key injection, zero secrets in repo/logs. |
| Quality gates | verify.py full suite PASS, exit 0 |
| Known-acceptable quirks | /recommendations 404s; bare date queries score-boost without re-sort (cosmetic, queued for Update 2) |
