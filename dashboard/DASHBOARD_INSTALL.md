# DASHBOARD_INSTALL.md — Your Own Brain Dashboard, with Your Own Login

This gives you a web dashboard for your brain at `https://dashboard.<YOUR-DOMAIN>` — view,
search, and browse all your memories from any browser or your phone. You log in with a
one-time code emailed to you. No passwords, no API keys to handle, ever.

**Paste this whole file to your Claude Code and say:** *"Walk me through this one step at a
time. Do the terminal work for me. Stop and tell me clearly whenever I need to do something
myself. Don't skip ahead."*

---

## What you need before starting

- Your brain already installed and running (from your original install — `brain.<YOUR-DOMAIN>` works).
  **Works whether your brain is key-gated or anonymous — the installer detects which automatically.**
  (If key-gated, it reads the key from `~/stanley-ai/memory-server-api-key.txt`; if anonymous, it
  skips the key entirely.)
- Your Cloudflare account (the same one your brain's tunnel uses).
- Your domain on Cloudflare (the same one).
- **Zero Trust enabled** on that Cloudflare account with **One-time PIN** turned on
  (Zero Trust → Settings → Authentication → Login methods → One-time PIN). It's free.
- About 20 minutes.

---

## How it works (30 seconds)

A small Cloudflare Worker sits at `dashboard.<YOUR-DOMAIN>`. Cloudflare emails you a 6-digit
code when you visit — that's the login. Once you're in, the Worker talks to your brain *for*
you. If your brain uses an API key, the Worker holds it server-side and attaches it to every
request — you never see or paste it (and if your brain is anonymous, there's simply no key to
handle). Nobody without access to your email inbox can get in.

---

## STEP 1 — 👉 YOU: make a Cloudflare token

Your Claude needs permission to deploy the Worker and create the login gate.

👉 **YOU:** Go to https://dash.cloudflare.com/profile/api-tokens → **Create Token** → **Custom token**.
Give it exactly these permissions, then add your zone under "Zone Resources":

- **Account → Workers Scripts → Edit**
- **Account → Access: Apps and Policies → Edit**
- **Zone → Workers Routes → Edit** (your domain — this is what binds `dashboard.<YOUR-DOMAIN>` to the Worker)
- **Zone → DNS → Edit** (your domain)
- **Zone → Zone → Read** (your domain)

> Shortcut: Cloudflare's **"Edit Cloudflare Workers"** token template already bundles
> Workers Scripts:Edit + Zone Workers Routes:Edit. If you use it, just **add**
> Account → Access: Apps and Policies → Edit and Zone → DNS → Edit, scoped to your zone.

Copy the token and paste it to your Claude when it asks. Your Claude keeps it on your
machine for this run only — it never goes into chat history beyond that paste, and never
into any file that ships anywhere.

---

## STEP 2 — Run the installer (Claude does this)

Your Claude runs, from inside the `dashboard/` folder of the install repo:

```
./install-dashboard.sh
```

It will ask for your **domain** and the **email** you want to log in with, then do everything else:

1. Find your account, your Access team, and your One-time-PIN login method automatically.
2. Fill in the Worker template with your domain and your brain's hostname.
3. Set your brain's API key as a Worker **secret**, read straight from where your brain install
   saved it (`~/stanley-ai/memory-server-api-key.txt`) — you never touch it.
4. Deploy the Worker to `dashboard.<YOUR-DOMAIN>` (fail-closed at first — nobody can reach the
   brain until the gate exists).
5. Create the **email-One-time-PIN** Access gate — pinned to email-code login from the moment
   it's created, so a "Sign in with Google" button can never appear.
6. Wire the gate into the Worker and redeploy.
7. Check that, with no login, the page sends you to the email-code screen (not an error).

---

## STEP 3 — 👉 YOU: test it

👉 **YOU:** Open `https://dashboard.<YOUR-DOMAIN>` in a browser.

1. You should be asked for your **email** → enter it → check your inbox → enter the 6-digit code.
2. The dashboard loads and shows **your memories**. No API-key prompt should EVER appear.
3. Try it from your **phone** too — same flow.
4. **👉 YOU — confirm back to your Claude, in your words:** *"I logged in with the email code,
   I can see my memories, and it never asked me for an API key."*

> **This first login is the verification step — it is not assumed.** The dashboard is **not done**
> until you have logged in via the email code and confirmed your memories render. If anything
> fails, tell your Claude exactly what you saw and let it fix it before calling this complete.

If a key prompt appears or memories don't load, tell your Claude:
*"the dashboard loaded but the key injection isn't working"* — it will check the Worker secret
and the upstream brain hostname.

⚠️ If you EVER see a "Sign in with Google" button, something is misconfigured — tell your Claude
*"remove the Google login from the dashboard Access app, One-time PIN only."* (The installer
already pins it to OTP-only; re-running fixes it.)

---

## STEP 4 — Lock it in

👉 **YOU:** Tell your Claude: *"Store a memory that my dashboard is live at
dashboard.<YOUR-DOMAIN> with email-code login, tagged permanent."*

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Sign in with Google" appears | Re-run the installer (it pins the app to One-time PIN); or have Claude set `allowed_idps` to the OTP provider only. |
| 403 / blocked at login | Your email isn't on the allowlist — have Claude check the Access policy for `dashboard.<YOUR-DOMAIN>`. |
| Dashboard loads, then asks for an API key | Worker secret missing/wrong — have Claude re-run `wrangler secret put MCP_API_KEY`. |
| Memories don't load / errors | The Worker's upstream hostname is wrong — it should be your `brain.<YOUR-DOMAIN>`. |
| Page returns 503 to everyone | The gate's AUD isn't wired in — have Claude re-run the installer (steps 7–8). |
| Code email never arrives | Check spam; confirm the allowlist email is exactly yours; confirm One-time PIN is enabled in Zero Trust. |

---

*Your dashboard. Your login. Your brain. Nothing touches anyone else's infrastructure.*
