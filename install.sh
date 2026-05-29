#!/bin/bash
# ============================================================================
# stanley-install — the Stanley appliance installer
# Packages Jason's proven, key-gated brain (mcp-memory-service + Cloudflare
# Tunnel + launchd) into a one-run installer.
#
# Same script runs for PRODUCTION and SANDBOX. Defaults are production values;
# sandbox passes overrides via env vars.
#
# OVERRIDES (env vars; all optional):
#   INSTALL_DIR            default: $HOME/stanley-ai
#   PORT                  default: 8765
#   BASE_DOMAIN           prompted if unset (production); ignored in sandbox
#   BRAIN_HOSTNAME        default: brain.$BASE_DOMAIN
#   TUNNEL_NAME           default: stanley-brain
#   LAUNCHD_LABEL_BRAIN   default: com.stanleyai.memory-server
#   LAUNCHD_LABEL_TUNNEL  default: com.stanleyai.memory-tunnel
#   SANDBOX               default: 0   (1 = quick tunnel, no login/DNS, no prompts)
#   ASSUME_YES            default: 0   (1 = non-interactive)
#
# Usage:
#   ./install.sh                         # production, interactive
#   SANDBOX=1 INSTALL_DIR=... PORT=8767 TUNNEL_NAME=... ./install.sh
# ============================================================================
set -euo pipefail

# ---- locate the package (templates live next to this script) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/templates"

# ---- config (defaults = production) ----
INSTALL_DIR="${INSTALL_DIR:-$HOME/stanley-ai}"
PORT="${PORT:-8765}"
TUNNEL_NAME="${TUNNEL_NAME:-stanley-brain}"
LAUNCHD_LABEL_BRAIN="${LAUNCHD_LABEL_BRAIN:-com.stanleyai.memory-server}"
LAUNCHD_LABEL_TUNNEL="${LAUNCHD_LABEL_TUNNEL:-com.stanleyai.memory-tunnel}"
SANDBOX="${SANDBOX:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
USER_HOME="$HOME"
LA_DIR="$HOME/Library/LaunchAgents"

c_grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_red(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_blu(){ printf '\033[34m%s\033[0m\n' "$*"; }
die(){ c_red "✗ $*"; exit 1; }
step(){ printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

MCP_INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"stanley-install","version":"1.0"}}}'
ACCEPT='Accept: application/json, text/event-stream'

# Render a template to a destination, substituting all placeholders.
render(){
  local src="$1" dst="$2"
  sed \
    -e "s|{{USER_HOME}}|$USER_HOME|g" \
    -e "s|{{INSTALL_DIR}}|$INSTALL_DIR|g" \
    -e "s|{{PORT}}|$PORT|g" \
    -e "s|{{BASE_DOMAIN}}|${BASE_DOMAIN:-}|g" \
    -e "s|{{BRAIN_HOSTNAME}}|${BRAIN_HOSTNAME:-}|g" \
    -e "s|{{TUNNEL_NAME}}|$TUNNEL_NAME|g" \
    -e "s|{{TUNNEL_UUID}}|${TUNNEL_UUID:-}|g" \
    -e "s|{{TUNNEL_CREDS_FILE}}|${TUNNEL_CREDS_FILE:-}|g" \
    -e "s|{{LAUNCHD_LABEL_BRAIN}}|$LAUNCHD_LABEL_BRAIN|g" \
    -e "s|{{LAUNCHD_LABEL_TUNNEL}}|$LAUNCHD_LABEL_TUNNEL|g" \
    -e "s|{{API_KEY}}|${API_KEY:-}|g" \
    "$src" > "$dst"
}

# ============================================================================
step "1. Preflight"
[ "$(uname)" = "Darwin" ] || die "macOS only."
command -v brew >/dev/null || die "Homebrew required: https://brew.sh"
PY="$(command -v python3.13 || true)"
[ -n "$PY" ] || PY="$(command -v python3 || true)"
[ -n "$PY" ] || die "Python 3.13+ required (brew install python@3.13)."
PYV="$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
c_grn "  ✓ macOS, Homebrew, Python $PYV ($PY)"
command -v claude >/dev/null && c_grn "  ✓ Claude Code present" || c_red "  ! Claude Code not found (needed later for the plugin step)"
if command -v cloudflared >/dev/null; then
  c_grn "  ✓ cloudflared $(cloudflared --version 2>/dev/null | awk '{print $3}')"
else
  c_blu "  installing cloudflared via brew…"; brew install cloudflared || die "cloudflared install failed."
fi

# SAFETY GUARD: never clobber an already-loaded brain (protects Jason's live brain
# from an accidental default-value run).
if launchctl list 2>/dev/null | grep -q "[[:space:]]$LAUNCHD_LABEL_BRAIN$"; then
  die "launchd label '$LAUNCHD_LABEL_BRAIN' is already loaded. Refusing to clobber a running brain.
     Use SANDBOX=1 with sandbox labels, or pass distinct LAUNCHD_LABEL_BRAIN / INSTALL_DIR / PORT."
fi

# ============================================================================
step "2. Domain → brain hostname"
if [ "$SANDBOX" = "1" ]; then
  BRAIN_HOSTNAME="${BRAIN_HOSTNAME:-sandbox.local}"   # placeholder; quick tunnel sets the real public URL
  c_blu "  SANDBOX mode: skipping domain prompt; public URL comes from a throwaway quick tunnel."
else
  if [ -z "${BASE_DOMAIN:-}" ]; then
    [ "$ASSUME_YES" = "1" ] && die "BASE_DOMAIN required in non-interactive mode."
    read -r -p "  Enter your base domain (e.g. jordandomain.com): " BASE_DOMAIN
  fi
  [ -n "${BASE_DOMAIN:-}" ] || die "No base domain."
  BRAIN_HOSTNAME="${BRAIN_HOSTNAME:-brain.$BASE_DOMAIN}"
  c_grn "  ✓ brain hostname: $BRAIN_HOSTNAME"
fi

# ============================================================================
step "3. Install dir + Python venv + pinned deps"
mkdir -p "$INSTALL_DIR/logs" "$INSTALL_DIR/data/backups"
if [ ! -d "$INSTALL_DIR/memory-venv" ]; then
  "$PY" -m venv "$INSTALL_DIR/memory-venv"
fi
# shellcheck disable=SC1091
source "$INSTALL_DIR/memory-venv/bin/activate"
c_blu "  pip install -r requirements.txt (pinned, ~85 pkgs; first run downloads torch — slow)…"
pip install --quiet --upgrade pip >/dev/null 2>&1 || true
pip install --quiet -r "$SCRIPT_DIR/requirements.txt"
MV="$(memory --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo '?')"
c_grn "  ✓ mcp-memory-service $MV installed in $INSTALL_DIR/memory-venv"

# ============================================================================
step "4. Generate API key"
API_KEY="$(openssl rand -hex 32)"
printf '%s\n' "$API_KEY" > "$INSTALL_DIR/memory-server-api-key.txt"
chmod 600 "$INSTALL_DIR/memory-server-api-key.txt"
c_grn "  ✓ key written to $INSTALL_DIR/memory-server-api-key.txt (chmod 600)"

# ============================================================================
step "5. Render brain launch script + launchd plist, then load"
render "$TPL/memory-server.sh.tmpl"  "$INSTALL_DIR/memory-server.sh";  chmod +x "$INSTALL_DIR/memory-server.sh"
render "$TPL/com.stanleyai.memory-server.plist.tmpl" "$LA_DIR/$LAUNCHD_LABEL_BRAIN.plist"
# validate the plist parses before loading
plutil -lint "$LA_DIR/$LAUNCHD_LABEL_BRAIN.plist" >/dev/null || die "brain plist failed plutil lint"
launchctl unload "$LA_DIR/$LAUNCHD_LABEL_BRAIN.plist" 2>/dev/null || true
launchctl load -w "$LA_DIR/$LAUNCHD_LABEL_BRAIN.plist"
c_grn "  ✓ brain launched via launchd ($LAUNCHD_LABEL_BRAIN)"

# ============================================================================
step "6. VERIFY brain locally (fresh empty DB)"
curl --retry 60 --retry-delay 1 --retry-connrefused -s -o /dev/null \
  -w "  /api/health → HTTP %{http_code}\n" "http://127.0.0.1:$PORT/api/health"
NK="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/mcp" -H 'Content-Type: application/json' -H "$ACCEPT" -d "$MCP_INIT")"
WK="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/mcp" -H 'Content-Type: application/json' -H "Authorization: Bearer $API_KEY" -H "$ACCEPT" -d "$MCP_INIT")"
echo "  no-key /mcp → $NK (expect 401)   with-key /mcp → $WK (expect 200)"
[ "$NK" = "401" ] || die "local no-key check expected 401, got $NK"
[ "$WK" = "200" ] || die "local with-key check expected 200, got $WK"
c_grn "  ✓ brain is key-gated locally"

# ============================================================================
if [ "$SANDBOX" = "1" ]; then
  step "7-9 (SANDBOX). Render named-tunnel artifacts (validate only) + start quick tunnel"
  # Render production tunnel artifacts so the templates are proven to substitute,
  # WITHOUT creating real named tunnels / DNS (avoids live + cloud collision).
  TUNNEL_UUID="SANDBOX-UUID" TUNNEL_CREDS_FILE="$INSTALL_DIR/SANDBOX-creds.json" \
    render "$TPL/config-memory.yml.tmpl" "$INSTALL_DIR/config-memory.yml"
  render "$TPL/memory-tunnel.sh.tmpl" "$INSTALL_DIR/memory-tunnel.sh"; chmod +x "$INSTALL_DIR/memory-tunnel.sh"
  render "$TPL/com.stanleyai.memory-tunnel.plist.tmpl" "$INSTALL_DIR/$LAUNCHD_LABEL_TUNNEL.plist.rendered"
  plutil -lint "$INSTALL_DIR/$LAUNCHD_LABEL_TUNNEL.plist.rendered" >/dev/null || die "tunnel plist failed lint"
  c_grn "  ✓ named-tunnel config + runner + plist rendered & validated (not loaded in sandbox)"

  c_blu "  starting throwaway quick tunnel (cloudflared --url)…"
  # quick tunnels have no uptime guarantee and the provisioning API can return a
  # transient error ("Unknown output format") — retry the whole launch a few times.
  PUBLIC_URL=""
  for attempt in 1 2 3; do
    : > "$INSTALL_DIR/quick-tunnel.log"
    nohup cloudflared tunnel --url "http://localhost:$PORT" > "$INSTALL_DIR/quick-tunnel.log" 2>&1 &
    QTPID=$!; echo "$QTPID" > "$INSTALL_DIR/quick-tunnel.pid"; disown
    # wait up to 40s; bail early only if the process actually died (don't kill a live handshake)
    for _ in $(seq 1 40); do
      PUBLIC_URL="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$INSTALL_DIR/quick-tunnel.log" | head -1 || true)"
      [ -n "$PUBLIC_URL" ] && break
      kill -0 "$QTPID" 2>/dev/null || break
      sleep 1
    done
    [ -n "$PUBLIC_URL" ] && break
    c_red "  quick tunnel attempt $attempt got no URL (cloudflare quick-tunnel provisioning can be rate-limited); retrying…"
    kill "$QTPID" 2>/dev/null || true
  done
  [ -n "$PUBLIC_URL" ] || die "quick tunnel URL not obtained after 3 attempts (cloudflare quick-tunnel rate limit; named-tunnel production path is unaffected)"
  c_grn "  ✓ quick tunnel: $PUBLIC_URL"
else
  step "7. cloudflared tunnel login (one manual browser click)"
  cloudflared tunnel login
  step "8. Create named tunnel"
  cloudflared tunnel create "$TUNNEL_NAME" || true
  TUNNEL_UUID="$(cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" '$2==n{print $1; exit}')"
  [ -n "$TUNNEL_UUID" ] || die "could not resolve tunnel UUID for $TUNNEL_NAME"
  TUNNEL_CREDS_FILE="$HOME/.cloudflared/$TUNNEL_UUID.json"
  c_grn "  ✓ tunnel $TUNNEL_NAME = $TUNNEL_UUID"
  step "9. Render tunnel config + runner + plist; route DNS; load"
  render "$TPL/config-memory.yml.tmpl" "$INSTALL_DIR/config-memory.yml"
  render "$TPL/memory-tunnel.sh.tmpl" "$INSTALL_DIR/memory-tunnel.sh"; chmod +x "$INSTALL_DIR/memory-tunnel.sh"
  render "$TPL/com.stanleyai.memory-tunnel.plist.tmpl" "$LA_DIR/$LAUNCHD_LABEL_TUNNEL.plist"
  plutil -lint "$LA_DIR/$LAUNCHD_LABEL_TUNNEL.plist" >/dev/null || die "tunnel plist failed lint"
  cloudflared tunnel route dns "$TUNNEL_NAME" "$BRAIN_HOSTNAME" || true
  launchctl unload "$LA_DIR/$LAUNCHD_LABEL_TUNNEL.plist" 2>/dev/null || true
  launchctl load -w "$LA_DIR/$LAUNCHD_LABEL_TUNNEL.plist"
  PUBLIC_URL="https://$BRAIN_HOSTNAME"
  c_grn "  ✓ tunnel running; public base $PUBLIC_URL"
fi

# ============================================================================
step "10. VERIFY public"
curl --retry 60 --retry-delay 2 --retry-all-errors -s -o /dev/null \
  -w "  public /api/health → HTTP %{http_code}\n" "$PUBLIC_URL/api/health"
PNK="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PUBLIC_URL/mcp" -H 'Content-Type: application/json' -H "$ACCEPT" -d "$MCP_INIT")"
PWK="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PUBLIC_URL/mcp?api_key=$API_KEY" -H 'Content-Type: application/json' -H "$ACCEPT" -d "$MCP_INIT")"
echo "  public no-key /mcp → $PNK (expect 401)   public ?api_key= → $PWK (expect 200)"
[ "$PNK" = "401" ] || die "public no-key check expected 401, got $PNK"
[ "$PWK" = "200" ] || die "public with-key check expected 200, got $PWK"
c_grn "  ✓ brain reachable publicly, key-gated, no Cloudflare Access in front"

# ============================================================================
step "11-13. Connector + plugin + test"
CONNECTOR_URL="$PUBLIC_URL/mcp?api_key=$API_KEY"
cat <<EOF

$(c_grn "INSTALL COMPLETE")

  CONNECTOR URL (paste in claude.ai → Settings → Connectors → Add custom):
    $CONNECTOR_URL

  CLAUDE CODE PLUGIN (run these in Claude Code separately):
    /plugin marketplace add StanleyAIbrain/brain
    /plugin install stanleyai-brain

  FINAL TEST:
    1. Add the connector above in claude.ai.
    2. In a chat: "store a memory: my appliance works" → then ask it to retrieve.
    3. Confirm the round-trip succeeds.

  Your API key lives at: $INSTALL_DIR/memory-server-api-key.txt
EOF
