#!/bin/bash
# ===========================================================================
# install-dashboard.sh — put an email-OTP-gated dashboard in front of your
# already-installed brain (mcp-memory-service).
#
# Result: https://dashboard.<your-domain> → Cloudflare Access (email One-time
# PIN) → a key-injecting Worker → your brain. You log in by email.
#
# AUTH MODE IS AUTO-DETECTED:
#   * key-gated brain  → the brain key is injected server-side (never seen by the browser)
#   * anonymous brain  → the proxy forwards without a key
#
# Pure ADDITION in front of your brain. Does not touch the brain, tunnel, or
# launchd jobs. Safe to re-run — it converges in place (idempotent).
#
# REQUIRED (env, else prompted):
#   BASE_DOMAIN     your Cloudflare domain  (derives dashboard.<d> + brain.<d>)
#   ACCESS_EMAIL    the email allowed to log in (your own)
#   CF_API_TOKEN    a Cloudflare API token with ALL FIVE of:
#                     Account > Workers Scripts            : Edit
#                     Account > Access: Apps and Policies  : Edit
#                     Zone    > Workers Routes             : Edit   (binds the custom domain)
#                     Zone    > DNS                        : Edit
#                     Zone    > Zone                       : Read
#                   (Cloudflare's "Edit Cloudflare Workers" template covers the two
#                    Workers scopes; just add Access: Apps and Policies + DNS.)
#
# OPTIONAL:
#   DASHBOARD_HOSTNAME default dashboard.$BASE_DOMAIN
#   BRAIN_HOSTNAME     default brain.$BASE_DOMAIN   (the Worker's upstream)
#   WORKER_NAME        default dashboard-proxy
#   BRAIN_KEY_FILE     default $HOME/stanley-ai/memory-server-api-key.txt
#   CERT_WAIT_SECONDS  default 300  (max wait for the custom-domain cert)
#   CF_ACCOUNT_ID / ZONE_ID / CF_ACCESS_TEAM_DOMAIN / OTP_IDP_ID  pre-set to skip discovery
#   DASHBOARD_DEPLOY_TOKEN / DASHBOARD_REST_TOKEN  per-phase token override (testing/split tokens)
#   SKIP_SCOPE_PREFLIGHT=1  skip the step-3 scope check (advanced/CI; you've pre-validated)
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

BASE_DOMAIN="${BASE_DOMAIN:-}"
ACCESS_EMAIL="${ACCESS_EMAIL:-}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
WORKER_NAME="${WORKER_NAME:-dashboard-proxy}"
BRAIN_KEY_FILE="${BRAIN_KEY_FILE:-$HOME/stanley-ai/memory-server-api-key.txt}"
CERT_WAIT_SECONDS="${CERT_WAIT_SECONDS:-300}"

# ============================================================================
step "1. Preflight (tools)"
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

cf_get(){ curl -s -H "Authorization: Bearer $REST_TOKEN" "$API$1"; }
cf_code(){ curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $REST_TOKEN" "$API$1"; }

# ============================================================================
step "2. Discover account / zone / Access team / One-time-PIN IdP"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-$(cf_get /accounts | python3 -c 'import sys,json;print(((json.load(sys.stdin).get("result") or [{}])[0]).get("id",""))')}"
[ -n "$CF_ACCOUNT_ID" ] || die "could not resolve account id (token missing Account read?)"
ZONE_ID="${ZONE_ID:-$(cf_get "/zones?name=$BASE_DOMAIN" | python3 -c 'import sys,json;print(((json.load(sys.stdin).get("result") or [{}])[0]).get("id",""))')}"
[ -n "$ZONE_ID" ] || die "could not find the zone for $BASE_DOMAIN in this Cloudflare account (token missing Zone:Read, or wrong domain)."
CF_ACCESS_TEAM_DOMAIN="${CF_ACCESS_TEAM_DOMAIN:-$(cf_get "/accounts/$CF_ACCOUNT_ID/access/organizations" | python3 -c 'import sys,json;print((json.load(sys.stdin).get("result") or {}).get("auth_domain",""))')}"
[ -n "$CF_ACCESS_TEAM_DOMAIN" ] || die "could not resolve the Access team domain — is Zero Trust set up on this account? (token missing Access read?)"
OTP_IDP_ID="${OTP_IDP_ID:-$(cf_get "/accounts/$CF_ACCOUNT_ID/access/identity_providers" | python3 -c 'import sys,json
ids=[p["id"] for p in (json.load(sys.stdin).get("result") or []) if p.get("type")=="onetimepin"]
print(ids[0] if ids else "")')}"
[ -n "$OTP_IDP_ID" ] || die "no One-time PIN identity provider in your Zero Trust org. Enable it under Zero Trust → Settings → Authentication, then re-run."
c_grn "  ✓ account=$CF_ACCOUNT_ID  zone=$ZONE_ID  team=$CF_ACCESS_TEAM_DOMAIN"

# ============================================================================
step "3. Token-scope preflight (fail fast; name the missing scope)"
if [ "${SKIP_SCOPE_PREFLIGHT:-0}" = "1" ]; then
  c_blu "  (skipped via SKIP_SCOPE_PREFLIGHT=1)"
else
  # Read-level capability probes (Cloudflare's Edit groups include Read). Catches a
  # scope that was omitted entirely — the common mistake.
  miss=""
  [ "$(cf_code "/accounts/$CF_ACCOUNT_ID/workers/scripts")" = "200" ] || miss="$miss\n   - Account > Workers Scripts : Edit"
  [ "$(cf_code "/accounts/$CF_ACCOUNT_ID/access/apps")"     = "200" ] || miss="$miss\n   - Account > Access: Apps and Policies : Edit"
  [ "$(cf_code "/zones/$ZONE_ID/workers/routes")"           = "200" ] || miss="$miss\n   - Zone > Workers Routes : Edit"
  [ "$(cf_code "/zones/$ZONE_ID/dns_records?per_page=1")"   = "200" ] || miss="$miss\n   - Zone > DNS : Edit"
  [ "$(cf_code "/zones/$ZONE_ID")"                          = "200" ] || miss="$miss\n   - Zone > Zone : Read"
  if [ -n "$miss" ]; then
    c_red "✗ Your Cloudflare token is missing permission(s):"; printf "$miss\n"
    die "re-create the token with all five permissions and re-run (never deploy half-configured)."
  fi
  c_grn "  ✓ token has all five required scopes"
fi

# ============================================================================
step "4. Detect brain auth mode (probe a DATA endpoint, not health)"
BRAIN_CODE="$(curl -s -o /dev/null -m 20 -w '%{http_code}' "https://$BRAIN_HOSTNAME/api/memories" || echo 000)"
case "$BRAIN_CODE" in
  401) AUTH_MODE="keyed"; c_grn "  ✓ brain is KEY-GATED (401 without a key)";;
  200) AUTH_MODE="anon";  c_grn "  ✓ brain is ANONYMOUS (200 without a key) — key injection skipped";;
  *)   die "couldn't reach your brain at https://$BRAIN_HOSTNAME (/api/memories → $BRAIN_CODE). Is it running and publicly reachable? Fix that, then re-run.";;
esac
if [ "$AUTH_MODE" = "keyed" ]; then
  [ -f "$BRAIN_KEY_FILE" ] || die "brain is key-gated but no key file at $BRAIN_KEY_FILE (set BRAIN_KEY_FILE=... to your brain's key file)."
fi

# ============================================================================
step "5. Install dependencies (jose, wrangler)"
( cd "$SCRIPT_DIR" && npm install --no-fund --no-audit >/dev/null 2>&1 ) || die "npm install failed"
c_grn "  ✓ deps installed"

render_wrangler(){  # $1 = AUD (may be empty)
  sed -e "s|{{WORKER_NAME}}|$WORKER_NAME|g" \
      -e "s|{{BRAIN_HOSTNAME}}|$BRAIN_HOSTNAME|g" \
      -e "s|{{CF_ACCESS_TEAM_DOMAIN}}|$CF_ACCESS_TEAM_DOMAIN|g" \
      -e "s|{{CF_ACCESS_AUD}}|${1:-}|g" \
      -e "s|{{DASHBOARD_HOSTNAME}}|$DASHBOARD_HOSTNAME|g" \
      "$TPL/wrangler.toml.tmpl" > "$SCRIPT_DIR/wrangler.toml"
}
export CLOUDFLARE_API_TOKEN="$DEPLOY_TOKEN"
export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"
wr(){ ( cd "$SCRIPT_DIR" && npx --yes wrangler "$@" ); }

# ============================================================================
step "6. Deploy Worker FAIL-CLOSED + bind $DASHBOARD_HOSTNAME (idempotent)"
render_wrangler ""   # AUD empty → 503 to everyone until the gate is wired
wr deploy || die "wrangler deploy failed — token likely missing Account>Workers Scripts:Edit or Zone>Workers Routes:Edit (+ DNS:Edit)"

# ============================================================================
step "7. Brain key as a Worker secret — only if key-gated"
if [ "$AUTH_MODE" = "keyed" ]; then
  printf %s "$(cat "$BRAIN_KEY_FILE")" | wr secret put MCP_API_KEY >/dev/null
  c_grn "  ✓ MCP_API_KEY secret set (value never printed)"
else
  # Anonymous: ensure no stale secret from a prior key-gated run (idempotency).
  printf 'y\n' | wr secret delete MCP_API_KEY >/dev/null 2>&1 || true
  c_grn "  ✓ anonymous brain — no key secret (proxy forwards keyless)"
fi

# ============================================================================
step "8. Verify FAIL-CLOSED (no gate yet → expect 503)"
code=""; for _ in $(seq 1 12); do
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$DASHBOARD_HOSTNAME/api/health" || true)
  [ "$code" = "503" ] && break; sleep 4
done
echo "  https://$DASHBOARD_HOSTNAME/api/health → ${code:-?} (expect 503; cert may still be issuing)"

# ============================================================================
step "9. Create/normalize the email-OTP Access gate (OTP-only; idempotent)"
AUD="$(CF_ACCOUNT_ID="$CF_ACCOUNT_ID" CF_API_TOKEN="$REST_TOKEN" \
  python3 "$SCRIPT_DIR/scripts/setup_access.py" \
  --hostname "$DASHBOARD_HOSTNAME" --email "$ACCESS_EMAIL" --otp-idp "$OTP_IDP_ID" \
  | sed -n 's/^AUD=//p')"
[ -n "$AUD" ] || die "Access app setup failed (token needs Access: Apps and Policies: Edit)"
c_grn "  ✓ Access app is One-time PIN only (Google absent), allow = $ACCESS_EMAIL"

# ============================================================================
step "10. Wire the gate into the Worker + redeploy"
render_wrangler "$AUD"
wr deploy || die "redeploy failed"

# ============================================================================
step "11. Wait for the custom-domain certificate (up to ${CERT_WAIT_SECONDS}s)"
ready=""; waited=0; delay=8
while [ "$waited" -lt "$CERT_WAIT_SECONDS" ]; do
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$DASHBOARD_HOSTNAME/" || true)
  if [ "$code" = "302" ]; then ready="yes"; break; fi
  sleep "$delay"; waited=$((waited + delay)); [ "$delay" -lt 24 ] && delay=$((delay + 4))
done

if [ -n "$ready" ]; then
  c_grn "DASHBOARD LIVE"
  echo "  https://$DASHBOARD_HOSTNAME → email-code login is enforcing (302 to Access)."
else
  c_blu "DASHBOARD DEPLOYED — certificate still issuing (not a failure)"
  echo "  The gate is wired; a brand-new custom-domain TLS cert can take a few minutes."
  echo "  Try the login at https://$DASHBOARD_HOSTNAME shortly."
fi

cat <<EOF

  Open:   https://$DASHBOARD_HOSTNAME
  Log in: a one-time code is emailed to  $ACCESS_EMAIL  (no Google, no password)
  Expect: your memories load with NO API-key prompt.   [brain auth mode: $AUTH_MODE]

  Uninstall: delete the '$WORKER_NAME' Worker and the Access app for
  $DASHBOARD_HOSTNAME in your Cloudflare dashboard. Your brain is unaffected.
EOF
