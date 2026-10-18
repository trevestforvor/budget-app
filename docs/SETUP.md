# Setting up your own Budget

This takes you from a fresh clone to your own server, your banks linked and the app on your phone. Nothing in the repo points at anyone else's server, Apple team or accounts. You supply each of those yourself.

The usual setup:
- **The server runs on a machine that stays on**: a Mac (such as a Mac mini), or Docker on a Linux box or a NAS. It holds the ledger in Postgres and serves the API and the dashboard. (An Olares box works too, but only for the owner: its chart isn't in this repo.)
- **The phone reaches the API over HTTPS**: through Tailscale, Caddy on your domain, a Cloudflare Tunnel, or an address you already have.
- **You open the dashboard on that machine**, or from another computer through an SSH tunnel. The dashboard has no login, so it's never exposed.
- **The app is built on a Mac with Xcode.** It can be the same Mac.

## Quick start

On the machine that will run the server (for a Docker server on Linux, run `./setup.sh` there, then `BUDGET_SERVER=none ./setup.sh app` on a Mac):

```sh
git clone <this repo> budget && cd budget
./setup.sh before     # what you paste into your own Terminal first (Homebrew, Xcode's license, signing in to Xcode)
./setup.sh
```

`setup.sh` asks before each step. Each step checks first and skips what's already done, so it's safe to run again, and also to update: `git pull`, then `./setup.sh`.

| Step | Run alone | What it does | Guide |
|---|---|---|---|
| Before | `./setup.sh before` | Prints only what this machine still lacks that needs your password or a browser, as commands to paste and steps to click | [Server §1](INSTALL-SERVER.md#1-prerequisites) |
| Tools | `./setup.sh tools` | On a Mac: checks Xcode; installs xcodegen, and Postgres 16 for a Mac server (and Homebrew, when run in your own Terminal). Checks Docker for a Docker server | [Server §1](INSTALL-SERVER.md#1-prerequisites) |
| Server | `./setup.sh server [mac\|docker]` | `mac`: Postgres, a launchd service, nightly backups. `docker`: Compose with Postgres and daily backups. Then checks `/health` | [Where it runs](INSTALL-SERVER.md#where-it-runs) |
| Address | `./setup.sh address [tailscale\|caddy\|cloudflare\|url]` | Sets up how the phone reaches the API, saves the address and checks it | [Server §5](INSTALL-SERVER.md#5-give-the-phone-an-https-address) |
| App | `./setup.sh app` | Signing config, the server's app settings, the Xcode project; builds, installs and pairs a connected iPhone | [App](INSTALL-APP.md) |
| Banks | `./setup.sh banks [plaid\|simplefin]` | Prints the steps to get bank data, filled in with this install's addresses | [Server §6](INSTALL-SERVER.md#6-link-banks) |
| Check | `./setup.sh check [--json]` | What's done, what's left, and a last "Next:" line. Changes nothing | |

Three more take a value without ever showing it:
- `./setup.sh bank simplefin` links SimpleFIN with a setup token you copied.
- `./setup.sh secret NAME` sets one `budget.env` value (Plaid keys, the APNs key, a model key).
- `./setup.sh save-key` puts `BUDGET_TOKEN_KEY` in your Keychain.

These parts happen in a browser, so you do them yourself:
1. [Link your banks](INSTALL-SERVER.md#6-link-banks). `./setup.sh banks` prints the steps.
2. Optionally, add a model for Ask and categorizing in [AI](INSTALL-SERVER.md#7-ai-optional).
3. Optionally, set up the [morning summary](INSTALL-SERVER.md#8-morning-summary-optional) push.

Just looking? `xcodegen generate && open Budget.xcodeproj`, then run it in a simulator. It starts on a demo ledger, with no server and no account ([App → Try it first](INSTALL-APP.md#try-it-first-the-simulator)).

## Guides

- **[INSTALL-SERVER.md](INSTALL-SERVER.md):** the server on a Mac or in Docker. Covers the HTTPS address, banks, AI, the morning summary, updates, backups and restore, and troubleshooting.
- **[INSTALL-APP.md](INSTALL-APP.md):** the iPhone app. Covers the simulator, signing, installing, pairing, and troubleshooting.
- **[SERVER.md](SERVER.md):** the server in depth. Covers every setting, Linux and Olares deploys, and tests.

## For a coding agent: the checklist

Read the rules in [CLAUDE.md](../CLAUDE.md) first:
- no secrets in the conversation, ever, in either direction;
- the dashboard never exposed;
- no tests against the real server.

`setup.sh` takes its answers from `BUDGET_*` variables, so it runs without prompts. Without a terminal, it checks every answer a step needs before doing anything and lists all the missing ones at once. Steps that need a password or a browser stop and print what the person has to do, instead of waiting.

### Phase 0: where things stand

```sh
./setup.sh check --json
```

It prints `{"version":1,"server":"mac|docker|olares|none","steps":[{"id","state","detail","url"?}],"next":"..."}`. Each step's state is one of:
- `done`;
- `todo`: something to run;
- `person`: waiting on the person (it doesn't count toward the exit status);
- `warn`;
- `skipped`, with the reason in `detail`.

It exits 0 when nothing is `todo` or `warn`, 1 otherwise, and 2 for a bad flag. `next` is the first `todo` or `person` step in dependency order. Resume from there: every step is safe to run twice.

The step ids, roughly in order: `macos`, `xcode`, `xcode_license`, `xcode_account`, `homebrew`, `xcodegen`, `psql`, `caddy`, `cloudflared`, `machine`, `docker`, `docker_access`, `tailscale`, `server`, `loopback`, `postgres`, `launchd`, `env_private`, `api_token`, `token_key`, `api`, `dashboard`, `backups`, `awake`, `address_source`, `address`, `caddy_job`, `tunnel`, `tailscale_serve`, `banks`, `app_config`, `free_team`, `push_ids`, `xcodeproj`, `phone`, `phone_paired`, `public_paths`, `aasa`, `webhook`, `oauth_return`, `linking`, `plaid_keys`, `card_bills`, `model_configured`, `apns_key`, `save_key`. `model_configured` and `apns_key` are optional, so they read `skipped` until set. Which ones appear depends on the server and the address.

### Phase 1: ask the choices, once

Ask only for choices and IDs. Never for a secret.

| Choice | Variable | Notes |
|---|---|---|
| Where the server runs | `BUDGET_SERVER=mac\|docker\|none` | `none`: no server here, the app only. `olares` is for the owner only: it needs `deploy/olares/budgetapi/deploy.env`, and `BUDGET_DEPLOY=1` as well as `BUDGET_YES=1` ([compared](INSTALL-SERVER.md#where-it-runs)) |
| How the phone reaches it | `BUDGET_ADDRESS=tailscale\|caddy\|cloudflare\|url` | Plus `BUDGET_DOMAIN` for caddy and cloudflare, `BUDGET_PUBLIC_URL=https://…` for url, optionally `BUDGET_ACME_EMAIL` for caddy ([compared](INSTALL-SERVER.md#5-give-the-phone-an-https-address)) |
| Apple team: paid or free | `BUDGET_FREE_TEAM=1\|0` | Leave it unset to go by what Xcode says about the team |
| Team ID | `BUDGET_TEAM_ID` | Only when Xcode doesn't list the team. A paid team's is at https://developer.apple.com/account → Membership details |
| Bundle prefix they own | `BUDGET_BUNDLE_PREFIX=com.theirname` | The app becomes `<prefix>.budget` |
| Banks | `BUDGET_BANKS=plaid\|simplefin\|later` | Picks the steps the bare `./setup.sh` prints. `./setup.sh banks <choice>` prints them any time ([compared](INSTALL-SERVER.md#6-link-banks)) |
| Signing in to a bank again from the phone | `BUDGET_RECONNECT=no` to leave it out | On by default with a paid team and a public https address ([checklist](INSTALL-SERVER.md#signing-in-to-a-bank-again-from-the-phone)) |
| Ask (AI), morning push | none | Yes or no each; both happen on the dashboard later |
| Which phone, if several | `BUDGET_DEVICE=<name or UDID>`, or `BUDGET_DEVICE_PICK=<number>` | The number is its place in the list `./setup.sh app` prints |

Then check the answers against each other and tell the person plainly before doing anything. `./setup.sh`, `app` and `address` print the same notes under "Before you start":
- **Tailscale** means no Plaid webhooks (the server pulls on its schedule) and no phone reconnect.
- **A free team** means no morning summary or pace alerts, no phone reconnect, and reinstalling every 7 days.
- **Phone reconnect** needs a paid team and a public https address that isn't Tailscale.

**Secrets never go through the chat.** Tell the person to copy a value, then say when it's copied. Never ask them to paste it to you. If one lands in the chat anyway, don't repeat it, and suggest they make a new one.

| Secret | How it gets in |
|---|---|
| `BUDGET_API_TOKEN`, `BUDGET_TOKEN_KEY`, the Postgres password | `./setup.sh server` makes them on disk. Never read them. `./setup.sh app` hands the token to the phone; `./setup.sh save-key` keeps a copy of the key |
| Plaid client ID and secret | The person types them into the dashboard: Accounts → Connect a bank → Plaid → Keys → Save and test. Or they copy each one and you run `./setup.sh secret PLAID_CLIENT_ID`, then `./setup.sh secret PLAID_SECRET` |
| SimpleFIN setup token | They copy it on SimpleFIN Bridge and you run `./setup.sh bank simplefin`. Or they paste it on the dashboard |
| A model key | The dashboard: Settings → Models. Or `./setup.sh secret OPENROUTER_API_KEY` (or `MODEL_API_KEY`) after they copy it |
| The APNs key (`.p8`) and its Key ID | The dashboard: Settings → Notifications. Or `./setup.sh secret APNS_KEY --stdin < ~/Downloads/AuthKey_<KeyID>.p8`, then `./setup.sh secret APNS_KEY_ID` |

`secret` reads with no echo when it has a terminal. Without one (your shell), it reads the clipboard and clears it afterwards. `--stdin` reads a pipe. It never prints the value, keeps `budget.env` at mode 600, and restarts the server. It refuses `BUDGET_API_TOKEN`, `BUDGET_TOKEN_KEY` and any name not on its list.

### Phase 2: the person's Before block

```sh
BUDGET_SERVER=mac BUDGET_ADDRESS=caddy ./setup.sh before
```

It prints only what this machine still lacks. Commands to paste into their own Terminal: the Homebrew installer, `sudo xcode-select -s /Applications/Xcode.app`, `sudo xcodebuild -license accept`, and with `BUDGET_ADDRESS=cloudflare`, `brew install cloudflared` and `cloudflared tunnel login`. On Linux, `sudo usermod -aG docker $USER`. Steps by hand: install Xcode, sign in to Xcode (Settings → Accounts → + → Apple Account → Continue), install Docker, log out and back in. Hand it over, wait, then run `./setup.sh check` again.

### Phase 3: server and address

```sh
BUDGET_SERVER=mac BUDGET_YES=1 ./setup.sh tools        # or docker, or none
BUDGET_SERVER=mac BUDGET_YES=1 ./setup.sh server       # backs up first; makes the secrets on disk
BUDGET_ADDRESS=caddy BUDGET_DOMAIN=budget.example.com BUDGET_YES=1 ./setup.sh address
```

- **Caddy:** the person adds the DNS record and the port forward the script prints. Then rerun `address` until `/health` answers.
- **Cloudflare:** `cloudflared tunnel login` must have run first (it's in the Before block). Without `~/.cloudflared/cert.pem` and no terminal, `address` stops and says so.
- **Tailscale:** the person installs and signs in on this machine and the phone, and turns on HTTPS certificates.

### Phase 4: the app

```sh
BUDGET_TEAM_ID=… BUDGET_BUNDLE_PREFIX=com.… BUDGET_YES=1 ./setup.sh app
```

It writes `Config/Local.xcconfig` in place, keeping values set by hand:
- the team and prefix;
- `BUDGET_FREE_TEAM = YES` for a free team;
- `BUDGET_API_HOST` when phone reconnect fits.

For a paid team on a Mac or Docker server, it also sets `APNS_TEAM_ID`, `APNS_TOPIC` and, with a host, `BUDGET_IOS_APP_ID` in `budget.env`. It restarts the server and checks the Universal Link file before building. If that file doesn't name the app yet, it builds without Associated Domains and says to run `app` again later.

With a phone connected, it builds, installs and opens the app with the server's address and token (never shown), and prints **PAIRED**. Before that, the person plugs in the phone, taps Trust, and turns on Developer Mode ([INSTALL-APP.md](INSTALL-APP.md#what-you-need)). Without a terminal it needs `BUDGET_YES=1` up front, since it changes `budget.env`, restarts the server, builds and installs. With no phone, several phones and no pick, or a failed build, it prints **NOT INSTALLED** and exits 1. Fix what it says and rerun.

### Phase 5: banks

```sh
./setup.sh banks simplefin      # or plaid; with no argument, both and the comparison
```

Hand the person what it prints. It covers each kind of server, with full URLs and this install's addresses.
- **SimpleFIN:** the person signs up, adds banks and makes a setup token on SimpleFIN Bridge, and copies it. Then you run `./setup.sh bank simplefin`. It checks that the server can seal tokens before reading the clipboard, links, clears the clipboard, and prints only counts. Mac and Docker only.
- **Plaid:** the person gets access and keys, enters them on the dashboard (or copies them for `./setup.sh secret`), turns on Card bills, and links banks on the dashboard. Then `./setup.sh check --json` shows `plaid_keys`, `card_bills`, `aasa`, `webhook` and `oauth_return`.

### Phase 6: optional AI and push

- **Ask:** on the dashboard, Settings → Models. The default to suggest is in [INSTALL-SERVER.md §7](INSTALL-SERVER.md#7-ai-optional).
- **Morning push** (paid team): `./setup.sh app` already filled in the team and topic. The person makes an APNs key ([§8](INSTALL-SERVER.md#8-morning-summary-optional)) and enters it on the dashboard. On the phone: Settings → Notifications → Morning summary, then **Send one now**.

### Phase 7: wrap up

```sh
./setup.sh save-key             # into the login Keychain, as "Budget server token key"
./setup.sh check --json
```

`save-key --clipboard` puts it on the clipboard instead. `save-key --done` records a copy the person saved by hand (the only way on Linux). Each writes `$BUDGET_HOME/token-key-saved`, which `check` compares with the current key. Report only the steps left as `person` or `todo`, each with its full URL.

Don't print `budget.env`. When the person needs the phone's token, point them to the dashboard: Settings → Connect your phone → Show.

### The steps only the person can do

| # | Step | Where, and what to click |
|---|---|---|
| 1 | Install Xcode 26 or later and open it once | https://apps.apple.com/app/xcode/id497799835 |
| 2 | Homebrew, Xcode's toolchain and license (needs their password) | Paste what `./setup.sh before` prints into their own Terminal |
| 3 | Sign in to Xcode | Xcode → Settings → Accounts → + (bottom left) → Apple Account → Continue |
| 4 | Optional: the paid Apple Developer Program, for push and phone reconnect | https://developer.apple.com/programs/enroll/ ($99 a year; an organization needs a D-U-N-S number first, which can take a week) |
| 5 | Linux Docker: join the docker group | `sudo usermod -aG docker $USER`, then log out and back in |
| 6 | Keep the server Mac awake and logged in | System Settings → Energy → "Prevent automatic sleeping when the display is off"; System Settings → Users & Groups → automatic login |
| 7 | The address: Tailscale | https://tailscale.com/download on both devices, signed in to one account; HTTPS certificates on at https://login.tailscale.com/admin/dns |
| 7 | The address: Caddy | A DNS A record for the domain at their registrar, and their router forwarding ports 80 and 443 to this machine |
| 7 | The address: Cloudflare | `cloudflared tunnel login` in their Terminal, then pick the domain in the browser window it opens |
| 8 | Phone: pair, Developer Mode, trust | Cable → Trust; Settings → Privacy & Security → Developer Mode → Restart → Turn On; Settings → General → VPN & Device Management → Developer App → Trust ([INSTALL-APP.md](INSTALL-APP.md#what-you-need)) |
| 9 | Plaid: sign up, pick a plan, copy keys | https://dashboard.plaid.com, https://dashboard.plaid.com/trial-plan, https://dashboard.plaid.com/developers/keys ([§6](INSTALL-SERVER.md#plaid-step-by-step)) |
| 10 | Plaid: enter the keys | Dashboard → Accounts → Connect a bank → Plaid → Keys → Save and test |
| 11 | Plaid: the phone's return address (phone reconnect) | Under Allowed redirect URIs at https://dashboard.plaid.com/developers/api, add what `./setup.sh banks plaid` prints |
| 12 | Plaid: card bills | Dashboard → Settings → Sync → Card bills (Plaid Liabilities) |
| 13 | Plaid: link banks | Dashboard → Accounts → Connect a bank → Plaid → Link an account |
| 14 | SimpleFIN: sign up, subscribe, add banks, make a setup token | https://beta-bridge.simplefin.org/auth/login ([§6](INSTALL-SERVER.md#simplefin-step-by-step)) |
| 15 | Optional: an Ask model key | Their provider; for OpenRouter, https://openrouter.ai/keys |
| 16 | Optional: an APNs key | https://developer.apple.com/account/resources/keys/list ([§8](INSTALL-SERVER.md#8-morning-summary-optional)) |
| 17 | Optional: the morning summary on the phone | Settings → Notifications → Morning summary → Send one now |
| 18 | Keep a copy of `BUDGET_TOKEN_KEY` | `./setup.sh save-key` does it on a Mac; on Linux, they copy it from `budget.env` into a password manager |

## Tests

```sh
cd Packages/BudgetCore && swift test
cd Server && swift test                       # add POSTGRES_TEST_HOST/POSTGRES_TEST_PASSWORD for the Postgres suite
xcodebuild test -project Budget.xcodeproj -scheme Budget -destination 'platform=iOS Simulator,name=iPhone 17'
```

The tests use the demo ledger and fixtures, never a real account. The live tests skip unless they're pointed at a server or a model:
- a server: `TEST_RUNNER_BUDGET_SERVER` and `TEST_RUNNER_BUDGET_TOKEN`;
- a model: `TEST_RUNNER_LIVE=1` with `TEST_RUNNER_LIVE_MODEL`.

Point them at a test server: in memory, with `BUDGET_ALLOW_DEMO=1`, on other ports. Never the one holding the real ledger. A test server also takes a made-up SimpleFIN setup token, so linking can be tried with no bank ([SERVER.md → Tests](SERVER.md#tests)).

To try `setup.sh` itself, use a copy of the repo with `BUDGET_HOME` pointing at a scratch folder. `BUDGET_PASTE`, `BUDGET_COPY`, `BUDGET_KEYCHAIN` (an existing keychain file) and `BUDGET_DERIVED` keep the clipboard, the login Keychain and Xcode's build folder out of it.
