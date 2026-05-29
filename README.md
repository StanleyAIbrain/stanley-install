# 🧠 stanley-install — the Stanley brain appliance installer

One-run installer that stands up **Jason's proven, key-gated brain** on a fresh Mac:
a local [`mcp-memory-service`](https://github.com/doobidoo/mcp-memory-service) instance
(semantic memory, SQLite-vec, `all-MiniLM-L6-v2` embeddings) exposed over a Cloudflare
Tunnel and connected to claude.ai via a custom MCP connector.

This is a **templatized copy of the exact setup running on Jason's Mac mini** — not config
written from scratch. Version-pinned (`requirements.txt`) for parity with Jason's brain.

## What you get
- A self-hosted memory server on `127.0.0.1:<PORT>`, **API-key gated** (no anonymous, no OAuth).
- A public HTTPS endpoint `https://brain.<your-domain>/mcp` via a named Cloudflare Tunnel.
- Two `launchd` jobs (brain + tunnel) that auto-start on boot and restart on crash.
- A claude.ai connector URL: `https://brain.<your-domain>/mcp?api_key=<key>`.
- The `stanleyai-brain` Claude Code plugin (skills) — installed separately (see below).

> **Not included:** the cognition cron cycles (curiosity / consolidate / dream / report /
> goal_eval). This mirrors Jason's *actual running* setup — skills only.

## Requirements
- macOS (Apple Silicon; paths assume Homebrew at `/opt/homebrew`)
- Homebrew, Python 3.13+, Claude Code
- A domain you control in Cloudflare (for the public hostname)
- `cloudflared` (the installer brew-installs it if missing)

## Install (what Jordan's Claude Code runs)
```bash
git clone https://github.com/StanleyAIbrain/stanley-install.git
cd stanley-install
./install.sh
```
The installer will:
1. Preflight (macOS / brew / python / claude / cloudflared).
2. Ask for your **base domain** → derives `brain.<domain>`.
3. Create `~/stanley-ai/`, a Python venv, and `pip install` the pinned deps.
4. Generate an API key (`openssl rand -hex 32`), saved `chmod 600`.
5. Render + load the brain `launchd` job.
6. Verify locally: no-key → **401**, key → **200**.
7. `cloudflared tunnel login` — **the one manual step** (browser click).
8. Create the named tunnel.
9. Render the tunnel config, route DNS, load the tunnel `launchd` job.
10. Verify publicly: no-key → **401**, `?api_key=` → **200**.
11. Print the **connector URL** to paste into claude.ai → Settings → Connectors.
12. Print the Claude Code plugin commands.
13. Print the final round-trip test.

### After install.sh — two manual steps
1. **claude.ai connector:** Settings → Connectors → Add custom connector → paste the printed
   `https://brain.<domain>/mcp?api_key=<key>` URL.
2. **Claude Code plugin (skills):**
   ```
   /plugin marketplace add StanleyAIbrain/brain
   /plugin install stanleyai-brain
   ```

## Configuration (overrides)
The same `install.sh` runs for production and sandbox. Defaults are production; override via env:

| Var | Default | Purpose |
|---|---|---|
| `INSTALL_DIR` | `$HOME/stanley-ai` | where venv/scripts/data/key live |
| `PORT` | `8765` | brain HTTP+SSE port |
| `BASE_DOMAIN` | _prompted_ | your Cloudflare domain |
| `BRAIN_HOSTNAME` | `brain.$BASE_DOMAIN` | public hostname |
| `TUNNEL_NAME` | `stanley-brain` | cloudflared named tunnel |
| `LAUNCHD_LABEL_BRAIN` | `com.stanleyai.memory-server` | brain job label |
| `LAUNCHD_LABEL_TUNNEL` | `com.stanleyai.memory-tunnel` | tunnel job label |
| `SANDBOX` | `0` | `1` = quick tunnel, no login/DNS, no prompts (for testing) |
| `ASSUME_YES` | `0` | `1` = non-interactive |

**Safety:** the installer refuses to run if `LAUNCHD_LABEL_BRAIN` is already loaded — it will
not clobber a brain that's already running.

## Package layout
```
install.sh                                      installer engine
requirements.txt                                pinned 85-pkg freeze (parity w/ Jason)
templates/memory-server.sh.tmpl                 brain launch script
templates/memory-tunnel.sh.tmpl                 named-tunnel runner
templates/config-memory.yml.tmpl                cloudflared ingress
templates/com.stanleyai.memory-server.plist.tmpl  brain launchd job
templates/com.stanleyai.memory-tunnel.plist.tmpl   tunnel launchd job
```
Placeholders: `{{USER_HOME}} {{INSTALL_DIR}} {{PORT}} {{BASE_DOMAIN}} {{BRAIN_HOSTNAME}}
{{TUNNEL_NAME}} {{TUNNEL_UUID}} {{TUNNEL_CREDS_FILE}} {{LAUNCHD_LABEL_BRAIN}}
{{LAUNCHD_LABEL_TUNNEL}} {{API_KEY}}`.

## Uninstall
```bash
launchctl unload ~/Library/LaunchAgents/com.stanleyai.memory-server.plist
launchctl unload ~/Library/LaunchAgents/com.stanleyai.memory-tunnel.plist
rm -f ~/Library/LaunchAgents/com.stanleyai.memory-{server,tunnel}.plist
rm -rf ~/stanley-ai/{memory-venv,data,logs,memory-server.sh,memory-tunnel.sh,config-memory.yml,memory-server-api-key.txt}
# remove the tunnel + DNS from your Cloudflare account separately
```
