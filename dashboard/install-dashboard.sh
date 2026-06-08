#!/bin/bash
# ===========================================================================
# install-dashboard.sh — put an email-OTP-gated dashboard in front of your
# already-installed brain (mcp-memory-service).
#
# Result: https://dashboard.<your-domain> → Cloudflare Access (email One-time
# PIN) → a key-injecting Worker → your brain. You log in by email; the brain
# API key is injected server-side and NEVER reaches your browser.
#
# This is a pure ADDITION in front of your brain. It does not touch your brain,
# tunnel, or launchd jobs. Removing the Worker + Access app fully reverts it.
#
# REQUIRED (env, else prompted):
#   BASE_DOMAIN     your Cloudflare domain  (derives dashboard.<d> + brain.<d>)
#   ACCESS_EMAIL    the email allowed to log in (your own)
#   CF_API_TOKEN    a Cloudflare API token with these scopes on YOUR account/zone:
#                     Account > Workers Scripts            : Edit
#                     Account > Access: Apps and Policies  : Edit
#                     Zone    > Workers Routes             : Edit   (binds the custom domain)
#                     Zone    > DNS                        : Edit   (your zone)
#                     Zone    > Zone                       : Read   (your zone)
#                   (Cloudflare's "Edit Cloudflare Workers" template covers the two Workers
#                    scopes; just add Access: Apps and Policies + DNS.)
#
# OPTIONAL:
#   DASHBOARD_HOSTNAME   default dashboard.$BASE_DOMAIN
#   BRAIN_HOSTNAME       default brain.$BASE_DOMAIN   (the Worker's upstream)
#   WORKER_NAME          default dashboard-proxy
#   BRAIN_KEY_FILE       default $HOME/stanley-ai/memory-server-api-key.txt
#   CF_ACCOUNT_ID / CF_ACCESS_TEAM_DOMAIN / OTP_IDP_ID   pre-set to skip discovery
#   DASHBOARD_DEPLOY_TOKEN / DASHBOARD_REST_TOKEN        per-phase token override
#                                                        (testing / split-scope tokens)
# ===========================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="$SCRIPT_DIR/templates"
API="https://api.cloudflare.com/client/v4"

c_grn(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_red(){ printf '\033[31m%s\033[0m\n' "$*"; }
c_blu(){ printf '\033[34m%s\033[0m\n' "$*"; }
die(){ c_red "✗ $*"; exit 1; }
step(){ printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

# ---- config / inputs ----
BASE_DOMAIN="${BASE_DOMAIN:-}"
ACCESS_EMAIL="${ACCESS_EMAIL:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
WORKER_NAME="${WORKER_NAME:-dashboard-proxy}"
BRAIN_KEY_FILE="${BRAIN_KEY_FILE:-$HOME/stanley-ai/memory-server-api-key.txt}"

# ============================================================================
step "1. Preflight"
for b in node npm python3 curl; do command -v "$b" >/dev/null || die "$b is required"; done
c_grn "  ✓ node $(node -v), npm $(npm -v), python3, curl"

[ -n "$BASE_DOMAIN" ]   || read -r -p "  Your Cloudflare domain (e.g. jordanbrain.com): " BASE_DOMAIN
[ -n "$BASE_DOMAIN" ]   || die "BASE_DOMAIN required"
[ -n "$ACCESS_EMAIL" ]  || read -r -p "  Email allowed to log in: " ACCESS_EMAIL
[ -n "$ACCESS_EMAIL" ]  || die "ACCESS_EMAIL required"
[ -n "$CF_API_TOKEN" ]  || { read -r -s -p "  Cloudflare API token: " CF_API_TOKEN; echo; }
[ -n "$CF_API_TOKEN" ]  || die "CF_API_TOKEN required"

DEPLOY_TOKEN="${DASHBOARD_DEPLOY_TOKEN:-$CF_API_TOKEN}"
REST_TOKEN="${DASHBOARD_REST_TOKEN:-$CF_API_TOKEN}"
DASHBOARD_HOSTNAME="${DASHBOARD_HOSTNAME:-dashboard.$BASE_DOMAIN}"
BRAIN_HOSTNAME="${BRAIN_HOSTNAME:-brain.$BASE_DOMAIN}"
c_grn "  ✓ dashboard=$DASHBOARD_HOSTNAME  upstream=$BRAIN_HOSTNAME  worker=$WORKER_NAME"
[ -f "$BRAIN_KEY_FILE" ] || die "brain key file not found: $BRAIN_KEY_FILE  (set BRAIN_KEY_FILE=...)"

cf_get(){ curl -s -H "Authorization: Bearer $REST_TOKEN" "$API$1"; }

# ============================================================================
step "2. Discover account / Access team / One-time-PIN identity provider"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-$(cf_get /accounts | python3 -c 'import sys,json;print(((json.load(sys.stdin).get("result") or [{}])[0]).get("id",""))')}"
[ -n "$CF_ACCOUNT_ID" ] || die "could not resolve account id (token missing Account read?)"
CF_ACCESS_TEAM_DOMAIN="${CF_ACCESS_TEAM_DOMAIN:-$(cf_get "/accounts/$CF_ACCOUNT_ID/access/organizations" | python3 -c 'import sys,json;print((json.load(sys.stdin).get("result") or {}).get("auth_domain",""))')}"
[ -n "$CF_ACCESS_TEAM_DOMAIN" ] || die "could not resolve Access team domain — is Zero Trust set up on this account? (token missing Access read?)"
OTP_IDP_ID="${OTP_IDP_ID:-$(cf_get "/accounts/$CF_ACCOUNT_ID/access/identity_providers" | python3 -c 'import sys,json
ids=[p["id"] for p in (json.load(sys.stdin).get("result") or []) if p.get("type")=="onetimepin"]
print(ids[0] if ids else "")')}"
[ -n "$OTP_IDP_ID" ] || die "no One-time PIN identity provider in your Zero Trust org. Enable it under Zero Trust → Settings → Authentication, then re-run."
c_grn "  ✓ account=$CF_ACCOUNT_ID  team=$CF_ACCESS_TEAM_DOMAIN  otp_idp=$OTP_IDP_ID"

render_wrangler(){  # $1 = AUD (may be empty)
  sed -e "s|{{WORKER_NAME}}|$WORKER_NAME|g" \
      -e "s|{{BRAIN_HOSTNAME}}|$BRAIN_HOSTNAME|g" \
      -e "s|{{CF_ACCESS_TEAM_DOMAIN}}|$CF_ACCESS_TEAM_DOMAIN|g" \
      -e "s|{{CF_ACCESS_AUD}}|${1:-}|g" \
      -e "s|{{DASHBOARD_HOSTNAME}}|$DASHBOARD_HOSTNAME|g" \
      "$TPL/wrangler.toml.tmpl" > "$SCRIPT_DIR/wrangler.toml"
}

# ============================================================================
step "3. Install dependencies (jose, wrangler)"
( cd "$SCRIPT_DIR" && npm install --no-fund --no-audit >/dev/null 2>&1 ) || die "npm install failed"
c_grn "  ✓ deps installed"

export CLOUDFLARE_API_TOKEN="$DEPLOY_TOKEN"
export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"

# ============================================================================
step "4. Deploy Worker FAIL-CLOSED + bind $DASHBOARD_HOSTNAME"
render_wrangler ""   # AUD empty → 503 to everyone; brain stays unreachable
( cd "$SCRIPT_DIR" && npx --yes wrangler deploy ) || die "wrangler deploy failed — token likely missing a scope: needs Account>Workers Scripts:Edit AND Zone>Workers Routes:Edit (+ DNS:Edit) on your zone"

# ============================================================================
step "5. Set brain API key as a Worker secret (value never printed)"
printf %s "$(cat "$BRAIN_KEY_FILE")" | ( cd "$SCRIPT_DIR" && npx --yes wrangler secret put MCP_API_KEY ) >/dev/null
c_grn "  ✓ MCP_API_KEY secret set"

# ============================================================================
step "6. Verify FAIL-CLOSED (no gate yet → expect 503)"
code=""; for _ in $(seq 1 12); do
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$DASHBOARD_HOSTNAME/api/health" || true)
  [ "$code" = "503" ] && break; sleep 3
done
echo "  https://$DASHBOARD_HOSTNAME/api/health → ${code:-?} (expect 503; cert may take a moment)"

# ============================================================================
step "7. Create email-OTP Access gate (no Google, ever)"
AUD="$(CF_ACCOUNT_ID="$CF_ACCOUNT_ID" CF_API_TOKEN="$REST_TOKEN" \
  python3 "$SCRIPT_DIR/scripts/setup_access.py" \
  --hostname "$DASHBOARD_HOSTNAME" --email "$ACCESS_EMAIL" --otp-idp "$OTP_IDP_ID" \
  | sed -n 's/^AUD=//p')"
[ -n "$AUD" ] || die "Access app creation failed (token needs Access: Apps and Policies: Edit)"
c_grn "  ✓ Access app created — One-time PIN only, allow = $ACCESS_EMAIL"

# ============================================================================
step "8. Wire the gate into the Worker + redeploy"
render_wrangler "$AUD"
( cd "$SCRIPT_DIR" && npx --yes wrangler deploy ) || die "redeploy failed"

# ============================================================================
step "9. Verify the gate is LIVE (no login → expect 302 to email-code page)"
code=""; for _ in $(seq 1 12); do
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$DASHBOARD_HOSTNAME/" || true)
  [ "$code" = "302" ] && break; sleep 3
done
echo "  https://$DASHBOARD_HOSTNAME/ (no login) → ${code:-?} (expect 302)"

cat <<EOF

$(c_grn "DASHBOARD INSTALL COMPLETE")

  Open:   https://$DASHBOARD_HOSTNAME
  Log in: email a one-time code to  $ACCESS_EMAIL  (no Google, no password)
  Expect: your memories load with NO API-key prompt.

  If a 'Sign in with Google' button ever appears, something is misconfigured —
  re-run this installer; it pins the app to One-time PIN only.

  Uninstall: delete the '$WORKER_NAME' Worker and the Access app for
  $DASHBOARD_HOSTNAME in your Cloudflare dashboard. Your brain is unaffected.
EOF
