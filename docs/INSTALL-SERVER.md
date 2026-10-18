# Installing the server

The server holds the ledger, syncs the banks, runs the assistant and serves the dashboard. It runs on a Mac that stays on (a Mac mini, say), or in Docker on any machine (a Linux box, a NAS, or a Mac with Docker). The numbered steps below are the Mac way; [Where it runs](#where-it-runs) covers Docker. An Olares install exists too, for the owner only.

When you're done you'll have:
- the **API** on `127.0.0.1:8080`, which the phone reaches over HTTPS with a bearer token;
- the **dashboard** on `127.0.0.1:8081`, for linking banks, imports, review and settings. **It has no login**, so it's only ever reached from this machine or through an SSH tunnel;
- a nightly database backup.

## The short way

```sh
./setup.sh before     # what you paste into your own Terminal first: the steps that need your password or a browser
./setup.sh tools      # what the server and the app need (on a Mac: xcodegen, postgresql@16)
./setup.sh server     # asks where it runs (mac or docker), then builds, installs, starts, checks /health
./setup.sh address    # asks how the phone reaches it (tailscale, caddy, cloudflare or url), sets it up, checks it (step 5)
./setup.sh banks      # the steps to link your banks, filled in for this install (step 6)
./setup.sh check      # what's done, what's left, and the one next step, at any time
```

Both questions can be answered up front: `./setup.sh server docker`, `./setup.sh address caddy`. Each step checks first and skips what's done, so you can run it again. The sections below are what those steps do, in case you'd rather do it by hand or something goes wrong.

## Where it runs

| | `./setup.sh server …` | Good for | Backups |
|---|---|---|---|
| **This Mac** | `mac` | A Mac that stays on. Steps 1–4 below | Nightly, in `~/Library/Application Support/BudgetServer/backups` |
| **Docker** | `docker` | A Linux box, a NAS, or a Mac with Docker Desktop or OrbStack. No Xcode or macOS 26 needed for the server | Daily, in `deploy/docker/backups` |
| **Olares** | `olares` | The owner only: it updates a `budgetapi` app that's already installed, and that app's chart isn't in this repo | Before every deploy, on the box |

**Docker** (`deploy/docker/`) runs three containers with Compose: the server, built from this checkout, Postgres 16 (data in the `budget_db` volume, on a network with no way out), and a backup that dumps the ledger daily and keeps 14. `./setup.sh server docker`:
1. writes `deploy/docker/budget.env` (mode 600, never committed) with a new `BUDGET_API_TOKEN`, `BUDGET_TOKEN_KEY` and Postgres password, and this machine's time zone;
2. builds and starts it (`docker compose up -d --build`; the first build takes several minutes), and waits until `/health` answers.

It publishes the API on `127.0.0.1:8080` and the dashboard on `127.0.0.1:8081`, on this machine only, like the Mac install. Running it again rebuilds from the checkout, after backing up. **Keep a copy of `BUDGET_TOKEN_KEY`**, as in [step 3](#3-install).

On Linux, your user has to be in the `docker` group. Run `sudo usermod -aG docker $USER` in your own Terminal, then log out and back in. `./setup.sh before` prints this when it's missing.

| | |
|---|---|
| Logs | `docker compose -f deploy/docker/compose.yaml logs -f server` |
| Change a setting | `./setup.sh secret NAME` for a key (it restarts the server), or edit `deploy/docker/budget.env`, then `docker compose -f deploy/docker/compose.yaml up -d` |
| Back up now | `docker compose -f deploy/docker/compose.yaml run --rm backup once` |
| Restore | `docker compose -f deploy/docker/compose.yaml stop server`, then `docker compose -f deploy/docker/compose.yaml exec -T db pg_restore --clean --if-exists -U budget -d budget < deploy/docker/backups/budget-<date>.dump`, then `start server` |
| Stop | `docker compose -f deploy/docker/compose.yaml down`. The data stays in the volume; `down -v` deletes it |

**Olares (owner only).** The `budgetapi` app is installed from the owner's own Market repo; the chart isn't in this repo, so there's no way to start an Olares install from here ([SERVER.md → Deploy](SERVER.md#deploy)). `./setup.sh server olares` runs `deploy/olares/budgetapi/deploy.sh`, which builds this checkout on the box, backs up the ledger, installs it and restarts the app. It needs `OLARES_SSH` and `APP_NS` in `deploy/olares/budgetapi/deploy.env`, and refuses a checkout with uncommitted changes. Without a terminal, it also needs `BUDGET_DEPLOY=1` as well as `BUDGET_YES=1`, because it replaces the live server. The app's API entrance is the phone's address, so step 5 is mostly done; its settings are in the Olares app. Two things to check for Plaid's webhooks and signing in again from the phone:
- **The server URL is the API entrance.** Settings → "Server URL for the phone" (`BUDGET_PUBLIC_URL`) must be the public API entrance (`https://<appid>0.<you>.olares.com`), not the dashboard's (`<appid>1`).
- **The API entrance lets three paths through without the Olares login:** `POST /v1/plaid/webhook` (with its `Plaid-Verification` header), `GET /.well-known/apple-app-site-association` and `GET /plaid/oauth-return`. From outside, the first should answer 400 to an empty POST and the second 200 (404 until `BUDGET_IOS_APP_ID` is set), never the Olares login page ([SERVER.md → Olares and Plaid](SERVER.md#olares-and-plaid-server-060)).

## 1. Prerequisites

`./setup.sh before` prints whichever of these this machine still lacks. Paste its commands into your own Terminal: `sudo` asks for your password, which nothing else can type. Run without a terminal, `setup.sh` stops at these steps and prints the same block instead of waiting.

- **macOS 26 or later** (`sw_vers -productVersion`). The server package won't build on older systems.
- **Xcode 26 or later**, from the [App Store](https://apps.apple.com/app/xcode/id497799835). Open it once, then:
  ```sh
  sudo xcode-select -s /Applications/Xcode.app
  sudo xcodebuild -license accept
  ```
- **Signed in to Xcode**, for the app: Xcode → Settings → Accounts → + (bottom left) → Apple Account → Continue.
- **[Homebrew](https://brew.sh)**: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`. Then `./setup.sh tools` installs `xcodegen` and `postgresql@16`.

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

**Keep a copy of `BUDGET_TOKEN_KEY` now.** Bank connections are sealed with it, so a backup without the key means linking every bank again. `./setup.sh save-key` puts it in your login Keychain, as "Budget server token key", without showing it. `./setup.sh save-key --clipboard` puts it on the clipboard for a password manager instead. If you copied it from `budget.env` yourself, `./setup.sh save-key --done` records that. `./setup.sh check` reports whether a copy matches the current key.

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
| `cloudflare` | Anyone with the address; the token is the lock | A domain on Cloudflare (the free plan works). No open ports | On a Mac: creates the tunnel `budget`, adds the DNS record, and runs it as the launchd job `local.budget.tunnel`, with one ingress rule to the API |
| `url` | Up to you | An address you already run (another proxy, VPN or tunnel) | Saves it and checks it |

Which one:
- **Tailscale** is the smallest exposure. The phone needs the VPN connected to sync. The morning push still arrives without it, because it comes from Apple. **The tradeoff:** Plaid can't reach a Tailscale address, so there are no Plaid webhooks (the server pulls on its schedule instead) and no signing in to a bank again from the phone (you do that on the dashboard). SimpleFIN is the same either way.
- **Caddy** needs a public IP at home. Some internet providers, and most cellular ones, put customers behind a shared address (CGNAT), and then no port forward works.
- **Cloudflare** works behind CGNAT, but Cloudflare sees the traffic, because it terminates HTTPS. Sign `cloudflared` in first, in your own Terminal: `cloudflared tunnel login`, then pick the domain in the browser window it opens. Run without a terminal and without that login, `./setup.sh address cloudflare` stops and says so.

For an agent: `BUDGET_ADDRESS=caddy BUDGET_DOMAIN=budget.example.com ./setup.sh address`, or `BUDGET_PUBLIC_URL=https://… ./setup.sh address`. Caddy also takes `BUDGET_ACME_EMAIL`, for Let's Encrypt's expiry notices.

**Check from outside:** with Wi-Fi off, open `https://<address>/health` in the phone's Safari. It should say `"status":"ok"`.

**Plaid and this address.** `BUDGET_PUBLIC_URL` is also where Plaid sends its webhooks (`/v1/plaid/webhook`) and where a bank's app hands the phone back after signing in again (`/plaid/oauth-return`, opened as a Universal Link with `/.well-known/apple-app-site-association`). Those three paths carry no bearer token, so whatever serves the address must pass them to the API as they are. Caddy and the Cloudflare tunnel above forward everything on the API port, so they do. `./setup.sh check` probes all three: the Universal Link file should answer 200, an empty POST to the webhook 400, and `/plaid/oauth-return` 200.

## 6. Link banks

On the dashboard, go to Accounts → **Connect a bank**. Choose either; you can add the other later. The dashboard shows the same comparison above its two tabs, and `./setup.sh banks` prints it with the steps for both.

| | **Plaid** | **SimpleFIN** |
|---|---|---|
| Cost | Your own Plaid account. Free Trial: 10 bank logins for the life of the account (removing one doesn't free it). Paid plans bill per bank | $15 a year (or $1.50 a month) to SimpleFIN, up to 25 banks |
| Setup | Developer sign-up, a plan, keys | Sign up, add your banks on their site, paste one token |
| Card bills (statement, minimum, due date) | Yes, once you turn on Card bills (below) | No |
| Merchant names and bank categories | Yes | Raw bank descriptions |
| History | Up to 2 years at link | About 90 days per request; Budget walks back further where the bank allows |
| Freshness | Several times a day | About once a day |
| Investments | Holdings by position, once Investment holdings is on (Settings → Sync; Plaid then bills Investments) | Balances only |

### Plaid, step by step

`./setup.sh banks plaid` prints these steps with this install's addresses filled in.

1. **Sign up** at https://dashboard.plaid.com and verify your email. Sandbox, with made-up banks, works right away and is free.
2. **Pick a plan for your real banks** (the table below). For a new team that's the free Trial: https://dashboard.plaid.com/trial-plan, or the button on the Plaid Dashboard home.
3. **Real banks also need a Link use case**, for accounts made after October 31, 2024: Customize → Link at https://dashboard.plaid.com/link/data-transparency-v5.
4. **Copy the client ID and the secret** for your environment at https://dashboard.plaid.com/developers/keys. There's one client ID, and one secret each for Sandbox and Production.
5. **Enter them on the dashboard:** Accounts → Connect a bank → Plaid → Keys. Pick the environment, paste both, then **Save and test**, which asks Plaid for a link token to check them. Moving to real banks later means switching Environment to Production there and pasting the Production secret. On a Mac or Docker install the keys can go in `budget.env` instead, never shown: copy each value, then run `./setup.sh secret PLAID_CLIENT_ID`, `./setup.sh secret PLAID_SECRET` and `./setup.sh secret PLAID_ENV`. Keys saved on the dashboard win over `budget.env`.
6. **Leave the return address empty on a Mac or Docker install.** Banks that sign in on their own site (Chase, Schwab and others) open their sign-in in a pop-up there, with no return address. Only a dashboard with its own https address, like an Olares one, fills it in, and then that exact address goes under Allowed redirect URIs at https://dashboard.plaid.com/developers/api. If Plaid says it doesn't know a return address, add it there or clear the field.
7. **Turn on card bills:** dashboard → Settings → Sync → **Card bills (Plaid Liabilities)**. It's off until you do. Plaid then bills Liabilities for each bank login with a card. Each new link already asks for card-bill consent; a bank linked before shows **Grant card-bill access** on its card.
8. **Link a bank:** Accounts → Connect a bank → Plaid → **Link an account**. Plaid's window opens; sign in to the bank there.

| Plan | Who can get it | Cost | Banks | Where |
|---|---|---|---|---|
| **Trial** | New teams in the US or Canada, made on or after April 15, 2026 | Free | 10 bank logins, ever (removing one doesn't free it). Almost every bank, Chase included, with no company profile or security questionnaire until you upgrade | https://dashboard.plaid.com/trial-plan |
| **Limited Production** | Older teams only (Trial replaced it) | Free, with call and login caps | No Chase, Bank of America or Wells Fargo until full Production | https://dashboard.plaid.com/overview/limited-production |
| **Pay as you go** | Anyone, after Plaid approves | Per bank login, no minimum | All, once the steps below are done | https://dashboard.plaid.com/overview/request-products |
| **Growth, Custom** | Anyone, after Plaid approves | A minimum spend and an annual commitment | All | https://dashboard.plaid.com/settings/team/plans |

On a paid plan, banks that sign in on their own site need three more things in the Plaid Dashboard: the company profile (https://dashboard.plaid.com/settings/company/compliance?tab=companyProfile), the app profile (https://dashboard.plaid.com/settings/company/app-branding) and the security questionnaire (https://dashboard.plaid.com/settings/company/compliance?tab=dataSecurity), which Chase needs. Most banks follow within hours; Schwab can take up to 5 business days. Their status is at https://dashboard.plaid.com/settings/compliance/us-oauth-institutions.

More about Plaid on this server:
- **Investment holdings** follow Settings → Sync → Investment holdings (`BUDGET_PLAID_HOLDINGS`): `auto` (the default) only for bank logins Plaid already bills for Investments, `on` for every login with investments (Plaid may start billing Investments on the others), `off` for none.
- **One Plaid link per bank:** the dashboard and the server refuse a second one at a bank that already has a working link, because each is a separate (and on the Trial, irreversible) Item. Use Reconnect on the existing one.
- **Webhooks** need nothing set up at Plaid. With a public https address, new links get the webhook address, and the server moves older ones within a day. With Tailscale they're off, and the 6-hourly sync carries on.

### Signing in to a bank again from the phone

Optional, Plaid only. When a bank wants you to sign in again, the phone can do it in Plaid's Hosted Link instead of sending you to the dashboard. It needs all of these, in this order:

1. **A paid Apple Developer team.** A free Personal Team can't have Associated Domains.
2. **A public https address** for the API on port 443, with no path, that isn't Tailscale ([step 5](#5-give-the-phone-an-https-address)).
3. **Plaid on the server**, with `BUDGET_TOKEN_KEY` set.
4. **Hosted Link:** nothing to request. Plaid's API includes it for every account.
5. **`BUDGET_IOS_APP_ID` set before the app is installed**, as `<team ID>.<your prefix>.budget`, so the server serves the Universal Link file Apple fetches at install. `./setup.sh app` sets it, restarts the server and checks the file. On an Olares, set it in the `budgetapi` app's settings.
6. **The app built with `BUDGET_API_HOST`**, the API's host name. `./setup.sh app` writes it to `Config/Local.xcconfig` when steps 1, 2 and 5 hold, and automatic signing adds Associated Domains to your App ID ([INSTALL-APP.md](INSTALL-APP.md#after-its-connected)).
7. **The phone's return address at Plaid:** add `https://<your API address>/plaid/oauth-return`, exactly, under Allowed redirect URIs at https://dashboard.plaid.com/developers/api. `./setup.sh banks plaid` prints the exact address, and so does the dashboard's Plaid tab.

Then run `./setup.sh check`: `aasa`, `webhook`, `oauth_return` and `push_ids` should be done. Until something's missing is fixed, the phone's Reconnect gets a message that names it, and a bank that wants a sign-in is fixed on the dashboard.

### SimpleFIN, step by step

`./setup.sh banks simplefin` prints these steps too.

1. **Check your banks are covered** (US and Canada only): https://beta-bridge.simplefin.org/search-institutions.
2. **Sign up** at https://beta-bridge.simplefin.org/auth/login: enter your email, then **Send sign-in email**, and open the link it sends. The same form signs you in later.
3. **Subscribe** on SimpleFIN Bridge ($1.50 a month or $15 a year) before you add the first bank.
4. **Add each bank** on SimpleFIN Bridge: start a new connection for an institution and sign in to the bank there.
5. **Make a setup token** for Budget: add a new app connection, name it Budget, create the setup token and copy it. (A third-party guide calls these Financial Institutions → New Connection and Apps → New Connection → Create Setup Token; the Bridge may word them differently.) **A setup token works only once.** If linking refuses it, make a new one.
6. **Give it to the server.** On a Mac or Docker install, with the token copied, run `./setup.sh bank simplefin`. It reads the clipboard, links, clears the clipboard and prints only counts. Or paste it on the dashboard: Accounts → Connect a bank → SimpleFIN → **Link**. On an Olares, use its dashboard.

The dashboard then lists each bank behind the token. More about SimpleFIN on this server:
- **A bank that wants you to sign in again** is fixed on SimpleFIN Bridge, then retried from the dashboard or the phone (Sign in on SimpleFIN Bridge, then Try again). SimpleFIN gives no warning before that happens; the first failed sync is the signal.
- **How often:** SimpleFIN refreshes about once a day and allows about 24 requests a day. So the server pulls at most four times a day on its schedule (Settings → Sync → "SimpleFIN pulls a day", `BUDGET_SIMPLEFIN_DAILY_PULLS`, 1–12) and stops at 20 requests in any 24 hours.
- **History:** the first sync brings about a year. Older history follows over the next day or two, as far back as SimpleFIN has it (two years at most).
- **Stopping it:** remove the link on the dashboard, which deletes the server's access. Also turn off Budget's access on SimpleFIN Bridge, in its apps section, to stop the sharing there.
- **If SimpleFIN stops accepting the server's access altogether,** the bank's card asks for a new setup token, which keeps the link, its accounts and history. That's on the dashboard only. The phone says where: on a Mac or Docker install, http://budget.localhost:8081 on the server computer.

### Statements and syncing

**Statements.** CSV or OFX/QFX files go in under Imports, to fill in history from before a link's reach. Each import can be undone.

Linked accounts sync every 6 hours (`BUDGET_SYNC_INTERVAL_HOURS`, from 0.25 to 24), and **Sync now** pulls right away. An account that goes 2 days without a good pull shows as stale. Banks are added and removed only on the dashboard: the phone's token can sync, sign in again and import files, but can't add or remove a bank link or erase data.

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

**If you don't know which model to pick for Ask,** use DeepSeek-V4.1-Flash on OpenRouter. It answered every one of the app's own test questions, in about 3 seconds, for under a tenth of a cent each.
1. Make an OpenRouter key at https://openrouter.ai/keys.
2. In Settings → Models, paste it into **OpenRouter key** (Jev's), turn on **Only providers that keep nothing**, and Save.
3. Add a chat model: the **OpenRouter** button fills in `https://openrouter.ai/api/v1`. Turn on **Use Jev's OpenRouter key**, and pick the model `deepseek/deepseek-v4.1-flash`.

OpenRouter sends it to one of many hosts, so answers can vary a little from host to host. `anthropic/claude-haiku-5.5` did as well on the same questions, from one host, at about four times the price. The key can also go in `budget.env`, never shown: copy it, then `./setup.sh secret OPENROUTER_API_KEY`.

A bank transaction goes to a model only when one is configured for it. In the app, Settings → Decision model → "What the decision model sees" shows the exact request.

## 8. Morning summary (optional)

A daily push with yesterday's spending. It needs a paid Apple Developer membership (https://developer.apple.com/programs/enroll/).

1. **Create an APNs key.** You need the Account Holder or Admin role.
   - Open https://developer.apple.com/account/resources/keys/list and click **+**.
   - Enter a Key Name, tick **Apple Push Notifications service (APNs)**, then click **Configure**.
   - Pick the environment: **Sandbox** (an app installed from Xcode gets sandbox tokens), or **Sandbox & Production** if the form offers it. A Production-only key can't reach a phone installed from Xcode. A Team Scoped key is fine.
   - Continue, Confirm, then **Download**. **The `.p8` downloads only once**: keep it somewhere safe.
   - The **Key ID** is the 10 characters under the key's name, and also in the file's name, `AuthKey_<KeyID>.p8`.
2. **Give it to the server.** On the dashboard → Settings → Notifications, paste the `.p8` file's text (one line is fine) and its Key ID. Or, on a Mac or Docker install, in your own Terminal: `./setup.sh secret APNS_KEY --stdin < ~/Downloads/AuthKey_<KeyID>.p8`, then copy the Key ID and run `./setup.sh secret APNS_KEY_ID`.
3. **Team ID and bundle ID:** `./setup.sh app` fills in both on a Mac or Docker install (`APNS_TEAM_ID` and `APNS_TOPIC`, which is `<your prefix>.budget`). Otherwise enter them under Settings → Notifications too.
4. **On the phone:** Settings → Notifications → Morning summary, then tap **Send one now** to check.

## Running it

| | |
|---|---|
| Is everything up? | `./setup.sh check` (`--json` for a script) |
| Logs | `tail -f ~/Library/Application\ Support/BudgetServer/logs/server.log` (and `backup.log`) |
| Change a setting | Most are on the dashboard, and apply without a restart. A key in `budget.env`: `./setup.sh secret NAME`, which restarts the server. Anything else: edit `budget.env`, then `launchctl kickstart -k gui/$(id -u)/local.budget.server`. Every variable: [SERVER.md → Configuration](SERVER.md#configuration) |
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
| A step stops and prints a Before block | It needs your password or a browser. Paste the commands into your own Terminal, do the steps by hand, then run it again |
| `install.sh` stops at "Postgres isn't answering" | `brew services start postgresql@16`. If it still won't start, check `brew services info postgresql@16` |
| "The backup failed, so the server wasn't replaced" | Postgres is down, or the disk is full. Fix that and run it again. The old server is still running |
| `/health` doesn't answer after install | The end of `logs/server.log` says why. Usually it's Postgres, or another program on port 8080 (`lsof -i :8080`). To use other ports, change `PORT` or `DASHBOARD_PORT` in `budget.env` |
| The phone says it can't reach the server | Open `https://<address>/health` in the phone's Safari. If that fails, check whatever provides the address (VPN, tunnel or proxy). If it works, check the token in the app |
| Caddy's address never answers | Caddy couldn't get a certificate: the end of `logs/caddy.log` (or `docker compose … logs caddy`) says why. Usually the DNS record or the port forward. From outside your network, `http://<domain>` should reach this machine |
| The tunnel's address never answers | The end of `logs/tunnel.log`. `cloudflared tunnel info budget` shows whether it's connected |
| The phone's requests are turned away (401) | The token doesn't match. Run `./setup.sh app` with the phone connected to pair it again, or copy it from the dashboard → Settings → Connect your phone → Show |
| Linking a bank says it's disabled | `BUDGET_TOKEN_KEY` is empty in `budget.env` |
| "Plaid doesn't know the return address" | Add that address under Allowed redirect URIs at https://dashboard.plaid.com/developers/api, or clear the return address on the Keys form (on a Mac or Docker install, leave it empty) |
| SimpleFIN refuses the setup token | A token works once. Make a new one on SimpleFIN Bridge |
| It stops overnight | The Mac slept or logged out. See [step 3](#3-install) |
| Building fails with a Swift error | Use Xcode 26 or later as the active toolchain: `xcode-select -p`, `swift --version` |
