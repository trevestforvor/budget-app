# Setting up your own Budget

This takes you from a fresh clone to your own server, your banks linked and the app on your phone. Nothing in the repo points at anyone else's server, Apple team or accounts. You supply each of those yourself.

The usual setup:
- **The server runs on a machine that stays on**: a Mac (such as a Mac mini), Docker on a Linux box or a NAS, or an Olares box. It holds the ledger in Postgres and serves the API and the dashboard.
- **The phone reaches the API over HTTPS**: through Tailscale, Caddy on your domain, a Cloudflare Tunnel, or an address you already have.
- **You open the dashboard on that machine**, or from another computer through an SSH tunnel. The dashboard has no login, so it's never exposed.
- **The app is built on a Mac with Xcode.** It can be the same Mac.

## Quick start

On the machine that will run the server (for a Docker server on Linux, run `./setup.sh` there, then `./setup.sh app` on a Mac):

```sh
git clone <this repo> budget && cd budget
./setup.sh
```

`setup.sh` asks before each step. Each step checks first and skips what's already done, so it's safe to run again, and also to update: `git pull`, then `./setup.sh`.

| Step | Run alone | What it does | Guide |
|---|---|---|---|
| Tools | `./setup.sh tools` | On a Mac: checks Xcode; installs Homebrew, xcodegen, and Postgres 16 for a Mac server. Checks Docker for a Docker server | [Server §1](INSTALL-SERVER.md#1-prerequisites) |
| Server | `./setup.sh server [mac\|docker\|olares]` | Asks where it runs. `mac`: Postgres, a launchd service, nightly backups. `docker`: Compose with Postgres and daily backups. `olares`: deploys to the installed app. Then checks `/health` | [Where it runs](INSTALL-SERVER.md#where-it-runs) |
| Address | `./setup.sh address [tailscale\|caddy\|cloudflare\|url]` | Asks how the phone reaches the API, sets that up, saves the address and checks it | [Server §5](INSTALL-SERVER.md#5-give-the-phone-an-https-address) |
| App | `./setup.sh app` | Signing config, the Xcode project; builds and installs on a connected iPhone | [App](INSTALL-APP.md) |
| Check | `./setup.sh check` | Shows what's installed and answering. Changes nothing | |

These parts happen in a browser, so you do them yourself:
1. [Link your banks](INSTALL-SERVER.md#6-link-banks) on the dashboard.
2. Optionally, add a model for Ask and categorizing in [AI](INSTALL-SERVER.md#7-ai-optional).
3. Optionally, set up the [morning summary](INSTALL-SERVER.md#8-morning-summary-optional) push.

Just looking? `xcodegen generate && open Budget.xcodeproj`, then run it in a simulator. It starts on a demo ledger, with no server and no account ([App → Try it first](INSTALL-APP.md#try-it-first-the-simulator)).

## Guides

- **[INSTALL-SERVER.md](INSTALL-SERVER.md):** the server on a Mac, in Docker or on an Olares. Covers the HTTPS address, banks, AI, the morning summary, updates, backups and restore, and troubleshooting.
- **[INSTALL-APP.md](INSTALL-APP.md):** the iPhone app. Covers the simulator, signing, installing, connecting, and troubleshooting.
- **[SERVER.md](SERVER.md):** the server in depth. Covers every setting, Linux and Olares deploys, and tests.

## For a coding agent: the checklist

Read the rules in [CLAUDE.md](../CLAUDE.md) first:
- no secrets in the conversation;
- the dashboard never exposed;
- no tests against the real server.

Then run `./setup.sh check` to see where things stand, and work through the steps. `setup.sh` takes its answers from the environment, so it runs without prompts:

```sh
BUDGET_SERVER=mac BUDGET_YES=1 ./setup.sh tools        # or docker, or olares
BUDGET_SERVER=mac BUDGET_YES=1 ./setup.sh server
BUDGET_ADDRESS=caddy BUDGET_DOMAIN=budget.example.com BUDGET_YES=1 ./setup.sh address   # or tailscale, cloudflare, or url with BUDGET_PUBLIC_URL=https://…
BUDGET_TEAM_ID=… BUDGET_BUNDLE_PREFIX=com.… BUDGET_YES=1 ./setup.sh app   # BUDGET_DEVICE=… when several phones are connected
./setup.sh check
```

Ask the person for these, since only they can get them:

| Needed for | What | Where they get it |
|---|---|---|
| Installing on a phone | Apple team ID and a bundle prefix they own (`com.theirname`) | https://developer.apple.com/account → Membership details |
| Where the server runs | Mac, Docker or Olares | Their choice; [compared](INSTALL-SERVER.md#where-it-runs) |
| Phone → server | Tailscale (private), Caddy (their domain, with ports 80 and 443 forwarded), a Cloudflare Tunnel (their domain on Cloudflare), or an address they already have | Their choice; [compared](INSTALL-SERVER.md#5-give-the-phone-an-https-address) |
| Banks | A SimpleFIN setup token, or a Plaid client ID and secret | https://beta-bridge.simplefin.org, https://dashboard.plaid.com |
| Optional: Ask | An OpenAI-compatible endpoint, model ID and key | Their provider |
| Optional: morning push | An APNs key (`.p8`) and its Key ID | https://developer.apple.com/account/resources/authkeys/list |

Some steps need the person:
- **Before:** installing Xcode from the App Store and signing in to Xcode → Settings → Accounts.
- **During:** for the HTTPS address, signing in to Tailscale, adding the DNS record and port forward for Caddy, or the Cloudflare login in the browser; tapping Trust and turning on Developer Mode on the phone.
- **After:** everything on the dashboard: banks, models, notifications.

Don't print `budget.env`. When they need the phone's token, point them to the dashboard: Settings → Connect your phone → Show.

## Tests

```sh
cd Packages/BudgetCore && swift test
cd Server && swift test                       # add POSTGRES_TEST_HOST/POSTGRES_TEST_PASSWORD for the Postgres suite
xcodebuild test -project Budget.xcodeproj -scheme Budget -destination 'platform=iOS Simulator,name=iPhone 17'
```

The tests use the demo ledger and fixtures, never a real account. The live tests skip unless they're pointed at a server or a model:
- a server: `TEST_RUNNER_BUDGET_SERVER` and `TEST_RUNNER_BUDGET_TOKEN`;
- a model: `TEST_RUNNER_LIVE=1` with `TEST_RUNNER_LIVE_MODEL`.

Point them at a test server: in memory, with `BUDGET_ALLOW_DEMO=1`, on other ports. Never the one holding the real ledger.
