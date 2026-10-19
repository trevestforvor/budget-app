# Budget: notes for coding agents

An iOS budgeting app (SwiftUI, iOS 26) with a self-hosted Swift server (Hummingbird 2 + Postgres) and a web dashboard. Layout, run commands and launch arguments: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Setting up a copy for someone, from a fresh clone to a phone with their banks linked: [docs/SETUP.md](docs/SETUP.md), driven by `./setup.sh` (`./setup.sh check --json` shows where a machine stands and the next step). It has a checklist for an agent; the details are in docs/INSTALL-SERVER.md and docs/INSTALL-APP.md.

## Build and test

```sh
xcodegen generate                                   # after any change to project.yml or Config/*.xcconfig
cd Packages/BudgetCore && swift test                # engine, demo ledger, assistant, decision models
cd Server && swift test                             # routes, settings, sync, push; Postgres suite with POSTGRES_TEST_HOST
xcodebuild test -project Budget.xcodeproj -scheme Budget -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Rules

- **Secrets stay out of the conversation and out of git.** Never print `BUDGET_API_TOKEN`, `BUDGET_TOKEN_KEY`, Plaid, SimpleFIN, OpenRouter or model keys, or an APNs `.p8`. Refer to them by name and location (`budget.env`). `./setup.sh app` pairs the phone without showing the token; otherwise point the person to the dashboard: Settings → Connect your phone → Show. `Config/Local.xcconfig` and `budget.env` are never committed.
- **The dashboard has no login.** It trusts that only this machine (or a login gateway) can reach it. Keep `HOST=127.0.0.1`. Expose only the API port (8080, bearer token) to the phone, through HTTPS. Reach the dashboard from another computer only through an SSH tunnel.
- **Never test against the server that holds a real ledger.** Tests, `/v1/admin/reset`, demo seeding and experiments go to a second server on other ports: no `POSTGRES_HOST` (in memory), with `BUDGET_ALLOW_DEMO=1`.
- **Real money data stays out of the conversation.** When checking a live server, report counts and totals, not transaction rows, merchants or account numbers.
- **Back up before replacing a running server:** `"$HOME/Library/Application Support/BudgetServer/backup.sh"` on a Mac install, `docker compose -f deploy/docker/compose.yaml run --rm backup once` in Docker (both also run daily; `./setup.sh server` and `deploy.sh` back up before replacing). Keep `BUDGET_TOKEN_KEY` with the dumps: bank tokens in them are sealed with it.
- **Some steps need the person, in a browser or their own Terminal:** Apple Developer, Plaid or SimpleFIN sign-up and linking banks, the Cloudflare login, anything with `sudo` (`./setup.sh before` prints them). Ask only for choices and IDs (team ID, bundle prefix, domain); don't invent them. Never ask for a secret in chat: the person types it into the dashboard, or copies it and you run `./setup.sh secret NAME` or `./setup.sh bank simplefin`.
