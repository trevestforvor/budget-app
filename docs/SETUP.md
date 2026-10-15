# Setting up your own Budget

This takes you from a fresh clone to your own server, your banks linked and the app on your phone. Nothing in the repo points at anyone else's server, Apple team or accounts. You supply each of those yourself.

The usual setup:
- **The server runs on a Mac that stays on**, such as a Mac mini. It holds the ledger in Postgres and serves the API and the dashboard.
- **The phone reaches the API over HTTPS.**
- **You open the dashboard from that Mac**, or from another computer through an SSH tunnel. The dashboard has no login, so it's never exposed.

## Quick start

On the Mac that will run the server:

```sh
git clone <this repo> budget && cd budget
./setup.sh
```

`setup.sh` asks before each step. Each step checks first and skips what's already done, so it's safe to run again, and also to update: `git pull`, then `./setup.sh`.

| Step | Run alone | What it does | Guide |
|---|---|---|---|
| Tools | `./setup.sh tools` | Checks macOS 26+ and Xcode; installs Homebrew, xcodegen and Postgres 16 | [Server §1](INSTALL-SERVER.md#1-prerequisites) |
| Server | `./setup.sh server` | Starts Postgres; builds and installs the server as a launchd service with nightly backups; checks `/health` | [Server §2–4](INSTALL-SERVER.md#2-postgres) |
| Address | `./setup.sh address` | Saves and checks the phone's HTTPS address for the API (a VPN, tunnel or proxy you set up) | [Server §5](INSTALL-SERVER.md#5-give-the-phone-an-https-address) |
| App | `./setup.sh app` | Signing config, the Xcode project; builds and installs on a connected iPhone | [App](INSTALL-APP.md) |
| Check | `./setup.sh check` | Shows what's installed and answering. Changes nothing | |

These parts happen in a browser, so you do them yourself:
1. [Link your banks](INSTALL-SERVER.md#6-link-banks) on the dashboard.
2. Optionally, add a model for Ask and categorizing in [AI](INSTALL-SERVER.md#7-ai-optional).
3. Optionally, set up the [morning summary](INSTALL-SERVER.md#8-morning-summary-optional) push.

Just looking? `xcodegen generate && open Budget.xcodeproj`, then run it in a simulator. It starts on a demo ledger, with no server and no account ([App → Try it first](INSTALL-APP.md#try-it-first-the-simulator)).

## Guides

- **[INSTALL-SERVER.md](INSTALL-SERVER.md):** the server on a Mac, step by step. Covers the HTTPS address, banks, AI, the morning summary, updates, backups and restore, and troubleshooting.
- **[INSTALL-APP.md](INSTALL-APP.md):** the iPhone app. Covers the simulator, signing, installing, connecting, and troubleshooting.
- **[SERVER.md](SERVER.md):** the server in depth. Covers every setting, Linux and Olares deploys, and tests.

## For a coding agent: the checklist

Read the rules in [CLAUDE.md](../CLAUDE.md) first:
- no secrets in the conversation;
- the dashboard never exposed;
- no tests against the real server.

Then run `./setup.sh check` to see where things stand, and work through the steps. `setup.sh` takes its answers from the environment, so it runs without prompts:

```sh
BUDGET_YES=1 ./setup.sh tools
BUDGET_YES=1 ./setup.sh server
BUDGET_PUBLIC_URL=https://… ./setup.sh address
BUDGET_TEAM_ID=… BUDGET_BUNDLE_PREFIX=com.… BUDGET_YES=1 ./setup.sh app   # BUDGET_DEVICE=… when several phones are connected
./setup.sh check
```

Ask the person for these, since only they can get them:

| Needed for | What | Where they get it |
|---|---|---|
| Installing on a phone | Apple team ID and a bundle prefix they own (`com.theirname`) | https://developer.apple.com/account → Membership details |
| Phone → server | An HTTPS address that forwards to the API: a mesh VPN like Tailscale, a tunnel or a proxy | They may already have one; [options](INSTALL-SERVER.md#5-give-the-phone-an-https-address) |
| Banks | A SimpleFIN setup token, or a Plaid client ID and secret | https://beta-bridge.simplefin.org, https://dashboard.plaid.com |
| Optional: Ask | An OpenAI-compatible endpoint, model ID and key | Their provider |
| Optional: morning push | An APNs key (`.p8`) and its Key ID | https://developer.apple.com/account/resources/authkeys/list |

Some steps need the person:
- **Before:** installing Xcode from the App Store and signing in to Xcode → Settings → Accounts.
- **During:** setting up the HTTPS address (a VPN, tunnel or proxy login); tapping Trust and turning on Developer Mode on the phone.
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
