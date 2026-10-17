# Budget API server

The always-on half of the app: a Swift server (Hummingbird 2) on the Olares that owns the ledger, syncs accounts, runs the agent loop on the local model, and answers the iPhone app. It links `BudgetKit` directly, so the server and the demo run the same tested engine (`LedgerBudgetAPI` over `Ledger`). Routes: [API.md](API.md).

**Where it runs:** anywhere Swift runs (macOS 26+ or Linux), with Postgres. On a Mac that stays on, `deploy/macos/install.sh` installs it as a launchd service; anywhere with Docker, `deploy/docker/compose.yaml` runs it with Postgres and daily backups ([INSTALL-SERVER.md](INSTALL-SERVER.md), or `./setup.sh server`). On an Olares box it's the `budgetapi` app, with two entrances:
- **API** (the phone): `https://<appid>0.<you>.olares.com`, `public` (reachable from anywhere, no VPN and no Olares login; the bearer token on `/v1` is the lock). No launcher tile. From 0.6.0 it also has to pass three unauthenticated paths through untouched, with no Olares login in front of them: `POST /v1/plaid/webhook` (with the `Plaid-Verification` header intact), `GET /.well-known/apple-app-site-association` and `GET /plaid/oauth-return` ([Olares and Plaid, server 0.6.0](#olares-and-plaid-server-060)).
- **Dashboard** (the launcher tile "Budget"): `https://<appid>1.<you>.olares.com`, `internal` (Olares login). Ledger summary, CSV/OFX import with undo, SimpleFIN linking, linked accounts and sync, categorization and models, server settings, and the URL + token to set up the phone.

Its own Postgres 16 (`budgetapidb`) lives in the same app. Olares numbers entrance hosts once an app has more than one (`<appid>0`, `<appid>1`); with one entrance it's the bare `<appid>`.

## Layout

```
Server/
  Package.swift                     BudgetKit (../Packages/BudgetCore), hummingbird, postgres-nio,
                                    async-http-client, swift-crypto
  Sources/BudgetServerCore/
    Config.swift                    ServerConfig.fromEnvironment
    App.swift                       service graph, startup (migrate → load or create ledger), run
    Routes.swift                    every route, auth + Origin middleware, error mapping
    PostgresStore.swift             tables, migrations, diff saves
    Records.swift                   TokenSealer (AES-GCM), StoredLink, ImportRecord, MemoryStore
    SyncService.swift               per-link sync, 2-year first window, scheduler
    AHCTransport.swift              HTTPTransport over AsyncHTTPClient
  Sources/BudgetServer/main.swift
  Tests/BudgetServerTests/          routes (HummingbirdTesting), RemoteBudgetAPI parity over a real
                                    socket, Plaid exchange + sync, Postgres store (when a DB is given)
deploy/olares/budgetapi/deploy.sh   build on the Olares + install + restart (--check: Linux tests + build only)
deploy/macos/install.sh             a launchd service on a Mac, with nightly pg_dump backups
deploy/docker/compose.yaml          server + Postgres + daily backup in Compose (+ Caddy with the caddy profile)
```

## Run it locally

```sh
cd Server
BUDGET_API_TOKEN=dev BUDGET_SEED_DEMO=1 PORT=8080 swift run BudgetServer     # in-memory store
curl -H 'Authorization: Bearer dev' localhost:8080/v1/overview
```

Without `POSTGRES_HOST` it keeps everything in memory (and says so in the log). Point the simulator at it with launch arguments `-server http://localhost:8080 -token dev`. They're saved like Settings entries, so the app keeps using the server until Settings says otherwise.

## Configuration

**Everything below is also editable on the dashboard** (Settings, one save bar for the page), live, without a restart. The models work differently: the `MODEL_*` and `DECISION_*` variables become the entry "From install settings" on each job's list, beside the models saved there ([Models](#models-server-051)). Every other value resolves **dashboard → environment (the install settings: `budget.env` on a Mac, the app's settings / chart on an Olares) → built-in default**, and the dashboard shows where a value comes from when it isn't the default, with Reset (back to environment/default) and Turn off (an empty value, e.g. no OpenRouter key, even if the environment sets one). Dashboard values live in Postgres `budget_settings` (the `server` document, and `models` for the model lists; secrets sealed with `BUDGET_TOKEN_KEY`). API: `GET /dash/settings`, `PATCH /dash/settings {"changes": {"key": "value" | null | ""}}`. Keys: `openRouterKey`, `openRouterZeroRetention`, `syncIntervalHours`, `cardBills`, `holdings`, `plaidWebhooks`, `simplefinDailyPulls` (the last three server 0.6.0), `timeZone`, `publicURL`, `dashboardURL`, `apnsKey`, `apnsKeyID`, `apnsTeamID`, `apnsTopic`. The categorization policy (provider, auto-accept %, ask Jev when unsure) lives in the ledger and is edited through `POST /v1/actions {"type":"updateDecisionPolicy",…}` — the same call the phone makes, so dashboard and phone always agree. Plaid keys are under Accounts → Connect a bank and Settings → Bank providers (`/dash/providers`).

What stays environment-only: `HOST`, `PORT`, `DASHBOARD_PORT`, `BUDGET_API_TOKEN`, `BUDGET_TOKEN_KEY`, `POSTGRES_*`, `BUDGET_ALLOWED_ORIGINS`, `BUDGET_SEED_DEMO`, `PLAID_MOBILE_REDIRECT_URI`, `BUDGET_IOS_APP_ID`, `BUDGET_STATEMENT_ID_MIGRATION` — they decide how the server starts or who can reach it. A value the server can't read for `BUDGET_PLAID_HOLDINGS` or `BUDGET_SIMPLEFIN_DAILY_PULLS` stops it at start, with the reason in the log.

| Variable | Default | |
|---|---|---|
| `HOST`, `PORT` | `127.0.0.1`, `8080` | The chart sets `HOST=0.0.0.0` in its pod |
| `BUDGET_API_TOKEN` | — | Bearer token for `/v1`. The chart generates one |
| `BUDGET_ALLOWED_ORIGINS` | none | Comma-separated origins allowed to write from a browser |
| `POSTGRES_HOST` / `PORT` / `USER` / `PASSWORD` / `DB` | —, 5432, `budget`, —, `budget` | No host = in-memory |
| `BUDGET_TOKEN_KEY` | — | Base64, 32 bytes. Seals provider access tokens (AES-GCM). No key = linking disabled. **Losing it means relinking every account** |
| `MODEL_BASE_URL` | — | OpenAI-compatible endpoint for Ask (Qwen on the Olares). With `MODEL_API_KEY` and `MODEL_NAME`, it's the chat model "From install settings" on the dashboard's Models list |
| `DECISION_BASE_URL` | the chat model's server | server with `/v1/systemone` (Clef) for categorization; a trailing `/v1` or `/v1/decision` is ignored. When it differs from `MODEL_BASE_URL`, it's the categorizing server "From install settings" |
| `MODEL_API_KEY` | — | Bearer token for the chat model's server (a router like switchboard or LiteLLM) |
| `DECISION_API_KEY` | the chat model's key, on the chat model's server | Bearer token for the categorizing server "From install settings". When `DECISION_BASE_URL` isn't a server of its own (unset, or the same as `MODEL_BASE_URL`), it also goes to the chat model's server while the chat model in use takes its address from the install settings (0.5.0's pairing), unless 0.5.0 had it turned off. Otherwise categorizing on the chat model's server sends the chat model's key ([Keys](#models-server-051)) |
| `MODEL_NAME` | `qwen3.8-27b` | The install settings' chat model |
| `OPENROUTER_API_KEY`, `OPENROUTER_ZDR=1` | — | Enables Jev as a decision provider |
| `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV`, `PLAID_REDIRECT_URI` | —, —, `sandbox` | Both id and secret, or Plaid stays off |
| `BUDGET_PLAID_LIABILITIES` | off | `1`/`true`: read card bills from Plaid Liabilities, at most once a day per Item. Plaid bills it per Item once used; the dashboard setting "Card bills (Plaid Liabilities)" wins ([API.md](API.md#upcoming-and-card-bills)) |
| `BUDGET_PLAID_HOLDINGS` | `auto` | Investment holdings (server 0.6.0): `auto` asks only for Items Plaid already bills for Investments, `on` every Item with an investment account (may start Investments billing on the others), `off` none. `1`/`true`/`yes` read as `on`, `0`/`false`/`no` as `off`; anything else stops the server at start. Asked by the daily Item check, at most about once a day per Item ([holdings](API.md#holdings)) |
| `BUDGET_PLAID_WEBHOOKS` | on | `0`/`false`/`no` turns Plaid's webhooks off. On, they still need an https `BUDGET_PUBLIC_URL` ([webhooks](#plaid-webhooks-and-reconnect)) |
| `PLAID_MOBILE_REDIRECT_URI` | `<public URL>/plaid/oauth-return` | Where a bank's app sends the phone back after an OAuth sign-in in the phone's reconnect. Must be listed exactly in the Plaid Dashboard's allowed redirect URIs. `off` turns signing in again from the phone off in production ([reconnect](#plaid-webhooks-and-reconnect)) |
| `BUDGET_IOS_APP_ID` | — | `<TEAMID>.<bundle id>` of the app, for `/.well-known/apple-app-site-association`; without it that file is a 404 and OAuth banks can't hand the phone back to the app |
| `BUDGET_SIMPLEFIN_DAILY_PULLS` | 4 | How many times a day the server asks SimpleFIN on its own, 1–12 (anything else stops the server at start; the cap leaves room for repair and history windows and your own syncs). The server never goes past 20 requests in 24 hours, whatever this says |
| `BUDGET_STATEMENT_ID_MIGRATION` | migrate | `audit` only for a dry run on a restored copy: the 0.6.0 start counts what the statement-id upgrade would rename (`GET /dash/maintenance/statement-ids`) but changes nothing and keeps OFX imports off. Any other value, or none, upgrades ([Deploy](#deploy)) |
| `BUDGET_SYNC_INTERVAL_HOURS` | 6 | 0.25 to 24 (server 0.6.0; a larger value reads as 24). An account is stale after 2 days without a good pull, so a longer gap would make accounts read stale between syncs |
| `BUDGET_TIMEZONE` | `America/Los_Angeles` | Month boundaries |
| `BUDGET_ALLOW_DEMO` | off | `1`: this is a test server and may hold the demo ledger. Never set on the Olares |
| `BUDGET_SEED_DEMO` | off | `1`/`true`: a new ledger starts as the demo — only with `BUDGET_ALLOW_DEMO` |
| `BUDGET_PUBLIC_URL` | — | The API's public https address (never the dashboard's). Shown under "Connect your phone"; from 0.6.0 also the base of Plaid's webhook URL (`/v1/plaid/webhook`), the phone's OAuth return (`/plaid/oauth-return`) and the AASA file. Without an https one, webhooks and the phone's reconnect are off (plain http only on a Plaid sandbox test server) |
| `BUDGET_DASHBOARD_URL` | — | The dashboard's address, for the phone's "Open dashboard" (`ServerStatus.dashboardURL`) |
| `APNS_KEY`, `APNS_KEY_ID` | — | The morning summary's APNs auth key (the .p8 file's text) and its Key ID. Without both, nothing is sent |
| `APNS_TEAM_ID`, `APNS_TOPIC` | — | Your Apple Developer team and the app's bundle ID (`<your prefix>.budget`, from `Config/Local.xcconfig`). Without both, nothing is sent |

A new ledger (first start, or `/v1/admin/reset`) categorizes on the local decision model at 80% when the categorizing server in use has an address (the install settings' `DECISION_BASE_URL`, one picked in Settings → Models, or the chat model's server); otherwise the policy starts off. Either way it's a Settings choice after that.

### Models (server 0.5.1)

Settings → Models keeps several models for each job, and each job uses the one picked there:
- **Ask and planning** (and the morning summary): an OpenAI-compatible server, its key if it wants one, and a model name. The Model field lists what the server offers; where the server says which models take tools (OpenRouter does), only those, since Ask calls tools.
- **Categorizing:** a server with `/v1/systemone` (Clef) and its key; the model is always `clef`.

Add, Edit and Remove save right away; a new pick waits for the page's Save. Each job keeps up to 20, and the one in use can't be removed until another is picked (a categorizing server counts as in use only while the policy categorizes on the local model). Changes apply without a restart.

The lists also hold entries that aren't saved there and can't be edited there:
- **From install settings:** the chat model `MODEL_BASE_URL` + `MODEL_API_KEY` + `MODEL_NAME`, when `MODEL_BASE_URL` is set, and the categorizing server `DECISION_BASE_URL` + `DECISION_API_KEY`, when it's set and differs from `MODEL_BASE_URL`. Change them in the install settings (on a Mac, in `budget.env`).
- **Off** for each job, **The chat model's server** for categorizing (`/v1/systemone` on the chat model in use), and **Jev**, whose OpenRouter key and zero-retention switch stay settings.

With nothing picked, or a pick that's since been removed, Ask uses the install settings' model if there is one, else Off, and categorizing uses the install settings' server if there is one, else the chat model's server. A new chat model goes into use by itself only on a server with no chat model at all; an Off someone picked stays off. The decision policy still says which provider categorizes: picking Jev or Off in the list changes it, and picking a server sets it to the local model on that server.

**Keys** are sealed with `BUDGET_TOKEN_KEY` (without it, keys can't be saved), never sent back to the page, and only go to the server they were saved for. When an entry's address moves to another server (scheme, host or port), it needs that server's key typed in or its key removed before it saves; listing model names and Test follow the same rule. On the chat model's server, categorizing sends the chat model's key, with one exception, the pairing 0.5.0 used: it sends `DECISION_API_KEY` when that's set, `DECISION_BASE_URL` isn't a server of its own, and the chat model in use takes its address from the install settings (its "From install settings" entry, or a model imported from 0.5.0 that follows the app's address). So `DECISION_API_KEY` never goes to a chat address typed on the dashboard, nor to the chat model's server when `DECISION_BASE_URL` names another one. If 0.5.0 had `DECISION_API_KEY` turned off there (an empty key on its dashboard), the upgrade keeps it off: categorizing on the chat model's server then always sends the chat model's key (`chatServerKey: "chat"` in the `models` row).

**A chat model on OpenRouter** (0.5.2) can use Jev's key: the drawer's OpenRouter button fills in `https://openrouter.ai/api/v1`, and "Use Jev's OpenRouter key" (on by default when the entry has no key of its own) sends `useOpenRouterKey: true`. The server seals a copy of the OpenRouter key as the entry's own key, so the rollback mirror carries it like a typed one, and changing Jev's key later leaves the copy as it was (edit the entry with the switch on to take the new one). The key only goes to https on openrouter.ai: the save is refused for any other address, for a categorizing server, and when no OpenRouter key is saved; names and Test send it nowhere else. Jev's "Only providers that keep nothing" (`openRouterZeroRetention`) covers every chat request to OpenRouter too, Test's included (`provider: {zdr: true, data_collection: "deny"}`); a model with no such provider fails with a 404 that Test explains.

**Upgrading from 0.5.0** imports what its Models settings held. Each address, key and model is kept with exactly the others 0.5.0 sent it with, or dropped, except for categorizing's key on the chat model's server (the last point):
- A chat model with any part set on the dashboard (address, key or model name) becomes `migrated-chat`, named after its model and in use. A saved key keeps the same sealed string. The exception is a key or model name with no address anywhere, neither on 0.5.0's dashboard nor in the install settings: it isn't kept, and the log says so.
- A value 0.5.0 took from the install settings isn't copied. The entry inherits it: it shows "From install settings" for that field and follows their current value, so a key rotated there is used at once and no environment secret lands in the database. Typing a value in Edit replaces it. If the app stops setting it, the entry has no address and works as Off until it's edited.
- A categorizing address of its own becomes `migrated-decision`, named after its host and in use. A categorizing key saved without an address goes with the install settings' categorizing server the same way, or is dropped when there's none (the log says so).
- Ask turned off (an empty chat address) becomes the pick Off; an empty decision address, "The chat model's server". A key or name left beside an empty address isn't imported, and the log says so without the key.
- `DECISION_API_KEY` turned off (an empty decision key) while categorizing ran on the chat model's server stays off: categorizing there sends the chat model's key, as 0.5.0 did.
- Nothing set on the dashboard imports nothing, and the install settings' entries stay in use, as before.
- Categorizing on the chat model's server follows the rule in **Keys** above. Where 0.5.0 sent `DECISION_API_KEY` to a chat address typed on its dashboard, or to the chat model's server while `DECISION_BASE_URL` named another one, 0.5.1 sends the chat model's key instead.

**Storage and rollback.** The lists live in their own `budget_settings` row, `models` (`{models, inUse, mirrored, chatServerKey}`), which 0.5.0 never reads or writes. Every change to them first mirrors what each job runs into the `server` row's five 0.5.0 keys (`modelBaseURL`, `modelAPIKey`, `modelName`, `decisionBaseURL`, `decisionAPIKey`), so a rollback to 0.5.0 runs the same models, with the same keys. The mirror also follows the install settings, so each start writes it again if they changed since the last one. Each is written as:
- **A saved model:** its address, sealed key and model name. No key is written as an empty one, so 0.5.0 doesn't send the install settings' key there. A field it inherits is left out, so 0.5.0 takes it from the install settings too.
- **Off for Ask:** an empty chat address.
- **Categorizing on the chat model's server:** an empty decision address when it's picked, none when it's the default. When `DECISION_API_KEY` is set but isn't the key 0.5.1 sends there, also an empty decision key, so 0.5.0 sends the chat model's key too.
- **The install settings' entry, or no chat pick:** nothing, so 0.5.0 falls back to the environment as 0.5.1 does.
- **A categorizing server whose address came from the install settings, which no longer set one:** an empty decision key. Nothing categorizes on 0.5.1 then, but 0.5.0 can't say so and falls back to the chat model's server; it sends that server's own key there, never this entry's.

The other saved models wait in the `models` row. If 0.5.0 changes its Models settings, the next 0.5.1 start sees that the five keys differ from what it mirrored and makes that the job's pick. A change to the chat keys also reads categorizing again, because which key 0.5.0 sent to the chat model's server depended on both. It reuses a saved entry with the same address, key and model rather than adding a copy, and keeps the rest of the list. The five keys aren't dashboard settings any more: `GET /dash/settings` leaves them out and `PATCH` refuses them.

If either row can't be read at start, the log says why. The one that could be read is still used (when it's the `server` row, the models it mirrors run until a restart), but settings and model writes are refused with 503 ("Server settings didn't load, so nothing was changed. Restart the server; its log says why.") instead of saving over what's stored. The dashboard can answer while the server is still starting: a write that comes before the server starts reading its settings is refused with 503 ("The server is still starting. Try again in a moment."), and one that comes while they're being read waits for that. Routes: [API.md](API.md#models-server-051).

## Tests

```sh
cd Server && swift test                          # macOS: routes, parity, Plaid, config (Postgres suite skips)
deploy/olares/budgetapi/deploy.sh --check        # Linux on the Olares: tests with a scratch Postgres + release build; installs nothing
deploy/olares/budgetapi/deploy.sh --test         # the same tests, then deploys only if they pass
```

`--check` is the Linux gate before merging: it runs the same build-pod steps as a deploy (sources into `budget-build/swift`, `swift test` against the scratch `budget-build/pg`, then the static-stdlib release build, which is what proves the dashboard's `.embedInCode` resources compile on Linux) and stops before the installer. It works in its own folders (`~/budget-build/check-src` on the host, `/work/check` in the pod), never touches the `budgetapi` namespace, and exits non-zero when a test or the build fails.

`POSTGRES_TEST_HOST` (plus `_PORT`, `_USER`, `_PASSWORD`, `_DB`) turns the Postgres suite on anywhere; it empties the `budget_*` tables it uses.

**The demo ledger never goes near real accounts.** It's compiled into the iPhone app only for the simulator (a device starts on Connect), and the server loads it only with `BUDGET_ALLOW_DEMO=1` — which the Olares chart doesn't set, so the real server refuses `seedDemo`, ignores `BUDGET_SEED_DEMO`, and the dashboard hides its demo button. The live-server UI tests therefore run against a **local** test server:

```sh
cd Server && BUDGET_ALLOW_DEMO=1 BUDGET_SEED_DEMO=1 BUDGET_API_TOKEN=dev DASHBOARD_PORT=8081 swift run BudgetServer &
TEST_RUNNER_BUDGET_SERVER=http://localhost:8080 TEST_RUNNER_BUDGET_TOKEN=dev \
xcodebuild test -project Budget.xcodeproj -scheme Budget -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:BudgetUITests/LiveServerUITests
```

They change the ledger (a dining target), so restart the local server between runs. In the simulator, `-noDemo -resetSettings` launches the app as a phone would on first run.

## Deploy

**The app** is a `budgetapi` Olares chart (kept in your own Market repo; not in this one): the API container, its own Postgres (`postgres:16-alpine`, data under appData), an `internal` entrance, and two generated secrets — `budgetapi-secret` (`apiToken`, `tokenKey`) and `budgetapidb-secret`. Both are created once and kept across upgrades (Helm `lookup`). Settings in the Olares app page: model URL (the chat model "From the Olares app" on the dashboard), demo seed, Plaid id/secret/env, OpenRouter key.

**The binary** isn't in an image. `swift:6.2-noble-slim` runs `<appData>/budgetapi/bin/budget-api`, a static-stdlib release build. A fresh install waits in the `await-binary` init container until the file exists; the API container mounts it read-only and runs as uid 1000.

```sh
deploy/olares/budgetapi/deploy.sh    # needs OLARES_SSH and APP_NS (or deploy.env beside it); sync sources → build in budget-build/swift → install → restart → logs
```

The script keeps a `swift:6.2-noble` build pod (`budget-build/swift`) with its build cache, so a redeploy takes about a minute. It writes the binary through a short-lived pod with a hostPath to `bin/`, renames it into place, and restarts the Deployment. The strategy is `Recreate` (hostPath), so the API is down for the ~15 s restart.

**Upgrading to 0.6.0** rewrites statement-row and account ids on the first start (account numbers out of ids; migration 5 adds `budget_merges`). So that no 0.5.x pod writes old ids after that, `deploy.sh` stops `budgetapi` before the backup and the binary swap unless the Deployment's strategy is `Recreate`: it scales it to 0, waits for the pod to be gone, backs up, installs, then scales it back. That's a few seconds of API downtime. Before a deploy, optionally restore the last dump into a scratch server and start 0.6.0 there with `BUDGET_STATEMENT_ID_MIGRATION=audit` to read the counts. Never run 0.5.x against a migrated ledger and import a statement into it; roll back with the pre-deploy dump ([Roll back](#operate)).

Chart changes: bump the version in `Chart.yaml` and the three manifest fields, `helm package`, preflight, push to your Market repo, then upgrade from Market. Upgrades keep the secrets and the database.

## Dashboard

A second listener (`DASHBOARD_PORT`, 8081 in the chart) serves the dashboard plus the same `/v1` API **without a token**, and the `/dash/*` routes in [API.md](API.md) (summary, providers, settings, models, the phone's URL and token).

The page lives in `Server/Sources/BudgetServerCore/Dashboard/`: `index.html`, `tokens.css` (a one-to-one mirror of the app's DesignSystem tokens), `app.css`, and native ES modules (`app.js` shell and router, `core.js` helpers and the one `api()` request function, then one module per view: `overview.js`, `accounts.js`, `imports.js`, `review.js` (with `groups.js` and `rules.js` for two of its tabs), `settings.js`, with `providers.js` shared by Accounts and Settings). SwiftPM compiles them into the binary with `.embedInCode` (listed in `Package.swift`), so there's no build step and no resource bundle: deploy still copies one file. `Dashboard.swift` holds only the routes; `/dash/assets/{name}` serves the files with ETags, and `/` sends a Content-Security-Policy (scripts from the server and Plaid's CDN only; `frame-ancestors` allows the Olares desktop). A new file goes in both `Package.swift` and `DashboardAssets.files`.

Seven views, by hash: `#/overview` (what needs you, connection freshness, the month at a glance), `#/accounts` (by institution, with Connect a bank), `#/imports` (statements, one or many, which months each account covers, and the history with Undo), `#/review` (what's waiting for a category in groups you file at once with 5 s to undo — keys j/k, 1–3, o, /, u — duplicates, and re-checking what the model filed), `#/categories` (Categories & rules: the categories by budget type with Add a category, and the rules with their hits, disagreements and a live preview; a rule's "New category…" makes the category first), `#/assistant` (assistant memory to add, edit and forget, and Ask's kept conversations to rename or delete; reading one stays on the phone) and `#/settings`. A bank waiting for a sign-in is reconnected here: Plaid Link in update mode then `POST /v1/links/:id/sync`, SimpleFIN by trying again after fixing it on SimpleFIN Bridge. Rules sit with the categories they file under rather than in Settings, because each is saved on its own with a preview (Settings holds everything for one Save); a group's "Make a rule" in Review opens the rule drawer there, filled in. Renaming, recoloring and merging categories stay on the phone. Reading the budget itself is the phone's job. The page refreshes summary, overview and status every 30 s and redraws only what changed, never an open preview or form. It trusts that the only way to it is the `private` entrance: Olares' login at the gateway and the pod's auth sidecar (a direct in-cluster request to the service gets 401). Writes additionally need an `X-Budget-Dashboard: 1` header — which a cross-site page can't send without a CORS preflight the server never answers — and a same-origin `Origin`. The phone's listener never serves the page or `/dash/*`.

Locally: `BUDGET_API_TOKEN=dev BUDGET_ALLOW_DEMO=1 BUDGET_SEED_DEMO=1 DASHBOARD_PORT=8081 swift run BudgetServer` (it binds 127.0.0.1 unless `HOST` says otherwise), then open `http://budget.localhost:8081`.

## Operate

- **The token for the phone:** easiest from the dashboard (Settings → Connect your phone → Show). Or:
  `ssh $OLARES_SSH 'kubectl -n $APP_NS get secret budgetapi-secret -o jsonpath={.data.apiToken} | base64 -d'`.
  Paste it into Settings → API token (kept in the Keychain) with the entrance URL, and turn off the demo ledger.
- **Logs:** `kubectl -n $APP_NS logs deploy/budgetapi -c budgetapi`. Sync results, import reports and 5xx errors are logged; tokens never are.
- **Health:** `GET /health` (open). `GET /v1/status` shows the decision policy, models and links.
- **Undo an import or a sync:** `GET /v1/imports`, then `DELETE /v1/imports/{batch}`, on the dashboard's listener. From 0.6.0 the phone's token gets a 404 for the import list and for a sync's batch (it can still undo a file it imported).
- **Start over:** `POST /v1/admin/reset {"confirm":"erase my ledger"}`, with `"seedDemo":true` for the demo, on the dashboard's listener only (0.6.0). Links and import history stay.
- **What the phone's token can't do (0.6.0):** add a bank (Plaid link token and exchange, SimpleFIN claim), paste a new SimpleFIN token, remove a link, erase the ledger, list imports, run the import-duplicate sweep or undo a sync. Those routes answer 404 on the API even with the right token, so a lost phone or a leaked token can't unlink banks or wipe the ledger ([API.md](API.md#accounts-sync-and-imports-server-only)).
- **Backup:**
  `kubectl -n $APP_NS exec deploy/budgetapidb -- pg_dump -U budgetapi -d budgetapi --format=custom > budget-$(date +%F).dump`.
  Keep `budgetapi-secret` with it: the dump's access tokens are sealed with `tokenKey`.
- **Restore (not yet exercised on the Olares):** `pg_restore --clean -U budgetapi -d budgetapi` inside `budgetapidb` (pipe the dump through `kubectl exec -i`), then restart `budgetapi`. Try it once against a scratch database before you need it: `createdb -U budgetapi scratch`, restore into `-d scratch`, count `budget_rows`, `dropdb scratch`.
- **Deploys back up first:** `deploy.sh` dumps the ledger to `~/budget-backups/` on the host (and checks the dump reads back) before installing, and keeps the running binary as `bin/budget-api.prev`.
- **Roll back:** a new server may rewrite rows on its first start in a form an older one can't read (0.2.0 moved matched transfers and statement rows to their own tiers), so the old binary alone would fail to load the ledger. Restore the dump taken before the deploy, then `mv budget-api.prev budget-api` in `<appData>/budgetapi/bin` and restart `budgetapi`. From 0.2.0 on, a tier the server doesn't know loads as a model's guess instead of failing, so later rollbacks start without a restore. Rolled back from 0.5.1, 0.5.0 runs the model picked for each job and never touches the other saved models ([Models](#models-server-051)). **From 0.6.0, roll back only by restoring the dump taken before the deploy:** a 0.5.x server still starts on a 0.6.0 ledger, but it doesn't know what 0.6.0 added (account nicknames and edits, each link's Plaid and SimpleFIN state, the merge log) and drops it the next time it saves those records, without saying so.
- **Morning summary (0.4.0):**
  1. Create an APNs auth key at https://developer.apple.com/account/resources/authkeys/list with Apple Push Notifications service (APNs) on. One key works for both sandbox and production.
  2. On the dashboard, open Settings → Notifications. Paste the .p8 file's text (one line is fine) and its Key ID.
  3. On the phone, turn on Settings → Notifications → Morning summary, then tap **Send one now** to check.
  - Phones run from Xcode get sandbox tokens; TestFlight and App Store builds get production ones. The server tries the other environment once on `BadDeviceToken`.
  - The logs say when a summary went out, and when one fell back to the template (the model's reason).
- **Upgrading the server and the app:** deploy the server first, then install the app right away. The app refuses to send a rule with account, direction or amount conditions to a server older than 0.2.0 (it would drop them and save a broader rule), and an app from before 0.2.0 can't read some of the new server's rows until it's updated.

### Storage

Tables `budget_meta` (schema version), `budget_rows` (one row per transaction, indexed by date and batch), `budget_docs` (the rest of the ledger as JSONB documents: targets, rules, policy, accounts, merchant caps…), `budget_links` (sealed tokens, cursors, status), `budget_imports`, `budget_settings`, `budget_chats`, `budget_balances` (balance history) and, from 0.6.0, `budget_merges` (the merge log: every row skipped as already here, swept or merged, kept 400 days so it can be brought back). Each link keeps its newest 50 failed or warning-only sync records; older ones are pruned (a sync that wrote rows is never pruned: it's what Undo works on). A write saves only what changed, in one transaction; if the save fails, the in-memory ledger rolls back too. Loading overlays the stored documents on an empty ledger's, so a document equal to its default, or a field added by a later version, loads as the default.

## Connecting accounts

**Set up and link from the dashboard** (Connect a bank). Plaid and SimpleFIN sit side by side there, under one comparison, for the person to choose; neither is the recommended one ([INSTALL-SERVER.md §6](INSTALL-SERVER.md#6-link-banks) has the same table). Plaid keys entered there are stored in Postgres (`budget_settings`, secrets sealed with `BUDGET_TOKEN_KEY`), override the `PLAID_*` environment, and apply immediately — no restart. Plaid's **web** flow runs in the dashboard: Plaid Link (`cdn.plaid.com`), loaded only when you press Link. The public token goes straight to the server; the phone never adds a bank, so no LinkKit and no Apple Developer Program are needed to link one — register the dashboard's own URL (shown prefilled) as Plaid's redirect URI and OAuth banks return to the dashboard, which resumes Link. Signing in again from the phone (0.6.0, optional) is the one phone flow, and it needs a Universal Link and a second redirect URI ([reconnect](#plaid-webhooks-and-reconnect)). Inside the Olares desktop window the dashboard suggests opening itself in its own tab first, since bank sign-in pages don't run well in frames.

- `GET /dash/providers` — what's configured and where from (`dashboard` / `environment` / `none`); never a secret.
- `PUT /dash/providers/plaid {clientID, secret?, environment, redirectURI?}` — a missing secret keeps the saved one; redirect must be https.
- `DELETE /dash/providers/plaid` — back to the environment settings, if any.

SimpleFIN is the other tab: three steps with their links (sign up at SimpleFIN Bridge, add banks there, paste a setup token), then each bank behind the token with its state, the day's requests, and "Fix on SimpleFIN Bridge" for a bank that wants a sign-in. Removing a SimpleFIN link deletes the sealed access address; SimpleFIN has no call to revoke it, so the dashboard says to remove the app at SimpleFIN Bridge too. When SimpleFIN refuses the server's access as a whole (403 or `gen.auth`), the bank's card offers **Paste a new setup token** (`PUT /v1/links/:id/token`), which keeps the link, its accounts and history; the phone gets a push saying so. A 402 (the SimpleFIN subscription needs attention) stops every SimpleFIN bank and sends one push.

### Plaid, step by step

1. **Build against Sandbox** (free, unlimited, mock data). The old Development environment was shut down in June 2024 ([Plaid](https://plaid.com/docs/quickstart/glossary/)).
   - Set `BUDGET_PLAID_CLIENT_ID` and `BUDGET_PLAID_SECRET` in the app's Olares settings; `PLAID_ENV` stays `sandbox`.
2. **Trial plan for real data:** free, **10 production Items**, including Transactions and Investments ([billing](https://plaid.com/docs/account/billing/#trial-plans)).
   - **The cap is irreversible:** removing an Item doesn't free its slot. Each *login* is one Item, so a household with five banks uses 5. Don't burn Items testing; that's what Sandbox is for.
   - **Individuals can apply:** a Plaid engineer said you can put your own name as the legal entity ([HN, 2023](https://news.ycombinator.com/item?id=37617661); a community report, and possibly changed since).
3. **Company and app profile, then the security questionnaire,** in the Dashboard. OAuth banks need them; Trial can defer the questionnaire except for Chase ([OAuth prerequisites](https://plaid.com/docs/link/oauth/#prerequisites-for-adding-oauth-support)). Most OAuth institutions arrive within hours; **Schwab can take up to 5 business days** ([institution notes](https://plaid.com/docs/link/oauth/#institution-specific-behaviors)).
4. **Link from the dashboard** (web Plaid Link). The in-app alternative — Plaid LinkKit on iOS — would need a Universal Link redirect (paid Apple Developer Program + a domain serving `apple-app-site-association`) for OAuth banks; the web flow needs only the dashboard URL registered as a redirect URI.
5. **`days_requested: 730` at Link time** (the server sends it). It's fixed when the Item is created (the default is 90), and with irreversible Trial Items you get one shot at two years of history.
6. **Maintenance:** consent expires about yearly at some banks (Amex, Schwab and Chase among them). A sync that hits `ITEM_LOGIN_REQUIRED` marks the link `needsReauth`, and scheduled syncs skip it until it's reconnected: `/v1/links/plaid/token {linkID}` opens [update mode](https://plaid.com/docs/link/update-mode/), and when Link finishes, `POST /v1/links/{linkID}/sync` — no token exchange ([API.md](API.md#reconnecting-a-bank)).
7. **Webhooks and signing in again from the phone (server 0.6.0).** When the API has a public HTTPS address (Caddy, a Cloudflare Tunnel or Olares), Plaid's webhooks reach it at `POST /v1/plaid/webhook`; each is verified (an ES256 JWT) and only starts a sync. On a private Tailscale address Plaid can't reach the server. Either way the 6-hourly sync stays on; see [Plaid webhooks and reconnect](#plaid-webhooks-and-reconnect).

**Teller** withdrew its API in July 2026, and 0.6.0 removed it: its routes, dashboard keys, `TELLER_*` settings and mutual-TLS client are gone (a leftover `TELLER_*` setting is ignored). A Teller link stored before then still loads, so its accounts and history stay; it never syncs, and the dashboard says to remove it (only the dashboard can, like any link). Teller keys saved on the dashboard before 0.6.0 are ignored and dropped at the next provider save.

**Trying it out:** with Plaid, start in Sandbox, then the Trial plan and OAuth; with SimpleFIN, a setup token brings real data in minutes.

### Plaid webhooks and reconnect

**Webhooks (server 0.6.0).** `POST /v1/plaid/webhook` on the API port takes Plaid's webhooks with no bearer token: the signed `Plaid-Verification` JWT is its auth. It's on when `BUDGET_PLAID_WEBHOOKS` isn't `false` and `BUDGET_PUBLIC_URL` is an https address (plain http only on a sandbox test server). New Items get `<public URL>/v1/plaid/webhook` from their link token. The daily Item check moves existing Items to it with `/item/webhook/update`, and Plaid confirms the move with `WEBHOOK_UPDATE_ACKNOWLEDGED`.

- **Verified before anything is done:** `alg` must be exactly ES256, and the key comes from Plaid's `/webhook_verification_key/get` by `kid`. It's cached for a day and refused once Plaid retires it. `iat` must be at most 5 minutes old, and the SHA-256 of the raw body must match `request_body_sha256`.
  - A forged request can't make the server call Plaid freely. Header and `kid` shape are checked first. An unknown `kid` is remembered for a minute. Key fetches are capped at one per 10 seconds and 30 an hour, and over the cap the answer is 503.
  - Answers: 400 for no header or a body that isn't a webhook, 401 for a bad signature, key, time or hash, 413 above 64 KiB, and 503 when the key can't be fetched (Plaid retries a 5xx for a day).
  - Nothing from a refused request is logged, only the reason and a count. A verified one logs its type, code and link, never its body or a token in it.
- **A webhook is only a trigger.** The route answers 200 at once and queues the work per Item, in memory:
  - `SYNC_UPDATES_AVAILABLE` → a sync, at most one per Item a minute. It still won't ask for a link that was revoked or has refused three sign-ins.
  - `ITEM` `ERROR`, `PENDING_DISCONNECT`, `PENDING_EXPIRATION`, `LOGIN_REPAIRED`, `USER_PERMISSION_REVOKED`, `USER_ACCOUNT_REVOKED` and `NEW_ACCOUNTS_AVAILABLE` → `/item/get`. `PENDING_DISCONNECT` also notes the week's warning.
  - `HOLDINGS` `DEFAULT_UPDATE` → holdings due at that check.
  - `LIABILITIES` `DEFAULT_UPDATE` → card bills again, with Card bills on, at most every 6 hours.
- **The schedule stays on with webhooks.** The 6-hourly sync and the daily Item check aren't polling in place of webhooks. They're the reconcile Plaid asks for: a restart empties the queue, and Plaid drops a delivery after a day of retries.
- **Where to see it:** Accounts → a Plaid bank → ⋯ → Details → Webhooks: "On · confirmed by Plaid" once `WEBHOOK_UPDATE_ACKNOWLEDGED` came, with the last one to arrive; "Registered · waiting for Plaid to confirm" before that; "Off" when the server has no https public URL.

**The daily Item check.** Every 15 minutes the server looks for Plaid Items whose last `/item/get` is a day old (± an hour) and asks Plaid about each, one at a time in that Item's turn. It records the Item's error (a null error heals a link that was waiting for a sign-in and syncs it once), `consent_expiration_time`, the products it's billed for, and its `institution_id`, and moves the Item to this server's webhook URL when it has another. Holdings are fetched there too, once a day, when `BUDGET_PLAID_HOLDINGS` is `on`, or `auto` (the default) with the Item already billed for Investments.

**Consent running out.** Some banks (Amex, Schwab and Chase among them) end the access they gave Plaid after about a year. From 14 days before `consent_expiration_time` (or before the week a `PENDING_DISCONNECT` webhook gives, when that ends sooner), the dashboard shows a banner, "Harbor access ends in 9 days", with **Renew access**, and the phone gets a push at about 14 and 7 days. Renewing is Plaid's update mode on the same Item with `update.reauthorization_enabled`, from either place: same Item, same accounts and history, nothing exchanged, and no Plaid Item used up. Finishing it clears a PENDING_DISCONNECT warning. On the dashboard, the sync after Link says update mode finished (`afterUpdateMode`), which also makes the Item due its check, so the renewed consent date is read within 15 minutes and the banner goes unless the bank's new date is itself within 14 days. The phone's renewal reads the date at once: its `/item/get` runs when Link finishes.

**Signing in again from the phone** (`POST /v1/links/:id/reconnect`, [API.md](API.md#reconnect)). The phone opens Plaid's Hosted Link in update mode in an in-app browser. It works when the server has Plaid set up, `BUDGET_TOKEN_KEY`, an https `BUDGET_PUBLIC_URL`, and a mobile redirect:
- `PLAID_MOBILE_REDIRECT_URI` defaults to `<public URL>/plaid/oauth-return`, served by the API port with `/.well-known/apple-app-site-association` (built from `BUDGET_IOS_APP_ID`, `<TEAMID>.<bundle id>`). OAuth banks (Chase, Amex, Schwab…) return through that Universal Link. Add the URI to Plaid's allowed redirect URIs in the Plaid Dashboard; until it's there, the phone gets a 422 that names it.
- `PLAID_MOBILE_REDIRECT_URI=off` turns the phone flow off in production (links then say to reconnect on the dashboard). A sandbox test server falls back to `PLAID_REDIRECT_URI` with `is_mobile_app: false`.
- Hosted Link must be enabled for the Plaid account. Whether the Trial plan has it isn't confirmed yet; the first real call says.
- Update mode only: the phone can never start a new Item, change which accounts an Item shares, or ask for another product's consent. Each link allows one live session (reused while more than 5 minutes are left), 5 starts an hour and 10 a day. The session lives in memory; a restart drops it and the phone starts again.

**One Item per bank.** Each new Item is billed on its own, and on the Trial plan it's one of 10 lifetime slots. A second Item at a bank also brings every account in again under new ids. So the dashboard won't make one at a bank that already has a working Plaid link: picking that bank in Plaid Link closes Link with "Chase is already linked. Use Reconnect on it instead…", and the server refuses `POST /v1/links/plaid/exchange` with 409, before exchanging, by the same rule. Plaid's `institution_id` decides when both sides have it (Link gives it; the daily Item check stores the link's), else the bank's name. A link whose Item is gone (`ITEM_NOT_FOUND`) or whose access was withdrawn doesn't count: **Link again** on its card opens Plaid Link for a new Item, the one case where that's the way back. That new Item brings every account in again, under new account ids and with up to two years of history, next to the old link's accounts, which keep theirs. Nothing carries accounts over from the old link yet, and duplicates are matched by account, so until the old accounts are hidden or merged into the new ones the overlap counts twice (removing the old connection keeps its accounts and rows, so it doesn't help). Two separate logins at the same bank can't both be linked through Plaid this way; use statements or SimpleFIN for the second. Not confirmed yet: whether a public token the server refuses (and so never exchanges) still uses up a Trial slot; Plaid's guidance suggests it doesn't.

### Olares and Plaid (server 0.6.0)

What has to be true outside the server for webhooks and the phone's reconnect to work. The server can't check most of it; the dashboard's Webhooks line and the phone's 422 messages say when something is missing.

1. **The API entrance passes three paths through without the Olares login.** The `public` API entrance already reaches `/v1` with only the bearer token. Plaid and Apple carry no token, so these must reach the pod as they are:
   - `POST /v1/plaid/webhook`, with the `Plaid-Verification` header intact (the signed JWT is its auth);
   - `GET /.well-known/apple-app-site-association` (Apple fetches it to trust the Universal Link);
   - `GET /plaid/oauth-return` (where a bank's app hands the phone back).
   Check each answers from outside with a status code, not the Olares login page: the AASA file 200 (404 without `BUDGET_IOS_APP_ID`), the webhook 400 to an empty POST. Any other reverse proxy in front of the API (Caddy, a Cloudflare Tunnel) needs the same three paths.
2. **`publicURL` is the API's address.** Settings → Server URL for the phone (or `BUDGET_PUBLIC_URL`) must be the public https API entrance (`https://<appid>0.<you>.olares.com`), not the dashboard's (`<appid>1`). Webhooks, the mobile redirect and the AASA file all hang off it; pointed at the dashboard, Plaid's deliveries hit a login page.
3. **Plaid's allowed redirect URIs.** In the Plaid Dashboard (https://dashboard.plaid.com/team/api), add `https://<API host>/plaid/oauth-return` exactly, no query and no trailing slash, for Production (and Sandbox, to test it there). Keep the dashboard's own redirect URI: new links still use it. Until it's listed, the phone's Reconnect gets a 422 that names the URI.
4. **The app's side:** the Associated Domains capability on the app's identifier at https://developer.apple.com/account/resources/identifiers/list, and `BUDGET_API_HOST` (the API's host name, no scheme) in `Config/Local.xcconfig` before building. Without it the build has no `applinks` entitlement and the phone points to the dashboard instead ([INSTALL-APP.md](INSTALL-APP.md)).

After the first 0.6.0 start with all of this in place, the daily Item check moves each Plaid Item to the new webhook URL; each should show "On · confirmed by Plaid" on its Details within a day.

## Backfill

Measured on the Olares: Qwen `/v1/decision` batched runs at **15.6 decisions/s**. Merchant memory collapses repeats: the demo's 345 rows are 36 unique descriptors (10%); real households are likely higher, maybe 20–30% (an estimate). Two years at about 200 transactions a month is about 4,800 rows, or roughly 1,000–1,500 first decisions:
- **Qwen:** about 1–2 minutes.
- **Jev:** about a minute at 4 concurrent, about $0.05–0.07, using decision-bench's $0.044 per 1,000.

What the pipeline does (`Categorizer`, built):
1. **Decide per unique normalized descriptor, not per row.** It's about 5–10× fewer calls, it sends Jev far less, and every other row inherits the answer through merchant memory.
2. **Priors first:** your rules, then merchant memory. Plaid's `personal_finance_category` (and a statement's category column) is kept on each row as a hint. Skipping the model when they're VERY_HIGH and cleanly mapped needs an eval first.
3. **Batching:** Qwen up to 256 states per request with `cache_prompt`. Jev at bounded concurrency with 429/5xx backoff (default 4).
4. **Idempotent batches.** Rows are deduplicated by provider id, then across sources, and every sync or file is one batch you can roll back.
5. **Don't flood review.** At 80%, about 9% of unique descriptors (100+) need you. Grouping review by merchant and sorting by money involved is still to do.

Measured through the deployed server (2026-09-25):
- **The file import path:** 6 new rows became 4 model calls, and the decisions came back in under a second.
- **What got filed automatically:** Blue Bottle and Park Cafe → dining, city parking → transport, each at ≥ 99.7%.
- **What was held back:** "UNITED … HOUSTON" came back at 31% and went to review, since the descriptor had lost "airlines".
