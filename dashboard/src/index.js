// dashboard-proxy — Phase 1 of the memory dashboard.
//
// Flow:  Human --email OTP--> Cloudflare Access --> this Worker --X-API-Key injected--> brain (unchanged)
//
// Responsibilities (and ONLY these):
//   1. FAIL-CLOSED. If not fully configured, or the request lacks a valid
//      Cloudflare Access JWT, return an error and NEVER touch the brain.
//   2. Validate the `Cf-Access-Jwt-Assertion` against the team's JWKS + AUD.
//   3. Reverse-proxy every path (incl. SSE) to the upstream brain, injecting the
//      real MCP_API_KEY server-side. The key is NEVER returned to the browser.
//   4. Pre-seed localStorage so the dashboard SPA doesn't demand a key from the
//      human (GHSA-73hc-m4hx-79pj: the SPA always shows the key modal otherwise).
//
// It touches no brain code. Removing this Worker + its DNS fully reverts Phase 1.

import { createRemoteJWKSet, jwtVerify } from 'jose';

// JWKS is cached per isolate by jose; we just memoize the set object.
let JWKS = null;
function jwks(teamDomain) {
  if (!JWKS) {
    JWKS = createRemoteJWKSet(new URL(`https://${teamDomain}/cdn-cgi/access/certs`));
  }
  return JWKS;
}

function deny(status, msg) {
  return new Response(`${msg}\n`, {
    status,
    headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
  });
}

function cookie(request, name) {
  const c = request.headers.get('Cookie');
  if (!c) return null;
  const m = c.match(new RegExp('(?:^|;\\s*)' + name + '=([^;]+)'));
  return m ? decodeURIComponent(m[1]) : null;
}

export default {
  async fetch(request, env) {
    const { CF_ACCESS_TEAM_DOMAIN, CF_ACCESS_AUD, UPSTREAM, MCP_API_KEY, ALLOWED_EMAILS } = env;

    // ---- (1) FAIL-CLOSED preconditions -------------------------------------
    // If any of these are missing the proxy must not reach the brain at all.
    if (!UPSTREAM || !MCP_API_KEY || !CF_ACCESS_TEAM_DOMAIN || !CF_ACCESS_AUD) {
      return deny(503, 'dashboard-proxy not configured (fail-closed)');
    }

    // ---- (2) Verify the Cloudflare Access JWT ------------------------------
    const token =
      request.headers.get('Cf-Access-Jwt-Assertion') || cookie(request, 'CF_Authorization');
    if (!token) return deny(403, 'Forbidden: no Cloudflare Access token');

    let claims;
    try {
      const { payload } = await jwtVerify(token, jwks(CF_ACCESS_TEAM_DOMAIN), {
        issuer: `https://${CF_ACCESS_TEAM_DOMAIN}`,
        audience: CF_ACCESS_AUD,
      });
      claims = payload;
    } catch {
      return deny(403, 'Forbidden: invalid Cloudflare Access token');
    }

    // Optional belt-and-suspenders email allowlist (Access policy is primary).
    const allow = (ALLOWED_EMAILS || '')
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean);
    if (allow.length && claims.email && !allow.includes(String(claims.email).toLowerCase())) {
      return deny(403, 'Forbidden: email not allowlisted');
    }

    // ---- (3) Reverse-proxy to the brain, injecting the key -----------------
    const url = new URL(request.url);
    const upstream = new URL(UPSTREAM);
    upstream.pathname = url.pathname;
    upstream.search = url.search;

    // EventSource (SSE) can't set request headers from the browser, and the SPA
    // uses ?api_key= for the stream — so inject the key in the query for SSE.
    const isSSE =
      url.pathname.startsWith('/api/events') ||
      (request.headers.get('accept') || '').includes('text/event-stream');
    if (isSSE) upstream.searchParams.set('api_key', MCP_API_KEY);

    const headers = new Headers(request.headers);
    // Strip anything the client supplied; the Worker is the sole source of auth.
    headers.delete('X-API-Key');
    headers.delete('Authorization');
    headers.delete('Cf-Access-Jwt-Assertion'); // no need to forward to the brain
    headers.delete('Host'); // let fetch derive Host/SNI from the upstream URL
    headers.set('X-API-Key', MCP_API_KEY);

    const init = {
      method: request.method,
      headers,
      redirect: 'manual',
    };
    if (!['GET', 'HEAD'].includes(request.method)) {
      init.body = request.body;
      init.duplex = 'half'; // stream request bodies (multipart uploads in Phase 2)
    }

    let resp = await fetch(upstream.toString(), init);

    // ---- (4) Suppress the SPA's key modal without exposing the key ---------
    // Pre-seed a PLACEHOLDER into localStorage. The SPA stops nagging for a key
    // and sends X-API-Key: access-gated, which this Worker discards and replaces
    // with the real key. The real key is never present client-side.
    const ct = resp.headers.get('content-type') || '';
    if (ct.includes('text/html')) {
      const seed =
        "<script>try{if(!localStorage.getItem('mcp_api_key'))" +
        "localStorage.setItem('mcp_api_key','access-gated');}catch(e){}</script>";
      resp = new HTMLRewriter()
        .on('head', {
          element(el) {
            el.prepend(seed, { html: true });
          },
        })
        .transform(resp);
    }

    return resp;
  },
};
