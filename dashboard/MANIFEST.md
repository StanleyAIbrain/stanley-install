# dashboard/ module — MANIFEST (staged, not pushed)

**What:** an additive, email-OTP-gated, key-injecting dashboard proxy for an
already-installed `mcp-memory-service` brain. Templatized 1:1 from a proven live
reference implementation. **Zero values from any specific deployment are baked in.**

## What ships
| File | Purpose |
|---|---|
| `install-dashboard.sh` | One-run installer: discovers the owner's CF account / Access team / One-time-PIN IdP from their own token, renders the Worker config, deploys, sets the brain key as a Worker secret, creates the OTP-only Access gate, wires the AUD, redeploys, verifies. |
| `src/index.js` | The Worker. Fully env-driven (no hard-coded hostnames/keys). Validates the Cloudflare Access JWT, injects the brain `X-API-Key` server-side (incl. SSE), never returns it to the browser, pre-seeds `localStorage` to suppress the SPA key-modal. |
| `templates/wrangler.toml.tmpl` | `{{...}}` template rendered per-owner by the installer. `workers_dev=false` (no bypass URL). |
| `scripts/setup_access.py` | Creates the Access app **One-time-PIN-only from birth** (`allowed_idps=[otp]`, `auto_redirect_to_identity=true`) + a single owner-email allow policy; prints the AUD. Idempotent. |
| `DASHBOARD_INSTALL.md` | Paste-to-your-Claude owner-facing install guide (👉 YOU markers). |
| `README.md` | Module overview + layout + uninstall. |

The dashboard UI itself is **not** in this module — it is served by the brain
(`mcp-memory-service`'s built-in dashboard, app.js `v10.7.1-auth-fix`). This module
ships only the gating/auth proxy in front of it.

## Security model
- Human auth = **email One-time PIN** only. **No Google IdP, ever** — the Access app is
  pinned to OTP at creation, eliminating the `org_internal`-Google 403 trap that locks out
  personal Gmail accounts.
- Brain API key lives in a **Worker secret**, injected server-side, never sent to the browser
  and never written to any file in this repo.
- **Fail-closed:** until the gate's AUD is wired in, the Worker returns `503` and never
  contacts the brain. No `*.workers.dev` URL exists, so the gate cannot be bypassed.

## Validation (sandbox install from this repo)
Ran `./install-dashboard.sh` **from this module** against a throwaway, isolated test brain
(fresh empty DB on a spare port, exposed via a disposable quick tunnel) deploying to a
disposable sandbox subdomain, Worker name, and test email — never against any production brain.

| Acceptance criterion | Result |
|---|---|
| Worker deploys from the template | **PASS** — deployed + custom domain bound from the rendered config |
| Brain key set as a Worker secret (never printed) | **PASS** |
| Access app creates **OTP-only** (no Google) | **PASS** — `allowed_idps=[onetimepin]`, Google absent, `auto_redirect=true` |
| Allow policy = single owner email | **PASS** |
| Fail-closed before the gate exists | **PASS** (verified `503` on the live reference; in sandbox the Worker deploys fail-closed by construction) |
| Non-allowlisted blocked at the edge | **PASS at config level** (only the owner email is in the policy); HTTP-`302` enforcement was not observed within the test window because the throwaway custom-domain TLS cert was still issuing |
| Allowlisted login → memories render, key injected | **NOT VERIFIED headlessly** — requires interactive email-OTP (no disposable inbox) + the cert. This exact path is proven on the live reference implementation, and `src/index.js` ships **byte-identical** to that proven Worker. |

All sandbox artifacts (Worker, custom domain, DNS, Access app, quick tunnel, test brain, temp
data) were **torn down** after the run, and the production brain + dashboard were verified
untouched.

## Zero-deployment-specific-values proof
Every shipped file in `dashboard/` was grepped for: a specific production domain, an Access
team subdomain, known Access app/policy/IdP IDs, a Cloudflare account ID, an API/brain key
value, and any bare 32-hex token. **All matches: zero.** `src/index.js` is fully env-driven;
the only owner-specific values exist transiently in the installer-rendered `wrangler.toml`
(`.gitignore`d, never committed).

## Not included (deliberately)
- No SPA/static assets (the brain serves its own dashboard).
- No production secrets, tokens, account IDs, hostnames, or Access app IDs.
- `node_modules/`, the rendered `wrangler.toml`, and `.wrangler/` are `.gitignore`d.

## Push target (when approved — NOT done)
Ships as the `dashboard/` module of `StanleyAIbrain/stanley-install`, bundled in the same
release as the in-flight brain-update RC. **No git remote operations performed.** Pre-push
gate: clean sandbox pass → reviewer approval → owner go → push.
