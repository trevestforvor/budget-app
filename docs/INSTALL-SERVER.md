# Installing the server

The server holds the ledger, syncs the banks, runs the assistant and serves the dashboard. This guide installs it on a Mac that stays on (a Mac mini, say), as a service that starts at login and restarts if it exits. For Linux or an Olares box, see [SERVER.md](SERVER.md).

When you're done you'll have:
- the **API** on `127.0.0.1:8080`, which the phone reaches over HTTPS with a bearer token;
- the **dashboard** on `127.0.0.1:8081`, for linking banks, imports, review and settings. **It has no login**, so it's only ever reached from this Mac or through an SSH tunnel;
- a nightly database backup.

## The short way

```sh
./setup.sh tools      # Homebrew tools: xcodegen, postgresql@16
./setup.sh server     # Postgres, build, install, start, check /health
./setup.sh address    # save and check the phone's HTTPS address (step 5)
./setup.sh check      # what's installed and answering, at any time
```

Each step checks first and skips what's done, so you can run it again. Then [link your banks](#6-link-banks) in the dashboard. The sections below are what those steps do, in case you'd rather do it by hand or something goes wrong.

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

The server listens only on this Mac (`127.0.0.1`), and the app talks to it over HTTPS. So the phone needs an address that terminates HTTPS and forwards to `127.0.0.1:8080`, and to nothing else. The dashboard on 8081 has no login. Use whatever you already have, or one of these:

- **Private: a mesh VPN on the Mac and the phone.** This is the smallest exposure: nothing is reachable from the internet. With [Tailscale](https://tailscale.com), for example, run `tailscale serve --bg 8080` on the Mac. That gives you `https://<mac-name>.<tailnet>.ts.net`, reachable only from your own devices. The phone needs the VPN connected to sync. The morning push still arrives without it, because it comes from Apple.
- **Public: a tunnel or a reverse proxy.**
  - A [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) needs a domain on Cloudflare, and no open ports.
  - Caddy needs a port forward on your router and a domain.
  - Either way, the API token is the only lock, so keep it secret.
- **On an Olares box** the API's public entrance already is this address ([SERVER.md](SERVER.md)).

Then save it, so the dashboard shows it under "Connect your phone" and `./setup.sh check` keeps testing it:

```sh
./setup.sh address      # or: BUDGET_PUBLIC_URL=https://… ./setup.sh address
```

**Check from outside:** with Wi-Fi off, open `https://<address>/health` in the phone's Safari. It should say `"status":"ok"`.

## 6. Link banks

On the dashboard, go to Accounts → **Connect a bank**.

- **SimpleFIN** (the easiest). Sign up at [SimpleFIN Bridge](https://beta-bridge.simplefin.org) (about $15 a year), connect your banks there, then create a setup token and paste it in. Each sync reaches back about 90 days.
- **Plaid** (more banks, two years of history). Use your own [Plaid account](https://dashboard.plaid.com) and enter its client ID and secret on the dashboard.
  - Start in Sandbox, which is free and uses made-up data.
  - Then request the free Trial plan for real banks. It allows 10 bank logins for the life of the account, and removing one doesn't free its slot.
  - OAuth banks (Chase and others) also need an `https://` redirect URI: [SERVER.md → Plaid step by step](SERVER.md#plaid-step-by-step).
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
| Remove | `deploy/macos/install.sh --uninstall` stops the server and the nightly backups. Your data, `budget.env` and the backups stay |

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
| The phone's requests are turned away (401) | The token doesn't match. Copy it again from the dashboard → Settings → Connect your phone → Show |
| Linking a bank says it's disabled | `BUDGET_TOKEN_KEY` is empty in `budget.env` |
| It stops overnight | The Mac slept or logged out. See [step 3](#3-install) |
| Building fails with a Swift error | Use Xcode 26 or later as the active toolchain: `xcode-select -p`, `swift --version` |
