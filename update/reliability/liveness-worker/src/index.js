// brain-liveness — external ESCALATION alarm for your brain's public health URL.
//
// This is a TEMPLATE. You deploy it to YOUR OWN Cloudflare account, pointed at
// YOUR OWN brain hostname, with YOUR OWN Telegram bot token + chat id set as
// Wrangler secrets. It never contains anyone else's domain or secrets.
//
// Division of labor: the on-box watchdog (cron + kickstart) owns fast recovery
// and the only routine voice. This Worker speaks ONLY when the watchdog has
// clearly failed to save the brain — sustained down >= ESCALATE_AFTER_MS (~4 min),
// e.g. the whole machine is off. No recovery message, no "OK" noise, ever.
//
// Stateless (no KV needed): the Cache API holds downSince + suppression. Known
// limit: cache is per-colo; a colo switch can restart the down-clock and delay
// (never silence) escalation. Worst case it alerts late, not never.

const DOWN_SINCE = "https://brain-liveness.internal/down-since";
const ALERT_FLAG = "https://brain-liveness.internal/alert-flag";
const ESCALATE_AFTER_MS = 4 * 60 * 1000; // 4 min — the watchdog should save in ~2-3
const SUPPRESS_S = 1800;                  // re-escalate at most every 30 min

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function tgSend(env, text) {
  if (!env.TG_TOKEN || !env.TG_CHAT) {
    console.log("telegram secrets missing — set TG_TOKEN and TG_CHAT via `wrangler secret put`");
    return false;
  }
  try {
    const resp = await fetch(`https://api.telegram.org/bot${env.TG_TOKEN}/sendMessage`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: env.TG_CHAT, text }),
    });
    console.log(`telegram send: ${resp.status}`);
    return resp.ok;
  } catch (e) {
    console.log(`telegram send failed: ${e.message}`);
    return false;
  }
}

async function check(env) {
  try {
    const resp = await fetch(env.CHECK_URL, {
      redirect: "manual",
      headers: { "cache-control": "no-cache" },
      signal: AbortSignal.timeout(10000),
    });
    return resp.status;
  } catch (e) {
    return 0;
  }
}

export default {
  async scheduled(event, env, ctx) {
    const prefix = env.TEST_PREFIX || "";
    const cache = caches.default;

    const first = await check(env);
    if (first === 200) {
      // healthy: clear state SILENTLY (the watchdog owns the recovery voice)
      await cache.delete(DOWN_SINCE);
      await cache.delete(ALERT_FLAG);
      console.log("ok status=200");
      return;
    }

    await sleep(20000); // transient-blip filter
    const second = await check(env);
    if (second === 200) {
      console.log("recovered on recheck — blip, no action");
      return;
    }

    const now = Date.now();
    let downSince = now;
    const ds = await cache.match(DOWN_SINCE);
    if (ds) {
      downSince = parseInt(await ds.text(), 10) || now;
    } else {
      await cache.put(
        DOWN_SINCE,
        new Response(String(now), { headers: { "cache-control": "max-age=900" } })
      );
      console.log(`down status=${second} — clock started, no escalation yet`);
      return;
    }

    const downMs = now - downSince;
    if (downMs < ESCALATE_AFTER_MS) {
      console.log(`down status=${second} for ${Math.round(downMs / 1000)}s — below escalation threshold`);
      return;
    }

    const suppressed = await cache.match(ALERT_FLAG);
    if (suppressed) {
      console.log(`down ${Math.round(downMs / 1000)}s — escalation suppressed (30min)`);
      return;
    }

    const sent = await tgSend(
      env,
      `${prefix}🚨 ${env.BRAIN_NAME || "Brain"} has been down ${Math.round(downMs / 60000)}+ minutes and the watchdog hasn't saved it — the host machine may be off. Needs you.`
    );
    if (sent) {
      await cache.put(
        ALERT_FLAG,
        new Response("alerted", { headers: { "cache-control": `max-age=${SUPPRESS_S}` } })
      );
    }
    console.log(`ESCALATED downMs=${downMs} sent=${sent}`);
  },

  async fetch(request, env) {
    const status = await check(env);
    return new Response(
      JSON.stringify({ monitor: "brain-liveness", mode: "escalation-only (>=4min sustained down)", target: env.CHECK_URL, live_status: status, ok: status === 200 }, null, 2),
      { headers: { "content-type": "application/json" } }
    );
  },
};
