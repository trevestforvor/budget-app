# Installing the server

The server holds the ledger, syncs the banks, runs the assistant and serves the dashboard. It runs on a Mac that stays on (a Mac mini, say), in Docker on any machine (a Linux box, a NAS, or a Mac with Docker), or as an app on an Olares box. The numbered steps below are the Mac way; [Where it runs](#where-it-runs) covers the other two.

When you're done you'll have:
- the **API** on `127.0.0.1:8080`, which the phone reaches over HTTPS with a bearer token;
- the **dashboard** on `127.0.0.1:8081`, for linking banks, imports, review and settings. **It has no login**, so it's only ever reached from this Mac or through an SSH tunnel;
- a nightly database backup.

## The short way

```sh
./setup.sh tools      # what the server and the app need (on a Mac: Homebrew, xcodegen, postgresql@16)
./setup.sh server     # asks where it runs (mac, docker or olares), then builds, installs, starts, checks /health
./setup.sh address    # asks how the phone reaches it (tailscale, caddy, cloudflare or url), sets it up, checks it (step 5)
./setup.sh check      # what's installed and answering, at any time
```

Both questions can be answered up front: `./setup.sh server docker`, `./setup.sh address caddy`. Each step checks first and skips what's done, so you can run it again. Then [link your banks](#6-link-banks) in the dashboard. The sections below are what those steps do, in case you'd rather do it by hand or something goes wrong.

## Where it runs

| | `./setup.sh server …` | Good for | Backups |
|---|---|---|---|
| **This Mac** | `mac` | A Mac that stays on. Steps 1–4 below | Nightly, in `~/Library/Application Support/BudgetServer/backups` |
| **Docker** | `docker` | A Linux box, a NAS, or a Mac with Docker Desktop or OrbStack. No Xcode or macOS 26 needed for the server | Daily, in `deploy/docker/backups` |
| **Olares** | `olares` | An Olares box that already has the `budgetapi` app | Before every deploy, on the box |

**Docker** (`deploy/docker/`) runs three containers with Compose: the server, built from this checkout, Postgres 16 (data in the `budget_db` volume, on a network with no way out), and a backup that dumps the ledger daily and keeps 14. `./setup.sh server docker`:
1. writes `deploy/docker/budget.env` (mode 600, never committed) with a new `BUDGET_API_TOKEN`, `BUDGET_TOKEN_KEY` and Postgres password, and this machine's time zone;
2. builds and starts it (`docker compose up -d --build`; the first build takes several minutes), and waits until `/health` answers.

It publishes the API on `127.0.0.1:8080` and the dashboard on `127.0.0.1:8081`, on this machine only, like the Mac install. Running it again rebuilds from the checkout, after backing up. **Save `BUDGET_TOKEN_KEY`** from `budget.env`, as in [step 3](#3-install).

| | |
|---|---|
| Logs | `docker compose -f deploy/docker/compose.yaml logs -f server` |
| Change a setting | Edit `deploy/docker/budget.env`, then `docker compose -f deploy/docker/compose.yaml up -d` |
| Back up now | `docker compose -f deploy/docker/compose.yaml run --rm backup once` |
| Restore | `docker compose -f deploy/docker/compose.yaml stop server`, then `docker compose -f deploy/docker/compose.yaml exec -T db pg_restore --clean --if-exists -U budget -d budget < deploy/docker/backups/budget-<date>.dump`, then `start server` |
| Stop | `docker compose -f deploy/docker/compose.yaml down`. The data stays in the volume; `down -v` deletes it |

**Olares**: the `budgetapi` app is installed from your own Market repo; the chart isn't in this repo ([SERVER.md → Deploy](SERVER.md#deploy)). `./setup.sh server olares` runs `deploy/olares/budgetapi/deploy.sh`, which builds this checkout on the box, backs up the ledger, installs it and restarts the app. It needs `OLARES_SSH` and `APP_NS` in `deploy/olares/budgetapi/deploy.env`. The app's API entrance is the phone's address, so step 5 is already done; its settings are in the Olares app.

## 1. Prerequisites

- **macOS 26 or later** (`sw_vers -productVersion`). The server package won't build on older systems.
- **Xcode 26 or later**, from the [App Store](https://apps.apple.com/app/xcode/id497799835). Open it once, then:
  ```sh
  sudo xcode-select -s /Applications/Xcode.app
  sudo xcodebuild -license accept
  ```
- **[Homebrew](https://brew.sh)**, then `brew install xcodegen postgresql@16`.

## 2. Postgres

```sh
brew services start postgresql@16     # now and at every login, on 127.0.0.1:5432
```

Homebrew's Postgres trusts local connections, so there's no password to set. The installer creates the `budget` role and database. Any Postgres 16 works instead: put its `POSTGRES_*` values in `budget.env` and create the role and database yourself.

## 3. Install

```sh
deploy/macos/install.sh
```

This does the following:
1. builds the release binary from this checkout;
2. installs it in `~/Library/Application Support/BudgetServer/`;
3. writes `budget.env` there (mode 600, once, never overwritten), with a new `BUDGET_API_TOKEN` and `BUDGET_TOKEN_KEY` and this Mac's time zone;
4. creates the database;
5. installs two LaunchAgents: `local.budget.server` (always on) and `local.budget.backup` (a `pg_dump` at 3:30 every night that keeps 14 copies);
6. waits until `/health` answers.

When a server is already installed, it backs up the database before replacing the server, and stops if that backup fails.

**Save `BUDGET_TOKEN_KEY` now.** Open `budget.env` and copy that key into a password manager. Bank connections are sealed with it, so a backup without the key means linking every bank again.

**Keep the Mac awake.** LaunchAgents run while you're logged in.
- **Sleep:** turn on System Settings → Energy → "Prevent automatic sleeping when the display is off", or run `sudo pmset -a sleep 0`.
- **Login:** on a Mac without a screen, also turn on automatic login (System Settings → Users & Groups).

`./setup.sh server` warns you if either is off.

## 4. Open the dashboard

- **On the server Mac:** http://budget.localhost:8081
- **From another computer:** turn on Remote Login on the server Mac (System Settings → General → Sharing). Then run `ssh -L 8081:127.0.0.1:8081 <server-mac>` and open http://budget.localhost:8081 on that computer.

Never forward port 8081 any other way.

## 5. Give the phone an HTTPS address

The server listens only on this machine (`127.0.0.1`), and the app talks to it over HTTPS. So the phone needs an address that terminates HTTPS and forwards to `127.0.0.1:8080`, and to nothing else. The dashboard on 8081 has no login. `./setup.sh address` asks which way, sets it up, saves the address as `BUDGET_PUBLIC_URL` (the dashboard shows it under "Connect your phone") and checks it:

| `./setup.sh address …` | Who can reach it | You need | What the script does |
|---|---|---|---|
| `tailscale` | Only your own devices: nothing is open to the internet | [Tailscale](https://tailscale.com/download) on this machine and the phone, signed in to one account, with HTTPS certificates on ([DNS settings](https://login.tailscale.com/admin/dns)) | `tailscale serve --bg 8080`, which gives `https://<machine>.<tailnet>.ts.net` and stays on. It never installs Tailscale |
| `caddy` | Anyone with the address; the token is the lock | A domain, a DNS record pointing at your home's public IP, and your router forwarding ports 80 and 443 to this machine | Writes a Caddyfile that forwards only to the API; runs Caddy as the launchd job `local.budget.caddy` (Mac) or the `caddy` container (Docker). Caddy gets the certificate from Let's Encrypt |
| `cloudflare` | Anyone with the address; the token is the lock | A domain on Cloudflare (the free plan works). No open ports | On a Mac: signs `cloudflared` in (once, in the browser), creates the tunnel `budget`, adds the DNS record, and runs it as the launchd job `local.budget.tunnel`, with one ingress rule to the API |
| `url` | Up to you | An address you already run (another proxy, VPN or tunnel) | Saves it and checks it |

Which one:
- **Tailscale** is the smallest exposure. The phone needs the VPN connected to sync. The morning push still arrives without it, because it comes from Apple.
- **Caddy** needs a public IP at home. Some internet providers, and most cellular ones, put customers behind a shared address (CGNAT), and then no port forward works.
- **Cloudflare** works behind CGNAT, but Cloudflare sees the traffic, because it terminates HTTPS.

For an agent: `BUDGET_ADDRESS=caddy BUDGET_DOMAIN=budget.example.com ./setup.sh address`, or `BUDGET_PUBLIC_URL=https://… ./setup.sh address`. Caddy also takes `BUDGET_ACME_EMAIL`, for Let's Encrypt's expiry notices.

**Check from outside:** with Wi-Fi off, open `https://<address>/health` in the phone's Safari. It should say `"status":"ok"`.

## 6. Link banks

On the dashboard, go to Accounts → **Connect a bank**. Choose either; you can add the other later. The dashboard shows the same comparison above its two tabs.

| | **Plaid** | **SimpleFIN** |
|---|---|---|
| Cost | Your own Plaid account. Free Trial: 10 bank logins for the life of the account (removing one doesn't free it). Paid plans bill per bank | $15 a year (or $1.50 a month) to SimpleFIN, up to 25 banks |
| Setup | Developer sign-up, keys, an identity check. OAuth banks need an https return address; approval can take days | Sign up, add banks on their site, paste one token |
| Card bills (statement, minimum, due date) | Yes | No |
| Merchant names and bank categories | Yes | Raw bank descriptions |
| History | Up to 2 years at link | About 90 days per request; Budget walks back further where the bank allows |
| Freshness | Several times a day | About once a day |
| Investments | Holdings by position | Balances only |

- **Plaid.** Use your own [Plaid account](https://dashboard.plaid.com) and enter its client ID and secret on the dashboard.
  - Start in Sandbox, which is free and uses made-up data.
  - Then request the free Trial plan for real banks. It allows 10 bank logins for the life of the account, and removing one doesn't free its slot.
  - OAuth banks (Chase and others) also need an `https://` redirect URI: [SERVER.md → Plaid step by step](SERVER.md#plaid-step-by-step).
- **SimpleFIN.** Sign up at [SimpleFIN Bridge](https://beta-bridge.simplefin.org), add your banks there (check yours at https://beta-bridge.simplefin.org/search-institutions), then create a setup token and paste it in. The dashboard lists each bank behind the token, and a bank that wants you to sign in again is fixed on SimpleFIN Bridge, then retried from the dashboard or the phone. SimpleFIN gives no warning before that happens; the first failed sync is the signal. Removing the link on the dashboard deletes the server's access; remove the app at SimpleFIN Bridge too, to stop the sharing there.
- **Statements.** CSV or OFX/QFX files go in under Imports, to fill in history from before a link's reach. Each import can be undone.

Linked accounts sync every 6 hours (`BUDGET_SYNC_INTERVAL_HOURS`), and **Sync now** pulls right away.

## 7. AI (optional)

Every AI piece is optional. Without a model:
- Ask gives built-in answers computed from the ledger;
- anything rules and merchant memory can't file waits in Review.

To add one, go to the dashboard → Settings → Models:
1. **Add** a model. It's saved right away.
2. Pick the one to use for each job.
3. **Save** at the bottom of the page.
4. **Test** checks each model with a made-up question, nothing from your ledger.

The two jobs:
- **Ask (chat)**, which also writes the morning summary. Any OpenAI-compatible address, its key and the model id: OpenAI, OpenRouter, LiteLLM, or a model you host.
- **Categorizing** is off by default. It can be Jev, through your OpenRouter key; Jev sees only the merchant name and the category list. It can also be a self-hosted decision server that serves `/v1/systemone`.

A bank transaction goes to a model only when one is configured for it. In the app, Settings → Decision model → "What the decision model sees" shows the exact request.

## 8. Morning summary (optional)

A daily push with yesterday's spending. It needs a paid Apple Developer membership.
1. Create an APNs key (a `.p8` file) at https://developer.apple.com/account/resources/authkeys/list.
2. On the dashboard → Settings → Notifications, enter:
   - the key's text and its Key ID;
   - your team ID;
   - the app's bundle ID, `<your prefix>.budget`. `./setup.sh app` prints it.
3. Turn it on in the app's Settings.

## Running it

| | |
|---|---|
| Is everything up? | `./setup.sh check` |
| Logs | `tail -f ~/Library/Application\ Support/BudgetServer/logs/server.log` (and `backup.log`) |
| Change a setting | Most are on the dashboard, and apply without a restart. For `budget.env`: edit it, then `launchctl kickstart -k gui/$(id -u)/local.budget.server`. Every variable: [SERVER.md → Configuration](SERVER.md#configuration) |
| Update | `git pull`, then `./setup.sh server` (it backs up first) |
| Back up now | `~/Library/Application\ Support/BudgetServer/backup.sh` |
| Remove | `deploy/macos/install.sh --uninstall` stops the server, the nightly backups, and Caddy or the tunnel if `./setup.sh address` set one up. Your data, `budget.env` and the backups stay |

**Restoring a backup.** Keep the `BUDGET_TOKEN_KEY` that was in use when the dump was taken.

```sh
cd ~/Library/Application\ Support/BudgetServer
launchctl bootout gui/$(id -u)/local.budget.server
pg_restore --clean --if-exists -h 127.0.0.1 -U budget -d budget backups/budget-<date>.dump
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.budget.server.plist
```

Try it once on a scratch database before you need it:
1. `createdb -h 127.0.0.1 -O budget scratch`
2. restore into `-d scratch`
3. `dropdb -h 127.0.0.1 scratch`

## Troubleshooting

| What you see | What to do |
|---|---|
| `install.sh` stops at "Postgres isn't answering" | `brew services start postgresql@16`. If it still won't start, check `brew services info postgresql@16` |
| "The backup failed, so the server wasn't replaced" | Postgres is down, or the disk is full. Fix that and run it again. The old server is still running |
| `/health` doesn't answer after install | The end of `logs/server.log` says why. Usually it's Postgres, or another program on port 8080 (`lsof -i :8080`). To use other ports, change `PORT` or `DASHBOARD_PORT` in `budget.env` |
| The phone says it can't reach the server | Open `https://<address>/health` in the phone's Safari. If that fails, check whatever provides the address (VPN, tunnel or proxy). If it works, check the token in the app |
| Caddy's address never answers | Caddy couldn't get a certificate: the end of `logs/caddy.log` (or `docker compose … logs caddy`) says why. Usually the DNS record or the port forward. From outside your network, `http://<domain>` should reach this machine |
| The tunnel's address never answers | The end of `logs/tunnel.log`. `cloudflared tunnel info budget` shows whether it's connected |
| The phone's requests are turned away (401) | The token doesn't match. Copy it again from the dashboard → Settings → Connect your phone → Show |
| Linking a bank says it's disabled | `BUDGET_TOKEN_KEY` is empty in `budget.env` |
| It stops overnight | The Mac slept or logged out. See [step 3](#3-install) |
| Building fails with a Swift error | Use Xcode 26 or later as the active toolchain: `xcode-select -p`, `swift --version` |
