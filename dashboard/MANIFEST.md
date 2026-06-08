# dashboard/ module — MANIFEST (staged, not pushed)

**What:** an additive, email-OTP-gated, key-injecting dashboard proxy for an
already-installed `mcp-memory-service` brain. Templatized 1:1 from a proven live
reference implementation. **Zero values from any specific deployment are baked in.**

## What ships
| File | Purpose |
|---|---|
| `install-dashboard.sh` | One-run **idempotent** installer: scope preflight (names a missing token scope, fails fast), **auto-detects key-gated vs anonymous brain** (probes a data endpoint), discovers CF account/zone/team/OTP-IdP, renders config, deploys, sets the key secret **only if key-gated**, creates/normalizes the OTP-only Access gate, wires the AUD, waits for the custom-domain cert (success-with-wait, never a false failure). |
| `src/index.js` | The Worker. Fully env-driven (no hard-coded hostnames/keys). Validates the Cloudflare Access JWT; injects the brain `X-API-Key` server-side (incl. SSE) **when configured**, or proxies **keyless** for an anonymous brain; never returns the key to the browser; pre-seeds `localStorage` to suppress the SPA key-modal. |
| `templates/wrangler.toml.tmpl` | `{{...}}` template rendered per-owner by the installer. `workers_dev=false` (no bypass URL). |
| `scripts/setup_access.py` | Creates **or normalizes** the Access app **One-time-PIN-only** (`allowed_idps=[otp]`, `auto_redirect=true`) + a single owner-email allow policy; a **post-condition guard** re-asserts OTP-only (self-heals drift); prints the AUD. Idempotent. |
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
- **Auto-detects brain auth mode:** probes the brain's data endpoint — key-gated → injects the
  key; anonymous → proxies keyless. Never assumes.
- **Token-scope preflight:** validates all five required scopes before deploying, names the exact
  missing one, and refuses to deploy half-configured. The `SKIP_SCOPE_PREFLIGHT=1` escape hatch is
  advanced/CI-only and **OFF by default**.

## Validation (sandbox install from this repo — hardening)
Ran `./install-dashboard.sh` **from this module** against two throwaway, storage-isolated test
brains (fresh empty DBs on spare ports, disposable quick tunnels) deploying to a disposable
sandbox subdomain / Worker / email — never any production brain. All artifacts torn down after.

| Fix / criterion | Result |
|---|---|
| Auth-mode auto-detect — KEY-GATED | **PASS** — detected `keyed`, `MCP_API_KEY` secret set |
| Auth-mode auto-detect — ANONYMOUS | **PASS** — detected `anon`, secret removed → deploys **keyless** (0 secrets) |
| Token-scope preflight | **PASS** — an under-scoped token was rejected, naming Workers Scripts/Routes/DNS; **nothing deployed** |
| Cert-readiness wait | **PASS** — "deployed; cert still issuing" reported as success-with-wait, not failure |
| OTP-only + post-create guard | **PASS** — `allowed_idps==[onetimepin]`, Google absent, `auto_redirect=true` |
| Idempotent re-run | **PASS** — two runs (keyed→anon) on one hostname converged to **one** app, no duplicate |
| Worker deploys from template | **PASS** |
| Proxy returns data through the gated Worker | **Composed proof** (owner-accepted) — `src/index.js` is byte-identical to the live reference Worker that returns data through a real OTP login; the conditional-injection branch is proven by the secret being present (keyed) vs absent (anon); both test brains return their seeded memories directly (keyed-with-key, anon-keyless). The literal request through the throwaway gate was bounded only by custom-domain TLS cert-issuance latency (environmental). |

Production brain + dashboard verified untouched after every run.

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

## Release
Ships as the `dashboard/` module of `StanleyAIbrain/stanley-install` (public). v1 landed in
commit `7e1b875`; this hardening update (auto-detect auth mode, scope preflight, cert wait,
idempotent, OTP guard) follows on `main` after a clean sandbox pass + owner go.
