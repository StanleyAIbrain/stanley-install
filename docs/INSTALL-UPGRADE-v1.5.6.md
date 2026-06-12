# Installing the Latest Brain Update → v1.5.6 (complete reliability release)

Hi — this brings your brain to the current release (**v1.5.6**): full **self-healing**
for both the brain itself AND its public tunnel. If either ever goes down, it comes
back on its own. Everything here runs on your own machine and your own accounts —
nothing connects back to anyone else's setup.

> **This is the single complete install.** If you haven't installed v1.5.5 yet, you do
> NOT need to do it separately — v1.5.6 contains everything (self-heal watchdog with
> ghost-process clearing, safe restart tool, off-machine alarm, and the new tunnel
> auto-fixer). Install from v1.5.6 or later only.

> **Before you start:** this updates your existing install. It does not delete anything —
> your memories are safe throughout. **Your Claude should review this whole guide and print
> every command it will run before running anything.** If anything looks wrong at any step,
> stop and message — don't push through.

> **You're upgrading from v1.5.2.** Your install came back IDENTICAL on v1.5.2, which means
> cognition and ingestion (and the security hardening) are **already live on your brain**.
> The real new work here is **Sections 5–6 (self-healing + tunnel)**. Sections 3–4 are quick
> "still healthy?" confirmations, not re-installs.

---

## 1. What's new in this update

- **Self-healing (v1.5.5, hardened):** a small helper checks your brain every minute.
  If it ever goes down, it turns it back on by itself (about 2 minutes) and texts you one
  line — "Brain was down at [time], restarted, back up." Silent otherwise. No daily "I'm OK"
  messages. Includes ghost-process clearing: a stray leftover copy of the brain squatting on
  the port gets removed automatically (and ONLY a provable stray copy — never anything else).
- **Tunnel auto-fixer (new in v1.5.6):** your brain can be healthy at home while the
  PUBLIC side is dark — the Cloudflare tunnel's connections can wedge. A second silent
  helper now fixes that: if the public side is down while the brain is fine locally, it
  restarts the tunnel automatically. It never texts (the off-machine alarm below stays
  the only loud voice).
- **An off-machine down alarm:** a check you run on your own Cloudflare that texts you if
  your brain is unreachable and the helpers couldn't fix it (e.g. your computer lost power).
- **A safe restart tool:** one command to safely stop/start/restart your brain that won't
  ever leave it half-running.
- **Everything from 1.4 through 1.5.3 (already on your brain from v1.5.2):** cognition and
  document ingestion, plus the security hardening.

One known cosmetic note: a couple of internal "date labels" on very recent memories sit in
the old spot. It's harmless, changes nothing you'll see, and is on a separate cleanup list.

---

## 2. Update your repo to v1.5.6

> Your brain stays pinned to the proven engine (10.26.5). This updates your *setup files*, not the engine.

```bash
cd ~/stanley-install        # or wherever your clone lives
git fetch --tags
git checkout v1.5.6
# self-test: you're on the tag AND the files are present
[ "$(git rev-parse HEAD)" = "$(git rev-list -n1 v1.5.6)" ] && echo "on v1.5.6 ✓"
ls update/reliability/brain-watchdog.sh update/reliability/brain-restart.sh update/reliability/brain-tunnel-watchdog.sh update/RUNBOOK-v1.4.md
```

**Upgrade-from-v1.5.2 note:** you do **not** re-apply the security patch or re-activate
cognition/ingestion — those are already in your running install from v1.5.2 and the engine
code on disk is unchanged. Checking out v1.5.6 only adds the new reliability files to your
clone (which you set up in Sections 5–6). Nothing about your running brain changes at this step.

**CHECK:** prints `on v1.5.6 ✓` and the four files exist.

---

## 3. Confirm cognition is still on (no re-install)

You activated this at v1.5.2. Just confirm it's healthy:

```bash
KEY="$(cat <INSTALL_DIR>/memory-server-api-key.txt)"
curl -s http://127.0.0.1:<PORT>/api/consolidation/status -H "X-API-Key: $KEY"
ls <INSTALL_DIR>/data/consolidation_archive/ 2>/dev/null   # should be empty
```
**Healthy looks like:** `"running":true`, `"jobs_failed":0`, a `next_daily` timestamp, and
the archive folder **empty** (empty = nothing was ever forgotten/compressed).

If for any reason `running` is false, your `<INSTALL_DIR>/memory-server.sh` should contain
this exact block before its final `exec` line (the three `false` lines are load-bearing —
never flip them):
```bash
export MCP_CONSOLIDATION_ENABLED=true
export MCP_ASSOCIATIONS_ENABLED=false     # load-bearing OFF
export MCP_FORGETTING_ENABLED=false       # load-bearing OFF (zero-deletion)
export MCP_COMPRESSION_ENABLED=false      # load-bearing OFF (zero-deletion)
export MCP_CLUSTERING_ENABLED=true
export MCP_DECAY_ENABLED=true
export MCP_CONSOLIDATION_ARCHIVE_PATH="<your existing archive path>"
```
Turn it off any time = set `MCP_CONSOLIDATION_ENABLED=false` and restart (Section 5b tool).

---

## 4. Confirm document loading works (no re-install)

Ingestion is already available (web-API only; there is no MCP tool for it). Supported:
**PDF, TXT, MD, CSV, JSON** (DOCX not yet). Quick confirm with a padded throwaway file that
you delete afterward so it doesn't change your count:

```bash
PRE=$(curl -s http://127.0.0.1:<PORT>/api/health/detailed -H "X-API-Key: $KEY" | python3 -c "import json,sys;print(json.load(sys.stdin)['storage']['total_memories'])")
printf 'Ingestion check. Unique phrase: violet-anchor-%s. This sentence pads the file past the chunker minimum so it stores at least one chunk.\n' "$(date +%s)" > /tmp/check.txt
curl -s -X POST http://127.0.0.1:<PORT>/api/documents/upload -H "X-API-Key: $KEY" -F "file=@/tmp/check.txt" -F "tags=project:<yours>,type:document"
sleep 5
curl -s http://127.0.0.1:<PORT>/api/documents/history -H "X-API-Key: $KEY"   # status:completed, chunks_stored >= 1
curl -s -X POST http://127.0.0.1:<PORT>/api/search -H "X-API-Key: $KEY" -H "Content-Type: application/json" -d '{"query":"violet-anchor","n_results":1}'  # should return your file
# cleanup so the count returns exactly:
curl -s -X POST http://127.0.0.1:<PORT>/api/manage/bulk-delete -H "X-API-Key: $KEY" -H "Content-Type: application/json" -d '{"tag":"source_file:check.txt"}'
POST=$(curl -s http://127.0.0.1:<PORT>/api/health/detailed -H "X-API-Key: $KEY" | python3 -c "import json,sys;print(json.load(sys.stdin)['storage']['total_memories'])")
echo "pre=$PRE post=$POST (equal = clean)"; rm -f /tmp/check.txt
```
Chunks are auto-labeled with `source_file:` and `file_type:` tags.
**CHECK:** `chunks_stored ≥ 1`, the phrase is returned, and `pre == post` after cleanup.

---

## 5. Set up self-healing (the important part)

> The helper only ever removes a process that is provably a stray copy of the brain
> itself (right port AND right program signature AND not the one the system is
> managing). Anything else on the port gets logged and left alone. It will never
> kill the wrong thing.

Three pieces, all on your own machine and accounts.

**5a. Telegram creds file** (so the helper can text you), `chmod 600`:
```bash
mkdir -p ~/.config/brain
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' '<your-bot-token>' '<your-chat-id>' > ~/.config/brain/telegram.env
chmod 600 ~/.config/brain/telegram.env
ls -l ~/.config/brain/telegram.env   # must show -rw-------
```
Your bot token is read from this file and passed to the network call through a private
channel — it never appears in any command line or process listing.

**5b. Install the scripts + the safe restart tool:**
```bash
mkdir -p ~/bin
cp update/reliability/brain-watchdog.sh update/reliability/brain-restart.sh update/reliability/brain-tunnel-watchdog.sh ~/bin/
chmod +x ~/bin/brain-watchdog.sh ~/bin/brain-restart.sh ~/bin/brain-tunnel-watchdog.sh
# if your launchd label or port differ from the stock defaults
# (com.stanleyai.memory-server, 8765), edit the CONFIG block at the top of each script.
~/bin/brain-restart.sh verify    # local health + row count, no changes — sanity check it runs
```
`brain-restart.sh` is now your one move for stop/start/restart: `~/bin/brain-restart.sh restart`.
It never reports success without a verified local 200, and texts you if it can't bring the brain back.

**5c. The watchdog (helper) — one crontab line, runs every minute:**
```bash
( crontab -l 2>/dev/null; echo '* * * * * /bin/bash $HOME/bin/brain-watchdog.sh' ) | crontab -
crontab -l | grep brain-watchdog   # confirm the line is there
```
It stays silent unless there's a real incident (one "down→back up" text, or one
"restart FAILED — needs you"). Its local log is `/tmp/brain-watchdog/tick.log`.

**5d. Your own off-machine down alarm (optional, recommended):** deploy the liveness Worker
to **your** Cloudflare so it can text you even if your computer is fully off.
```bash
cd update/reliability/liveness-worker
# edit wrangler.toml: set CHECK_URL to YOUR brain's public health URL (https://brain.<your-domain>/api/health)
wrangler secret put TG_TOKEN     # your Telegram bot token — entered as a SECRET, never typed in a command (no leak)
wrangler secret put TG_CHAT      # your Telegram chat id
wrangler deploy
```
It escalates only if your brain is down ≥4 minutes and the helpers haven't recovered it.

> Everything here uses **your** domain and **your** Telegram — entirely yours and isolated.

---

## 6. Tunnel self-healing (new in v1.5.6)

**6a. Enable the tunnel auto-fixer.** You already copied it in 5b; it runs automatically
off the SAME crontab line as the watchdog (no new cron entry). It's disabled until you
configure it — edit the CONFIG block at the top of `~/bin/brain-tunnel-watchdog.sh`:
- `TW_EDGE_URL` = your public health URL (e.g. `https://brain.<your-domain>/api/health`)
- `TW_LABEL` = your cloudflared launchd label (find it: `launchctl list | grep -i cloudflared`)

Behavior: if the public side fails 2 checks in a row while the brain is healthy locally,
it restarts the tunnel (10-minute cooldown). **It never texts** — the off-machine alarm
from 5d stays the only loud voice, and it only speaks if this fixer couldn't fix it.

**6b. Only if your tunnel log shows repeated QUIC timeouts** — lines like
`failed to accept QUIC stream: timeout: no recent network activity` — switch the tunnel
to steadier TCP transport. In YOUR tunnel config file (commonly `~/.cloudflared/config.yml`,
or wherever your install keeps it) add one line:
```yaml
protocol: http2
```
then restart the tunnel:
```bash
launchctl kickstart -k gui/$(id -u)/<your-cloudflared-label>
```
and confirm the tunnel log now registers connections with `protocol=http2`.
If your tunnel log is clean, skip 6b — you still get the auto-fixer.

---

## 7. Prove it heals (do this once)

See it recover before you ever need it:
```bash
~/bin/brain-restart.sh stop      # take the brain down on purpose
# hands off — within ~2 minutes the watchdog kickstarts it and you get ONE text.
~/bin/brain-restart.sh verify    # confirm local=200 again
```
You should get **exactly one** text. A stream of messages = misconfig — stop and check the
CONFIG blocks. If it doesn't come back in ~4 minutes, run `~/bin/brain-restart.sh start` by
hand and message.

---

## 8. If something goes wrong

- Your memories are never touched by any of this — it only stops/starts programs, never edits data.
- The safe restart tool (5b) is your one move for almost anything: `~/bin/brain-restart.sh restart`, wait ~1 min, re-check.
- Common snags:
  - **Brain won't come up after a stop** → `~/bin/brain-restart.sh start` (a bare `launchctl load` may not spawn it — that's the whole reason this tool exists).
  - **Watchdog never texts on a real outage** → check the creds file path/permissions (`~/.config/brain/telegram.env`, `-rw-------`) and `crontab -l` shows the line.
  - **A flood of texts** → misconfig; remove the crontab line, fix the CONFIG block, re-add.
  - **Public side down but local fine** → that's the tunnel; the auto-fixer (6a) should clear it within ~3 minutes. If it keeps happening, do 6b (http2).
- Anything you're unsure about: stop and message. Don't force it.

---

*This setup is entirely yours — your machine, your domain, your Cloudflare, your Telegram. It runs independently and connects to nothing outside your own accounts.*
