# Setting up your own Budget

This walks you from a fresh clone to your own server, your own bank links and the app on your phone. Nothing in the repo points at anyone else's server, Apple team or accounts. Every one of those is a value you supply.

The usual shape: **the server runs on a Mac that stays on** (a Mac mini, say), the phone reaches its API over HTTPS, and you open the dashboard from that Mac or through an SSH tunnel.

## For a coding agent: the checklist

Work through the sections below in order, and verify each step before moving on. Read the rules in [CLAUDE.md](../CLAUDE.md) first: no secrets in the conversation, the dashboard never exposed, no tests against the real server.

Ask the person for these, since only they can get them:

| Needed for | What | Where they get it |
|---|---|---|
| Installing on a phone | Apple team ID and a bundle prefix they own (`com.theirname`) | [developer.apple.com/account](https://developer.apple.com/account) → Membership details |
| Phone → server | An HTTPS address for the API, or a Cloudflare account with a domain for a tunnel | They may already have one |
| Banks | SimpleFIN setup token, or Plaid client ID and secret | [SimpleFIN Bridge](https://beta-bridge.simplefin.org), [Plaid dashboard](https://dashboard.plaid.com) |
| Optional: Ask | An OpenAI-compatible endpoint, model id and key | Their provider |
| Optional: morning push | An APNs key (`.p8`), its Key ID | [developer.apple.com/account/resources/authkeys/list](https://developer.apple.com/account/resources/authkeys/list) |

You can do the rest yourself: install tools, build, install the server, create the database, write config, start services and check that each step works. Linking banks happens in the dashboard in a browser, so the person does that, with you guiding.

## 1. Prerequisites (the server Mac)

- **macOS 26 or later.** The server package targets macOS 26 and won't build on older systems. Check with `sw_vers -productVersion`.
- **Xcode 26** (Swift 6.2). Check with `swift --version`. If it's missing, the person installs Xcode from the App Store; then run `xcode-select --install`.
- **Homebrew tools:** `brew install xcodegen postgresql@16 cloudflared`

To build the iPhone app, you also need Xcode 26 on whichever Mac builds it, which can be the same one.

## 2. Try the app in the simulator (no setup)

```sh
xcodegen generate
open Budget.xcodeproj        # run the Budget scheme on an iPhone simulator
```

The simulator starts on the demo ledger: six months of made-up household data (fictional banks and merchants), computed on the device with no server and no model.

## 3. Postgres

```sh
brew services start postgresql@16     # starts now and at login, on 127.0.0.1:5432
```

Homebrew's Postgres trusts local connections, and `install.sh` (next step) creates the `budget` role and database when they're missing. You can use any Postgres 16 instead. If it needs a password, set `POSTGRES_*` in `budget.env` and create the role and database yourself.

## 4. Install the server

```sh
deploy/macos/install.sh
```

This does the following:
- builds the release binary;
- installs it in `~/Library/Application Support/BudgetServer/`;
- writes `budget.env` there (mode 600) with a fresh `BUDGET_API_TOKEN` and `BUDGET_TOKEN_KEY`, plus this Mac's time zone;
- creates the database;
- installs two LaunchAgents: `local.budget.server`, which is always on and restarts if it exits, and `local.budget.backup`, which runs `pg_dump` nightly at 3:30 and keeps 14;
- waits for `/health`.

Run it again whenever you want to rebuild and restart. It never overwrites `budget.env`.

- **Keep `BUDGET_TOKEN_KEY`:** the person should copy it from `budget.env` into a password manager. If it's lost, every bank has to be linked again.
- **Stay up:** LaunchAgents run while the user is logged in. On a headless Mac, turn on automatic login (System Settings → Users & Groups) and stop sleep: System Settings → Energy → "Prevent automatic sleeping when the display is off", or `sudo pmset -a sleep 0`.
- **Check:** `curl -s http://127.0.0.1:8080/health`, and `tail -f ~/Library/Application\ Support/BudgetServer/logs/server.log`.
- **Settings:** edit `budget.env`, then `launchctl kickstart -k gui/$(id -u)/local.budget.server`. Most settings (models, Plaid, notifications) are easier on the dashboard, where changes apply without a restart. Every variable is listed in [SERVER.md](SERVER.md#configuration).
- **Update:** `git pull`, run `~/Library/Application\ Support/BudgetServer/backup.sh`, then run `deploy/macos/install.sh`.
- **Remove:** `deploy/macos/install.sh --uninstall` stops the server and removes the jobs, and keeps the data, settings and backups.

Both ports listen on `127.0.0.1` only: the API on 8080 (bearer token) and the dashboard on 8081 (**no login**: never make it reachable from the network).

## 5. Open the dashboard

- **On the server Mac:** `http://budget.localhost:8081`
- **From another computer:** `ssh -L 8081:127.0.0.1:8081 <server-mac>`, then `http://budget.localhost:8081` on that computer. This needs Remote Login enabled on the server Mac (System Settings → General → Sharing).

## 6. Give the phone an HTTPS address for the API

Use whatever the person already uses to reach their server, as long as it terminates HTTPS and forwards only to `127.0.0.1:8080`. With Cloudflare, a named tunnel gives a lasting address. It needs a domain on their Cloudflare account:

```sh
cloudflared tunnel login                          # the person approves in a browser
cloudflared tunnel create budget
cloudflared tunnel route dns budget budget.<their-domain>
cat > ~/.cloudflared/config.yml <<EOF
tunnel: budget
credentials-file: $HOME/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: budget.<their-domain>
    service: http://127.0.0.1:8080
  - service: http_status:404
EOF
cloudflared service install                       # runs it at login; check `cloudflared service --help` on their version
```

Only the API port goes in `ingress`, never 8081. For a quick trial with no domain, `cloudflared tunnel --url http://127.0.0.1:8080` prints a temporary `https://…trycloudflare.com` address.

Then set `BUDGET_PUBLIC_URL=https://budget.<their-domain>` in `budget.env` and restart, so the dashboard's "Connect your phone" shows it. Check from outside: `curl -s https://budget.<their-domain>/health`.

## 7. Build the app for the phone

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

In it, set `DEVELOPMENT_TEAM` (their team ID) and `BUDGET_BUNDLE_PREFIX` (such as `com.theirname`; the app becomes `com.theirname.budget`). Then:

```sh
xcodegen generate
open Budget.xcodeproj         # select their iPhone and Run
```

`Local.xcconfig` is git-ignored. The app's push entitlement (for the morning summary) needs a paid Apple Developer Program membership. With a free Personal Team, remove the `entitlements:` block from `project.yml` in their copy.

On first launch the phone asks for a server. Enter the HTTPS address and the API token, shown on the dashboard under Settings → Connect your phone → Show.

## 8. Link banks (the person, on the dashboard)

Go to Accounts → **Connect a bank**:

- **SimpleFIN** (easiest): sign up at [SimpleFIN Bridge](https://beta-bridge.simplefin.org) (about $15 a year), connect the banks there, create a setup token and paste it in. History is limited to about 90 days per request.
- **Plaid** (more banks, two years of history): use their own [Plaid account](https://dashboard.plaid.com). Start in Sandbox (free, fake data), then request the free Trial plan for real data: 10 bank logins for the life of the account, and removing one doesn't free its slot. Enter the client ID and secret on the dashboard.
  - OAuth banks (Chase and others) need an `https://` redirect URI registered with Plaid that leads back to the dashboard. One option is [Caddy](https://caddyserver.com) serving the dashboard as `https://budget.localhost` on the computer whose browser runs Link. That hasn't been tested here.
  - The details are in [SERVER.md](SERVER.md#plaid-step-by-step).
- **Statements:** CSV or OFX/QFX files go in under Imports, to fill in history before a link's reach. Each import can be undone.

After that, linked accounts sync every 6 hours (`BUDGET_SYNC_INTERVAL_HOURS`), and the dashboard's Sync now pulls on demand.

## 9. AI (optional)

With no model set, Ask gives built-in answers computed from the ledger, and anything rules and merchant memory can't file waits in Review. To add models, go to the dashboard → Settings → Models (each has a **Test** button):

- **Ask (chat):** any OpenAI-compatible endpoint, model id and key. That can be OpenAI, a router like OpenRouter or LiteLLM, or a model you host.
- **Categorizing:** off by default. It can be Jev through their own OpenRouter key (it sees only the merchant name and the category list), or a self-hosted llama.cpp server with `/v1/decision`.

Bank data goes to a model only if one is configured. In the app, Settings → Decision model → "What the decision model sees" shows the exact request.

## 10. Morning summary (optional)

A daily push with yesterday's spending. On the dashboard → Settings → Notifications, enter:
- the `.p8` key's text and its Key ID;
- their team ID;
- the app's bundle ID (`<their prefix>.budget`).

Then they turn it on in the app's Settings.

## Tests

```sh
cd Packages/BudgetCore && swift test
cd Server && swift test                       # add POSTGRES_TEST_HOST/POSTGRES_TEST_PASSWORD for the Postgres suite
xcodebuild test -project Budget.xcodeproj -scheme Budget -destination 'platform=iOS Simulator,name=iPhone 17'
```

The tests use the demo ledger and fixtures, never a real account. Live tests skip unless they're pointed at a server or model (`TEST_RUNNER_BUDGET_SERVER`/`TEST_RUNNER_BUDGET_TOKEN`, `TEST_RUNNER_LIVE=1` with `TEST_RUNNER_LIVE_MODEL`). Run them against a test server: in memory, `BUDGET_ALLOW_DEMO=1`, other ports. Never use the one holding the real ledger.
