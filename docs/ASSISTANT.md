# Assistant and decision model

The `chat` model answers questions and can control the app. A separate decision model (Jev-style) files uncertain transactions. Both run on the server; the phone renders their output. Code lives in `Packages/BudgetCore/Sources/BudgetKit/Assistant` and `.../Decisions`.

## System prompt

The demo ledger calls no model, so it has no prompt. Its answers are templated around tool results. The prompt the server gives the `chat` role is `AssistantPrompt.system(context)`, version `chat-2026-10-09.1`. It's rendered per request with today's date, the time zone, the live category list with targets, and assistant memory. A rendered copy is in [assistant/system-prompt.md](assistant/system-prompt.md), and the app shows the live one under Settings → Assistant → System prompt.

The prompt carries the rules a schema can't express:
- **Numbers come from the ledger.** Every amount, difference, percentage and projection must appear in a tool result. For comparisons, the model calls `sumByCategory` with `compareTo` instead of subtracting.
- **Writes are proposals.** The model describes what a card will do and never claims a change happened.
- **Relative edits go through `adjustCategoryTarget`** with the change exactly as the user stated it.
- **Ask when ambiguous**, with one short question.
- **Money in counts as income**: the category list marks Income and any category like card rewards "money in"; `sumByCategory` returns what one received, never spending.
- **Read-only**: no moving money. Describe what the ledger shows; no investment, tax or legal advice.
- **Style**: two or three sentences. Figures and proposals render as their own cards.
- **Assistant memory**: facts the person asked Ask to keep in mind ("Saving for a trip to Lisbon in March"), newest first, in their own section capped at about 2,000 characters. The section says they're background, not ledger data. The model proposes a new one with `rememberFact` when asked to remember something or told something later conversations need, never a figure from a tool and never a budget change (that's a target).

## Tools

The single source of truth is `ToolCatalog`. The server sends its OpenAI-compatible `tools` array to the model, validates every call against the same schemas, and returns validation messages written so the model can repair its call. Exported copies: [tools.openai.json](assistant/tools.openai.json) and [catalog.json](assistant/catalog.json). Regenerate them with `cd Packages/BudgetCore && swift run budget-assistant tools|prompt|catalog`.

| Kind | Tools | What happens |
|---|---|---|
| read | `queryTransactions` (with `spent` and `income`, the Activity summary's totals), `sumByCategory` (with optional `compareTo`), `sumByMerchant`, `merchantSummary` (one merchant: this month, the last 12 months and all time, how often, the average charge, recurring and cap), `topMerchants` (where the user goes most, or spends most, in a period), `projectBalance`, `flexBudget`, `cashFlow` (income against spending by month, as Plan shows it), `categoryHistory` (one category month by month), `savingsCapacity`, `savingsGuidance`, `categorize`, `findRules`, `sumByTag` (one tag with spending by category, or every tag; `queryTransactions` also takes a `tag` and lists each row's tags) | Runs on the ledger; the result goes back to the model. Every "Ask about this" question in the app lands on one of these |
| write | `setCategoryTarget`, `adjustCategoryTarget`, `removeCategoryTarget`, `setMerchantTarget`, `removeMerchantTarget`, `setMonthlySavings`, `createCategory`, `updateCategory`, `mergeCategory`, `createBudgetRule`, `updateBudgetRule`, `deleteBudgetRule`, `recategorize`, `editTransactions` (also `addTags`, `removeTags`, and `fileSimilar` to file the rest from a merchant), `updateDecisionPolicy`, `rememberFact` (assistant memory) | Becomes a `ProposedAction` card with ledger-computed before/after effects. Nothing changes until the user taps Apply |
| client | `navigate` | A card that opens a screen (including `recurring`) focused on a category, budget month, range, search or horizon |

Schema rules, chosen so constrained decoders (llama.cpp grammars, vLLM/SGLang guided decoding) can enforce them:
- No `oneOf`, `anyOf` or `$ref`; `additionalProperties: false` everywhere. "At least one field" is expressed as `minProperties`.
- Amounts are decimal strings (`"500"`, `"-25.50"`), so the model never converts units. Percentages are whole integers (`80`), not fractions.
- `categoryID` is narrowed per request to the live categories, and to spending categories only for the three target tools, so an invalid ID can't be generated.

### One write path

`AppAction` (a `{"type": <tool>, ...args}` object) is the only way anything changes. The assistant's proposals, the Spending screen's target editor, and Settings → Decision model all call `AppModel.perform(_:)`, which sends `POST /v1/actions`. The server runs the same validation for all three. `DemoLedger+Actions.swift` shows the two server steps: `preview` produces the card's effects, and `perform` makes the change.

## Agent loop (live)

`AgentLoop` (in `BudgetKit/Agent`, shared with the future server) is the loop the intent describes:
1. The system prompt and narrowed tool schemas go to an OpenAI-compatible model (`OpenAIChatModel`), with per-request thinking control (`chat_template_kwargs.enable_thinking`: off for chat, on for plan). Inline `<think>` blocks are stripped.
2. **Read** calls run through an `AgentToolbox`: `DemoToolbox` over the demo ledger now, Postgres on the server later. Money comes back in one en_US format, so grounding can match it.
3. **Write and client** calls become proposals; the model is told a card was shown and nothing changed.
4. **Invalid arguments** come back as `{"error", "problems", "fix"}` for the model to repair (counted as `repairs`).
5. **The final prose is grounded** against every tool result (this turn's and those replayed from earlier in the conversation), the prompt without assistant memory, and the person's questions. An ungrounded figure gets one rewrite request; anything still ungrounded is reported in `AgentOutcome.ungrounded`.

Verified live against `qwen3.8-27b`: 7 questions, every figure grounded, zero repairs, 1.6–5.6 s each. In an earlier raw probe without schema patterns, the model wrote `period: "Q3 2026"`. The pattern and description in the real schema fixed that, and the repair path covers it if it recurs.

The app can run "demo ledger + live model" (Settings → Assistant model, or launch with `-live`). The agent loop then runs on the phone. That's a dev bridge until the server exists, not the intended thin-client shape.

## Conversations

Every question is kept in chat history (`ChatSessionStore`: Postgres on the server, memory in the demo; API in [API.md](API.md#assistant-memory-and-chat-history)). Asking with a conversation's id continues it: `LedgerBudgetAPI.ask` hands `AgentLoop` the latest six turns as history, the two newest with their tool calls and results, within about 16,000 characters. A grounding retry (the draft and the "[system check]" note) isn't kept. Grounding counts the replayed tool results and the person's earlier questions, never the model's earlier prose: an answer it gave before isn't a source. The app's Ask hub lists Recents (Today, then Older); opening one shows its turns and continues it.

## Grounding

`Grounding.ungroundedAmounts` and `ungroundedPercents` find figures in model prose that no tool returned. A whole-dollar mention is accepted if it's the nearest-dollar rounding of a tool value. The server should reject or regenerate a reply that has any. Tests run this over every demo reply; it has already caught one real bug, where the demo stated a total that wasn't among its figures.

## Decision model

A decision model reads a state and answers typed questions with probabilities, without writing text (`choice`, `noul` = yes/no, `score`).

**One pathway: Jev's `/v1/systemone`.** The self-hosted decision server on the Olares (Cloudflare Clef, the `llamacppqwen3827bdecide` app) serves it natively, as does Laya. So Jev, Clef and Laya differ only by base URL, model and key. `DecisionModels.make(provider, endpoints)` builds the client. The server ignores the `model` field (the app sends `clef`), answers all of a request's questions jointly in one pass, takes one state per call (the client runs several in parallel), and rejects input over about 4096 tokens with a 413, which the client marks as a failed item rather than stopping the batch. The old `/v1/decision` endpoint is gone; saved addresses ending in `/v1/decision` or `/v1` are normalized to the server root.

Wire formats, as measured in a separate decision-model benchmark:

| Provider | Endpoint | Where it runs | Notes from the benchmark |
|---|---|---|---|
| `localDecide` | Cloudflare Clef, `POST /v1/systemone` (Jev shape), one state per call | Olares GPU | Returns the full distribution; $0. Earlier measurements below were taken on Qwen Decide's retired `/v1/decision` |
| `laya` | `POST /v1/systemone` | Olares CPU | Collapses past about 20 options; not recommended for categories |
| `jev` | OpenRouter `https://openrouter.ai/api/alpha/decisions` (`typesafe/jev-1.13`) or TypeSafe `https://api.typesafe.ai/v1/systemone` (`jev-latest`) | Cloud | Full distribution; about $0.04 per 1,000 decisions |

**Policy** (`DecisionPolicy`): provider (default `off`), `autoAcceptPercent` (default 80, allowed 50–99), decision kinds, and `escalateToJev`. With escalation on, a local provider answers first, and anything below the threshold is re-asked to Jev. Jev's answer is accepted only if it also clears the threshold; otherwise the item comes to you. In the demo, local at 80% accepts 3 of 7 and escalation accepts 2 more (Amazon and Venmo), leaving PayPal and CVS for you. Category decisions come first; subscriptions and transfers are categories, so they're covered. Changes go through `updateDecisionPolicy`, from Settings or from Ask ("turn on the decision model at 80%").

**Outcome** (`CategoryDecisions.outcome`): at or above the threshold, the decision is accepted as tier "Decision model" and records the model and confidence. Activity's **Filed by the model** filter lists these rows, their details say which model filed them and how sure it was, and you can change them like any other row. Below the threshold, it goes to review with the model's ranked suggestions. Applying a policy re-checks everything waiting for review and reports the result, e.g. "Auto-accepted 3 of 11 waiting; 8 still need you."

**Measured on the live model (2026-09-25):** Qwen Decide is very confident. At 80% it auto-accepted all 7 demo items, including PayPal as a transfer at 92–96% with the real merchant hidden. At 95% it accepted 5 and sent PayPal and CVS (93%) to review. **For Qwen Decide, use 95%.** Adding a `processor` hint to the request (Toast means restaurant, PayPal means merchant hidden) moved "TST* LOCAL 123" from shopping at 31% to dining at 100%.

**Calibration matters more than accuracy here.** A threshold only means something if the model's confidence is honest. The benchmark shows Qwen and Jev with a calibration error around 0.07–0.09 and Gemma about twice that. Before assigning a model, run the role's evals and check that items it scores at 80%+ are really right about 80%+ of the time.

### What Jev receives, and what's known about retention

Jev is a first-class option, and it only sees a place name and a category question. The app treats it as a disclosure, not a warning. Settings → Decision model → "What the decision model sees" shows the exact JSON the server sends for a real transaction, so anyone can weigh it themselves.

Each uncertain transaction sends (`CategoryDecisions.request`):
- **Sent:** the merchant name, a descriptor with processor prefixes and digits stripped, the direction, an amount band ("$10–50"), and the category options.
- **Never sent:** account, date, exact amount, transaction ID.
- **People are redacted**, following Jev's own "send less" guidance: `VENMO *J. PARK` becomes `VENMO`, `ZELLE TO JOHN SMITH` becomes `ZELLE TO`, and emails are removed.
- **Answers map back by request position** on the server, so no ID is sent.
- **API keys stay on the server.** The phone never calls a decision model.

Retention facts, checked 2026-09-25:
- **TypeSafe** says it "will not train or fine tune any artificial intelligence or machine learning models on your prompts or other Input" ([typesafe.ai/privacy](https://www.typesafe.ai/privacy), updated Nov 19, 2025). Retention isn't a fixed window: data is kept "as long as reasonably necessary" and deleted on request. **No zero-data-retention commitment was found**, so "probably zero retention" isn't confirmed. No training is confirmed.
- **OpenRouter** serves Jev with TypeSafe as the only provider ([openrouter.ai/typesafe/jev-1.13](https://openrouter.ai/typesafe/jev-1.13)). Its provider routing supports `zdr: true` and `data_collection: "deny"` per request, or account-wide in privacy settings ([provider routing](https://openrouter.ai/docs/features/provider-routing), [privacy](https://openrouter.ai/docs/features/privacy-and-logging)). Jev wasn't confirmed as ZDR-listed.
- `.openRouter(apiKey:, zeroDataRetention: true)` sends `provider: {zdr: true, data_collection: "deny", allow_fallbacks: false}`, so the request fails rather than landing somewhere that retains data. Try it on the first call: if Jev isn't ZDR-listed, those requests will fail, and the choice is between Jev without ZDR and local Qwen Decide. It's also unconfirmed whether the alpha Decisions endpoint honors provider routing at all.
- **Data processing agreements:** only relevant once other people's data is involved.
