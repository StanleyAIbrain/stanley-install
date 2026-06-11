# Reliability bundle — keep your brain alive unattended

Three small pieces, all on **your own** machine and accounts. They never connect to
anyone else's system.

| Piece | What it does | Where it runs |
|---|---|---|
| `brain-watchdog.sh` | Every minute, checks the local health URL. If down, `launchctl kickstart`s the service and texts you **once** ("was down at HH:MM, restarted, back up"). Silent otherwise. | your crontab |
| `brain-restart.sh` | The one safe way to stop/start/restart. `start`/`restart` never exit 0 without a verified local 200; failure alerts you. | by hand |
| `liveness-worker/` | A Cloudflare Worker TEMPLATE you deploy to **your** account, pointed at **your** public health URL, with **your** Telegram secrets. Escalates only if the brain is down ≥4 min and the watchdog hasn't recovered it (e.g. the machine is off). | your Cloudflare |

## Why this exists
On some Macs launchd is degraded: KeepAlive / `launchctl load` do **not** reliably
respawn the service after a crash or a `launchctl unload`. Only `launchctl kickstart`
brings it back. Cron ticks independently of launchd, so the watchdog (cron + kickstart)
is the dependable recovery path. The Worker is off-box defense-in-depth for the case
where the whole machine is down.

## Setup (summary — see RUNBOOK-v1.4.md "Reliability / self-heal" for the gated steps)
1. Create a Telegram credentials file, `chmod 600`:
   ```
   mkdir -p ~/.config/brain
   printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' '<your-bot-token>' '<your-chat-id>' > ~/.config/brain/telegram.env
   chmod 600 ~/.config/brain/telegram.env
   ```
2. Copy `brain-watchdog.sh` + `brain-restart.sh` somewhere stable (e.g. `~/bin/`), `chmod +x`.
3. Add the watchdog to crontab: `* * * * * /bin/bash $HOME/bin/brain-watchdog.sh`
4. (Optional, recommended) Deploy the liveness Worker to your Cloudflare — see its `wrangler.toml`.

## Security notes
- The Telegram token is read from your creds file and passed to `curl` via a `-K`
  config fd (process substitution) — it never appears in `ps` output or on a command
  line. Keep the creds file `chmod 600`.
- The Worker reads its token/chat from Wrangler **secrets**, never from the repo.
- Defaults assume the stock install (label `com.stanleyai.memory-server`, port 8765);
  override via the `WD_*` / `BR_*` env vars at the top of each script if yours differ.
