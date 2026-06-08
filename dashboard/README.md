# dashboard/ — email-OTP login + key-injecting proxy for your brain

An **additive** layer that puts a private, email-login web dashboard in front of an
already-installed [`mcp-memory-service`](https://github.com/doobidoo/mcp-memory-service) brain
(the "Everest" stack). It does **not** modify the brain, tunnel, or launchd jobs.

```
Human ─email OTP─▶ Cloudflare Access ─▶ dashboard-proxy Worker ─X-API-Key injected─▶ brain (unchanged)
                   (only human auth)     (validates Access JWT,
                                          injects the key incl. SSE,
                                          never returns it to the browser)
```

The dashboard UI itself is served by your brain (`mcp-memory-service`'s built-in dashboard,
app.js `v10.7.1-auth-fix`). This module ships **no** SPA assets — only the proxy Worker that
gates and authenticates access to it.

## What it does
- Human auth = **email One-time PIN** via Cloudflare Access (no passwords, no Google).
- Brain auth mode is **auto-detected**. If your brain is key-gated, its API key lives in a
  **Worker secret**, injected server-side on every request (incl. SSE), never sent to the browser.
  If your brain is anonymous, the proxy forwards keyless.
- Pre-seeds `localStorage` so the brain dashboard's SPA never shows its API-key modal — without
  exposing the real key.
- **Fail-closed:** until the Access gate is created, the Worker returns `503` and never contacts
  the brain. No public `*.workers.dev` URL exists, so the gate cannot be bypassed.

## Layout
```
install-dashboard.sh         one-run installer (discovers your CF account/team/OTP IdP, deploys, gates)
package.json                 Worker deps (jose for Access-JWT verification)
src/index.js                 the Worker (fully env-driven; no hard-coded values)
templates/wrangler.toml.tmpl {{...}} template rendered by the installer
scripts/setup_access.py      creates the OTP-only Access app + email policy, prints the AUD
DASHBOARD_INSTALL.md         paste-to-your-Claude install guide
```

## Install
You provide three things; the installer does the rest. See **DASHBOARD_INSTALL.md**.
```bash
cd dashboard
BASE_DOMAIN=yourdomain.com ACCESS_EMAIL=you@example.com CF_API_TOKEN=… ./install-dashboard.sh
```
Token scopes (your account/zone): Account→Workers Scripts:Edit, Account→Access: Apps and
Policies:Edit, Zone→Workers Routes:Edit (binds the custom domain), Zone→DNS:Edit, Zone→Zone:Read.
Tip: the "Edit Cloudflare Workers" template covers the two Workers scopes — just add Access and DNS.

## Uninstall
Delete the `dashboard-proxy` Worker and the Access app for `dashboard.<your-domain>` in your
Cloudflare dashboard. The brain is untouched.
