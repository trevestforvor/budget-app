# Developing Budget

How the repo is laid out, how to build and test it, and the launch arguments the app takes. To set up your own copy instead, start at [SETUP.md](SETUP.md).

## Layout

```
App/                         SwiftUI thin client (iOS 26, Swift 6 strict concurrency)
  Features/Home|Spending|Ask|Plan|Activity|Settings
  Support/AppModel.swift     API selection, shared lookups, cross-tab nav
  Support/Bridges.swift      Ledger models → design-system vocabulary
Packages/BudgetCore/
  Sources/DesignSystem/      Tokens, components, gallery (no money models)
  Sources/BudgetKit/         Wire models, BudgetAPI protocol, Remote + Caching clients, the engine
                             (Ledger, LedgerBudgetAPI, ingest, Categorizer, file import), sources,
                             agent loop, decision models. Builds on Linux for the server
  Tests/                     Swift Testing: ledger math, review loop, ask routing, ingest, cache, contrast
Server/                      Budget API: Swift + Hummingbird 2 + Postgres (macOS, Linux, or an Olares box)
Config/                      Budget.xcconfig; your signing goes in Local.xcconfig (not checked in)
setup.sh                     one-step setup: the server (Mac or Docker), the phone's HTTPS address (Tailscale,
                             Caddy, Cloudflare Tunnel), the app and its pairing, the bank steps, secrets that never
                             show (./setup.sh check --json for where things stand)
deploy/macos/                install.sh: the server as a launchd service on a Mac that stays on
deploy/docker/               compose.yaml: the server, Postgres and daily backups
deploy/olares/               deploy script for the owner's Olares box (its chart isn't in this repo)
project.yml                  XcodeGen spec (the .xcodeproj is generated)
```

## Build and run

```sh
xcodegen generate
open Budget.xcodeproj            # starts on the demo ledger until Settings points it at a server
cd Packages/BudgetCore && swift test
swift run budget-assistant tools # OpenAI-compatible tools array; also: prompt, catalog
swift run budget-assistant ask "What is my DoorDash budget?" --base URL   # live agent loop on your model server (or BUDGET_MODEL_BASE)
swift run budget-assistant decide --base URL [--percent 95] [--shim URL]  # live decision model on the review queue
xcodebuild test -project Budget.xcodeproj -scheme Budget \
  -destination 'platform=iOS Simulator,name=iPhone 17'   # UI tests: propose → apply → verify
```

The app starts on the demo ledger: six months of seeded household data, where every number is computed deterministically and the Ask answers are templated around tool results, with no model involved. To use the server, turn off "Use the demo ledger" in Settings → Advanced and enter the Budget API URL and token (see [SERVER.md](SERVER.md) → Operate), or launch with `-server URL -token T`.

A local server for development runs in memory with the demo ledger, on its own ports, never against a real ledger:

```sh
cd Server && BUDGET_API_TOKEN=dev BUDGET_ALLOW_DEMO=1 BUDGET_SEED_DEMO=1 DASHBOARD_PORT=8081 swift run BudgetServer
open http://budget.localhost:8081
```

## Launch arguments

For screenshots and UI tests:

- `-tab spending|ask|plan|activity`, `-ask "question"`
- `-open recurring|spending/2026-08|category/dining[/2026-08]` (the same routes Ask's navigate proposals take)
- `-review` (review one group at a time), `-settings`, `-checkup`, `-gallery`
- `-activity filters|select|summary|largest|notCounted|triage|search:TEXT|detail:ID-or-search` (simulator only: opens Activity in that state)
- `-live [-liveModel URL]` (demo ledger + a live model), `-server URL -token T` (saved like Settings)
- In the simulator: `-demoDate YYYY-MM-DD` (the whole app and the demo ledger on that day at noon; the UI tests use one fixed day, `UITests/DemoLaunch.swift`), `-noDemo` (behave like a phone), `-resetSettings` (a first run) and `-locked` (start on the lock screen)

The README screenshots are the demo ledger on its fixed day: `-demo -demoDate 2026-09-20` plus the argument for each screen.

## Tests

`swift test` in `Packages/BudgetCore` and in `Server` (the Postgres suite runs when `POSTGRES_TEST_HOST` is set), and the UI tests in the `Budget` scheme. The live UI test runs with `TEST_RUNNER_LIVE=1 TEST_RUNNER_LIVE_MODEL=<URL>`; the server suite with `TEST_RUNNER_BUDGET_SERVER` and `TEST_RUNNER_BUDGET_TOKEN`. Both skip unless their environment variables are set.

## Contributing

`main` is protected: changes land through a pull request with one approving review. Keep real money data out of issues, fixtures and screenshots; the demo ledger is there for that.
