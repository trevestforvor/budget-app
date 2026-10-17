# Budget API server

The always-on half of the app: a Swift server (Hummingbird 2) on the Olares that owns the ledger, syncs accounts, runs the agent loop on the local model, and answers the iPhone app. It links `BudgetKit` directly, so the server and the demo run the same tested engine (`LedgerBudgetAPI` over `Ledger`). Routes: [API.md](API.md).

**Where it runs:** anywhere Swift runs (macOS 26+ or Linux), with Postgres. On a Mac that stays on, `deploy/macos/install.sh` installs it as a launchd service; anywhere with Docker, `deploy/docker/compose.yaml` runs it with Postgres and daily backups ([INSTALL-SERVER.md](INSTALL-SERVER.md), or `./setup.sh server`). On an Olares box it's the `budgetapi` app, with two entrances:
- **API** (the phone): `https://<appid>0.<you>.olares.com`, `public` (reachable from anywhere, no VPN and no Olares login; the bearer token on `/v1` is the lock). No launcher tile.
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
    AHCTransport.swift              HTTPTransport over AsyncHTTPClient (+ mutual TLS for Teller)
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

**Everything below is also editable on the dashboard** (Settings, one save bar for the page), live, without a restart. The models work differently: the `MODEL_*` and `DECISION_*` variables become the entry "From install settings" on each job's list, beside the models saved there ([Models](#models-server-051)). Every other value resolves **dashboard → environment (the install settings: `budget.env` on a Mac, the app's settings / chart on an Olares) → built-in default**, and the dashboard shows where a value comes from when it isn't the default, with Reset (back to environment/default) and Turn off (an empty value, e.g. no OpenRouter key, even if the environment sets one). Dashboard values live in Postgres `budget_settings` (the `server` document, and `models` for the model lists; secrets sealed with `BUDGET_TOKEN_KEY`). API: `GET /dash/settings`, `PATCH /dash/settings {"changes": {"key": "value" | null | ""}}`. Keys: `openRouterKey`, `openRouterZeroRetention`, `syncIntervalHours`, `cardBills`, `timeZone`, `publicURL`, `dashboardURL`, `apnsKey`, `apnsKeyID`, `apnsTeamID`, `apnsTopic`. The categorization policy (provider, auto-accept %, ask Jev when unsure) lives in the ledger and is edited through `POST /v1/actions {"type":"updateDecisionPolicy",…}` — the same call the phone makes, so dashboard and phone always agree. Plaid/Teller keys are under Accounts → Connect a bank and Settings → Bank providers (`/dash/providers`).

What stays environment-only: `HOST`, `PORT`, `DASHBOARD_PORT`, `BUDGET_API_TOKEN`, `BUDGET_TOKEN_KEY`, `POSTGRES_*`, `BUDGET_ALLOWED_ORIGINS`, `BUDGET_SEED_DEMO` — they decide how the server starts or who can reach it.

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
| `TELLER_CERT_PATH`, `TELLER_KEY_PATH` | — | PEM files from `teller.zip` |
| `BUDGET_SYNC_INTERVAL_HOURS` | 6 | |
| `BUDGET_TIMEZONE` | `America/Los_Angeles` | Month boundaries |
| `BUDGET_ALLOW_DEMO` | off | `1`: this is a test server and may hold the demo ledger. Never set on the Olares |
| `BUDGET_SEED_DEMO` | off | `1`/`true`: a new ledger starts as the demo — only with `BUDGET_ALLOW_DEMO` |
| `BUDGET_PUBLIC_URL` | — | Shown in Settings → status |
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

Chart changes: bump the version in `Chart.yaml` and the three manifest fields, `helm package`, preflight, push to your Market repo, then upgrade from Market. Upgrades keep the secrets and the database.

## Dashboard

A second listener (`DASHBOARD_PORT`, 8081 in the chart) serves the dashboard plus the same `/v1` API **without a token**, and the `/dash/*` routes in [API.md](API.md) (summary, providers, settings, models, the phone's URL and token).

The page lives in `Server/Sources/BudgetServerCore/Dashboard/`: `index.html`, `tokens.css` (a one-to-one mirror of the app's DesignSystem tokens), `app.css`, and native ES modules (`app.js` shell and router, `core.js` helpers and the one `api()` request function, then one module per view: `overview.js`, `accounts.js`, `imports.js`, `review.js` (with `groups.js` and `rules.js` for two of its tabs), `settings.js`, with `providers.js` shared by Accounts and Settings). SwiftPM compiles them into the binary with `.embedInCode` (listed in `Package.swift`), so there's no build step and no resource bundle: deploy still copies one file. `Dashboard.swift` holds only the routes; `/dash/assets/{name}` serves the files with ETags, and `/` sends a Content-Security-Policy (scripts from the server and the Plaid/Teller CDNs only; `frame-ancestors` allows the Olares desktop). A new file goes in both `Package.swift` and `DashboardAssets.files`.

Seven views, by hash: `#/overview` (what needs you, connection freshness, the month at a glance), `#/accounts` (by institution, with Connect a bank), `#/imports` (statements, one or many, which months each account covers, and the history with Undo), `#/review` (what's waiting for a category in groups you file at once with 5 s to undo — keys j/k, 1–3, o, /, u — duplicates, and re-checking what the model filed), `#/categories` (Categories & rules: the categories by budget type with Add a category, and the rules with their hits, disagreements and a live preview; a rule's "New category…" makes the category first), `#/assistant` (assistant memory to add, edit and forget, and Ask's kept conversations to rename or delete; reading one stays on the phone) and `#/settings`. A bank waiting for a sign-in is reconnected here: Plaid Link in update mode then `POST /v1/links/:id/sync`, Teller Connect for the same enrollment then `PUT /v1/links/:id/token`, SimpleFIN by trying again after fixing it on SimpleFIN Bridge. Rules sit with the categories they file under rather than in Settings, because each is saved on its own with a preview (Settings holds everything for one Save); a group's "Make a rule" in Review opens the rule drawer there, filled in. Renaming, recoloring and merging categories stay on the phone. Reading the budget itself is the phone's job. The page refreshes summary, overview and status every 30 s and redraws only what changed, never an open preview or form. It trusts that the only way to it is the `private` entrance: Olares' login at the gateway and the pod's auth sidecar (a direct in-cluster request to the service gets 401). Writes additionally need an `X-Budget-Dashboard: 1` header — which a cross-site page can't send without a CORS preflight the server never answers — and a same-origin `Origin`. The phone's listener never serves the page or `/dash/*`.

Locally: `BUDGET_API_TOKEN=dev BUDGET_ALLOW_DEMO=1 BUDGET_SEED_DEMO=1 DASHBOARD_PORT=8081 swift run BudgetServer` (it binds 127.0.0.1 unless `HOST` says otherwise), then open `http://budget.localhost:8081`.

## Operate

- **The token for the phone:** easiest from the dashboard (Settings → Connect your phone → Show). Or:
  `ssh $OLARES_SSH 'kubectl -n $APP_NS get secret budgetapi-secret -o jsonpath={.data.apiToken} | base64 -d'`.
  Paste it into Settings → API token (kept in the Keychain) with the entrance URL, and turn off the demo ledger.
- **Logs:** `kubectl -n $APP_NS logs deploy/budgetapi -c budgetapi`. Sync results, import reports and 5xx errors are logged; tokens never are.
- **Health:** `GET /health` (open). `GET /v1/status` shows the decision policy, models and links.
- **Undo an import or a sync:** `GET /v1/imports`, then `DELETE /v1/imports/{batch}`.
- **Start over:** `POST /v1/admin/reset {"confirm":"erase my ledger"}`, with `"seedDemo":true` for the demo. Links and import history stay.
- **Backup:**
  `kubectl -n $APP_NS exec deploy/budgetapidb -- pg_dump -U budgetapi -d budgetapi --format=custom > budget-$(date +%F).dump`.
  Keep `budgetapi-secret` with it: the dump's access tokens are sealed with `tokenKey`.
- **Restore (not yet exercised on the Olares):** `pg_restore --clean -U budgetapi -d budgetapi` inside `budgetapidb` (pipe the dump through `kubectl exec -i`), then restart `budgetapi`. Try it once against a scratch database before you need it: `createdb -U budgetapi scratch`, restore into `-d scratch`, count `budget_rows`, `dropdb scratch`.
- **Deploys back up first:** `deploy.sh` dumps the ledger to `~/budget-backups/` on the host (and checks the dump reads back) before installing, and keeps the running binary as `bin/budget-api.prev`.
- **Roll back:** a new server may rewrite rows on its first start in a form an older one can't read (0.2.0 moved matched transfers and statement rows to their own tiers), so the old binary alone would fail to load the ledger. Restore the dump taken before the deploy, then `mv budget-api.prev budget-api` in `<appData>/budgetapi/bin` and restart `budgetapi`. From 0.2.0 on, a tier the server doesn't know loads as a model's guess instead of failing, so later rollbacks start without a restore. Rolled back from 0.5.1, 0.5.0 runs the model picked for each job and never touches the other saved models ([Models](#models-server-051)).
- **Morning summary (0.4.0):**
  1. Create an APNs auth key at https://developer.apple.com/account/resources/authkeys/list with Apple Push Notifications service (APNs) on. One key works for both sandbox and production.
  2. On the dashboard, open Settings → Notifications. Paste the .p8 file's text (one line is fine) and its Key ID.
  3. On the phone, turn on Settings → Notifications → Morning summary, then tap **Send one now** to check.
  - Phones run from Xcode get sandbox tokens; TestFlight and App Store builds get production ones. The server tries the other environment once on `BadDeviceToken`.
  - The logs say when a summary went out, and when one fell back to the template (the model's reason).
- **Upgrading the server and the app:** deploy the server first, then install the app right away. The app refuses to send a rule with account, direction or amount conditions to a server older than 0.2.0 (it would drop them and save a broader rule), and an app from before 0.2.0 can't read some of the new server's rows until it's updated.

### Storage

Tables `budget_meta` (schema version), `budget_rows` (one row per transaction, indexed by date and batch), `budget_docs` (the rest of the ledger as JSONB documents: targets, rules, policy, accounts, merchant caps…), `budget_links` (sealed tokens, cursors, status) and `budget_imports`. A write saves only what changed, in one transaction; if the save fails, the in-memory ledger rolls back too. Loading overlays the stored documents on an empty ledger's, so a document equal to its default, or a field added by a later version, loads as the default.

## Connecting accounts

**Set up and link from the dashboard** (Connect a bank). Plaid and Teller keys entered there are stored in Postgres (`budget_settings`, secrets sealed with `BUDGET_TOKEN_KEY`), override the `PLAID_*` / `TELLER_*` environment, and apply immediately — no restart. Linking runs each provider's **web** flow in the dashboard: Plaid Link (`cdn.plaid.com`) and Teller Connect (`cdn.teller.io`), loaded only when you press Link. The public token / access token goes straight to the server; the phone is never involved, so no LinkKit, no Universal Link, and no Apple Developer Program for OAuth banks — register the dashboard's own URL (shown prefilled) as Plaid's redirect URI and OAuth banks return to the dashboard, which resumes Link. Inside the Olares desktop window the dashboard suggests opening itself in its own tab first, since bank sign-in pages don't run well in frames.

- `GET /dash/providers` — what's configured and where from (`dashboard` / `environment` / `none`); never a secret.
- `PUT /dash/providers/plaid {clientID, secret?, environment, redirectURI?}` — a missing secret keeps the saved one; redirect must be https.
- `PUT /dash/providers/teller {applicationID, environment, certificatePEM?, keyPEM?}` — sandbox needs no certificate; development/production require both PEMs, parsed before saving.
- `DELETE /dash/providers/plaid|teller` — back to the environment settings, if any.

SimpleFIN is on the same card (paste a setup token). Not verified yet: a real Plaid or Teller link — that needs your keys.

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
7. **No webhooks.** They need a public HTTPS endpoint; polling `/transactions/sync` on a schedule is explicitly acceptable ([Plaid](https://plaid.com/docs/transactions/webhooks/)), which keeps the server off the public internet.

### Teller

Teller stopped taking new customers in July 2026; this is for an existing Teller account. A new setup uses Plaid or SimpleFIN.


1. **Sign up** to get `teller.zip` (client certificate and key). **Development** is real data, free, and capped at **100 enrollments**; mTLS is required ([environments](https://teller.io/docs/guides/environments)).
   - Upload `certificate.pem` and `private_key.pem` on the dashboard (Connect a bank → Teller); the server builds its mTLS client from them (AsyncHTTPClient). Unverified against real Teller until you have the files.
2. **Teller Connect runs in the dashboard** (`connect.js`); `onSuccess` returns `{accessToken, enrollment:{id, institution}}` ([Connect](https://teller.io/docs/guides/connect)), which goes to `/v1/links/teller` once; the server seals it.
3. **Sandbox first:** Teller's sandbox tokens work without a certificate, so the whole flow can be tried with only an application ID.
4. **Repairs:** a disconnected enrollment (credentials or MFA) is fixed by reopening Connect with `enrollmentId`.

**Suggested order:** SimpleFIN (paste a setup token, real data in minutes) or Plaid Sandbox, then the Plaid Trial plan and OAuth.

### Plaid webhooks and reconnect

Not built yet (server 0.6.0).

## Backfill

Measured on the Olares: Qwen `/v1/decision` batched runs at **15.6 decisions/s**. Merchant memory collapses repeats: the demo's 345 rows are 36 unique descriptors (10%); real households are likely higher, maybe 20–30% (an estimate). Two years at about 200 transactions a month is about 4,800 rows, or roughly 1,000–1,500 first decisions:
- **Qwen:** about 1–2 minutes.
- **Jev:** about a minute at 4 concurrent, about $0.05–0.07, using decision-bench's $0.044 per 1,000.

What the pipeline does (`Categorizer`, built):
1. **Decide per unique normalized descriptor, not per row.** It's about 5–10× fewer calls, it sends Jev far less, and every other row inherits the answer through merchant memory.
2. **Priors first:** your rules, then merchant memory. Plaid's `personal_finance_category` and Teller's `details.category` are kept on each row as hints. Skipping the model when they're VERY_HIGH and cleanly mapped needs an eval first.
3. **Batching:** Qwen up to 256 states per request with `cache_prompt`. Jev at bounded concurrency with 429/5xx backoff (default 4).
4. **Idempotent batches.** Rows are deduplicated by provider id, then across sources, and every sync or file is one batch you can roll back.
5. **Don't flood review.** At 80%, about 9% of unique descriptors (100+) need you. Grouping review by merchant and sorting by money involved is still to do.

Measured through the deployed server (2026-09-25):
- **The file import path:** 6 new rows became 4 model calls, and the decisions came back in under a second.
- **What got filed automatically:** Blue Bottle and Park Cafe → dining, city parking → transport, each at ≥ 99.7%.
- **What was held back:** "UNITED … HOUSTON" came back at 31% and went to review, since the descriptor had lost "airlines".
