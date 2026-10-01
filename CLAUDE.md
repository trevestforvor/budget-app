# Budget: notes for coding agents

An iOS budgeting app (SwiftUI, iOS 26) with a self-hosted Swift server (Hummingbird 2 + Postgres) and a web dashboard. Layout and run commands: [README.md](README.md). Setting up a copy for someone, from a fresh clone to a phone with their banks linked: [docs/SETUP.md](docs/SETUP.md). It starts with a checklist for an agent.

## Build and test

```sh
xcodegen generate                                   # after any change to project.yml or Config/*.xcconfig
cd Packages/BudgetCore && swift test                # engine, demo ledger, assistant, decision models
cd Server && swift test                             # routes, settings, sync, push; Postgres suite with POSTGRES_TEST_HOST
xcodebuild test -project Budget.xcodeproj -scheme Budget -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Rules

- **Secrets stay out of the conversation and out of git.** Never print `BUDGET_API_TOKEN`, `BUDGET_TOKEN_KEY`, Plaid, SimpleFIN, OpenRouter or model keys, or an APNs `.p8`. Refer to them by name and location (`budget.env`). To hand the person the phone's token, point them to the dashboard: Settings → Connect your phone → Show. `Config/Local.xcconfig` and `budget.env` are never committed.
- **The dashboard has no login.** It trusts that only this machine (or a login gateway) can reach it. Keep `HOST=127.0.0.1`. Expose only the API port (8080, bearer token) to the phone, through HTTPS. Reach the dashboard from another computer only through an SSH tunnel.
- **Never test against the server that holds a real ledger.** Tests, `/v1/admin/reset`, demo seeding and experiments go to a second server on other ports: no `POSTGRES_HOST` (in memory), with `BUDGET_ALLOW_DEMO=1`.
- **Real money data stays out of the conversation.** When checking a live server, report counts and totals, not transaction rows, merchants or account numbers.
- **Back up before replacing a running server:** `"$HOME/Library/Application Support/BudgetServer/backup.sh"` on a Mac install (it also runs nightly). Keep `BUDGET_TOKEN_KEY` with the dumps: bank tokens in them are sealed with it.
- **Some steps need the person, in a browser:** Apple Developer (team ID, APNs key), Plaid or SimpleFIN sign-up and linking banks, Cloudflare (or other tunnel) login. Ask for those values; don't invent them.
