# Budget

A personal budget and planning app for iOS whose AI runs on hardware you own. **To build and run your own copy, run `./setup.sh` and follow [docs/SETUP.md](docs/SETUP.md)**, which leads to the [server](docs/INSTALL-SERVER.md) and [app](docs/INSTALL-APP.md) guides. The visual language (modeled on Origin) is in [docs/DESIGN.md](docs/DESIGN.md), the server contract in [docs/API.md](docs/API.md), running and deploying the server in [docs/SERVER.md](docs/SERVER.md), the assistant (tools, system prompt, grounding, decision model) in [docs/ASSISTANT.md](docs/ASSISTANT.md), and the budgeting method in [docs/BUDGETING.md](docs/BUDGETING.md).

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
setup.sh                     one-step setup: the server (Mac, Docker or Olares), the phone's HTTPS address
                             (Tailscale, Caddy, Cloudflare Tunnel), the app (./setup.sh check)
deploy/macos/                install.sh: the server as a launchd service on a Mac that stays on
deploy/olares/               deploy script for a self-hosted Olares box
project.yml                  XcodeGen spec (the .xcodeproj is generated)
```

## Run

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

The app starts on the demo ledger: six months of seeded household data, where every number is computed deterministically and the Ask answers are templated around tool results, with no model involved. To use the server, turn off "Use the demo ledger" in Settings → Advanced and enter the Budget API URL and token (see [docs/SERVER.md](docs/SERVER.md) → Operate), or launch with `-server URL -token T`.

Launch arguments for screenshots and UI tests: `-tab spending|ask|plan|activity`, `-ask "question"`, `-open recurring|spending/2026-08|category/dining[/2026-08]` (the same routes Ask's navigate proposals take), `-review` (review one group at a time), `-activity filters|select|summary|largest|notCounted|triage|search:TEXT|detail:ID-or-search` (simulator only: opens Activity in that state), `-settings`, `-checkup`, `-gallery`, `-live [-liveModel URL]` (demo ledger + a live model), `-server URL -token T` (saved like Settings), and in the simulator `-demoDate YYYY-MM-DD` (the whole app and the demo ledger on that day at noon; the UI tests use one fixed day, `UITests/DemoLaunch.swift`), `-noDemo` (behave like a phone), `-resetSettings` (a first run) and `-locked` (start on the lock screen). The live UI test runs with `TEST_RUNNER_LIVE=1 TEST_RUNNER_LIVE_MODEL=<URL>`; the server suite with `TEST_RUNNER_BUDGET_SERVER` and `TEST_RUNNER_BUDGET_TOKEN`.

## Status

Working end to end for one household: the iPhone app (Home, Spending, Ask, Plan, Activity, Settings), the server (ledger in Postgres, scheduled sync for Plaid and SimpleFIN links, CSV/OFX import with undo, categorizing by rules, merchant memory and an optional decision model), the web dashboard (linking banks, imports, review, categories and rules, settings), an assistant that answers from ledger tools and proposes changes you apply, and an optional morning push summary. Every AI piece is optional: with no model configured, Ask gives built-in answers and uncertain transactions wait for you.

Tests: `swift test` in `Packages/BudgetCore` and in `Server` (the Postgres suite runs when `POSTGRES_TEST_HOST` is set), and the UI tests in the `Budget` scheme. The live UI tests skip unless their environment variables are set.

## License

Apache License 2.0: see [LICENSE](LICENSE).
