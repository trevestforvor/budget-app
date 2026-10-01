# Design system

Modeled on Origin's iOS app: *a midnight gallery of quiet wealth.* The room is a near-black canvas, the numbers are whisper-weight serif, and saturated color shows up only as category panels and data signals. Code: `Packages/BudgetCore/Sources/DesignSystem`. Live catalog: Settings → Advanced → Design system (or launch with `-gallery`).

## Principles

1. **Depth from shade, not borders.** Five near-black layers (`canvasDeep` → `surfacePressed`) do the separating; borders are 8% white hairlines.
2. **Three voices.** Serif light for emotive statements and headline numbers, sans for UI, uppercase mono for labels and data provenance.
3. **One primary action.** White fill, black ink, trailing arrow. Cyan is for data and inflow; violet is for AI and emphasis.
4. **Color is a panel, not a paint.** Chromatic tones fill category tiles (30pt radius) and chart series. Nothing else is saturated.
5. **Show the math's provenance.** Any ledger-computed figure can carry a `DSToolTrace` naming the tool that produced it. This is the design-level expression of "the model never does math."

## Tokens

| Token | Value | Use |
|---|---|---|
| `canvas` | `#0F1011` Obsidian | Screen background |
| `canvasDeep` | `#090A0B` Abyss | Stacked sections |
| `surface` | `#161718` | Cards |
| `surfaceRaised` | `#1F2022` | Emphasized cards, input, user bubbles |
| `surfacePressed` | `#3F4041` Steel | Pressed states |
| `ink` / `inkSoft` | `#FFFFFF` / `#F5F5F7` | Headlines, numbers / answer prose |
| `inkSecondary` | `#9F9FA0` Ash | Body and descriptions |
| `inkTertiary` | `#808182` | Captions, provenance |
| `accent` / `inflow` | `#00B3DD` Cyan Signal | Data lines, money in, links |
| `iris` | `#847DFF` | AI surface, projections |
| `caution` | `#EF72E3` Orchid | Over target, needs review |

Tones (`DSTone`): iris `#847DFF`, lilac `#D08FFF`, orchid `#EF72E3`, azure `#5AA0FF`, cyan `#00B3DD`, irisDeep `#4B49AA`, amber `#FFB42E`, coral `#FF7A59`, rose `#FF5C8A`, teal `#14C7B4`, lime `#B8E62E`, violet `#9B5CFF`. Each tone carries its own on-fill ink and an on-canvas foreground. A category stores its colour as the tone's token name (`DSTone(token:)` / `.token`), never a hex value; `DSTone.swatches` is the picker order, around the colour wheel.

**Revision (2026-09-25):** Origin's pale tints (pale iris `#D1C9FF`, periwinkle `#90B8F0`, orchid `#DD90D8`, silver `#CACACA`) read dusty next to the saturated iris, cyan and irisDeep. They were replaced with saturated tones at the same weight. Amber is the one warm tone, a deliberate break from Origin's all-cool palette: a neutral gray can't be made un-dusty, since a gray is exactly what a desaturated color is. Black text still clears AA on every tile (tested).

**Revision (2026-09-26):** five tones added so each default category owns a colour: health rose, travel teal, fees coral, utilities lime, transfer violet (the app's `CategoryStyle`). None is a pure red or green, and all take black ink at AA or better.

**Deliberate deviation:** Origin's "Fog" `#6A6B6B` is only 3.5:1 on the canvas. Tertiary ink is lifted to `#808182` (≥4.5:1 on canvas and surface). `DesignSystemTests` enforces AA contrast for every ink and tile pairing.

**No bright green or red.** Money in is cyan with a `+`; money out is plain white. "Over" uses orchid, but never orchid alone: orchid is also the Dining tone. `DSProgressBar` notches at the target with a white tick, `DSMonthBars` marks over months with an exclamation mark, `DSArcGauge` shows an "Over" tag, and rows add `DSTag.over()`.

**Muted, not faded.** Rows that don't count toward spending (transfers, hidden rows) switch to secondary and tertiary ink. Lowering opacity would drop the subtitle below AA.

## Type

| Style | Face | Size / weight |
|---|---|---|
| `displayXL` / `amountXL` | New York (serif) | 56 light, −1.2 tracking |
| `display` | New York | 40 light |
| `title` / `amount` | New York | 28 light |
| `headline` | New York | 20 regular |
| `body` / `bodyEmphasis` | SF Pro | 16 regular / medium |
| `callout` / `caption` | SF Pro | 14 / 12 |
| `eyebrow` | SF Mono | 11 medium, uppercase, +1.1 tracking |
| `mono` | SF Mono | 12 medium, tool traces and descriptors |

The system faces stand in for Lyon Display, Suisse Int'l and Roboto Mono, so there's no licensing and Dynamic Type works. Every style scales through `@ScaledMetric`; apply with `.dsFont(_:)`.

## Shape and space

- Radius: 4 tags · 8 buttons, chips, inputs · 16 cards · 30 category tiles. Rectangular discipline, no pill cards.
- Space: 4pt base; rhythm 8 / 12 / 16 / 24 / 32 / 48; 20pt page gutter.

## Components

| Component | Purpose |
|---|---|
| `DSCard` | Charcoal panel, hairline border, flat or raised |
| `DSEyebrow`, `DSSectionHeader`, `DSDivider` | Labels and structure |
| `DSHeroAmount` | Serif hero number with lowered-contrast cents |
| `DSAmountText`, `DSStatBlock`, `DSFigureRow` | Amounts in running UI |
| `DSLineChart` | Actual (cyan) + projected (dashed iris) + range band + goal rule |
| `DSCategoryTile` | Chromatic 30pt panel for top categories |
| `DSTransactionRow`, `DSGlyph` | Ledger lines with tone-washed category glyph |
| `DSConfidenceBadge` | Auto / Likely / Decided / Review, for provenance views. Rows don't carry it: review is the orchid dot, and how a row was filed (tier, model, how sure) is in its details |
| `DSInsightCard` | Origin-style "found for you" card with provenance footer |
| `DSToolTrace` | `ƒ(x) sumByCategory(range: "2026-Q3")` |
| `DSPrivacyBadge` | On your Olares / Aggregates only / Offline copy / Demo |
| `DSAskField`, `DSUserBubble`, `DSThinkingLine` | Conversation surface |
| `DSButtonStyle` (`.ds(.primary)`…), `DSChip`, `DSTag`, `DSFlowLayout` | Controls. At accessibility text sizes `DSTag` speaks in the sans callout voice instead of the uppercase monospace, so a tag wraps between words instead of mid-word |
| `DSStateView`, `.dsLoading` | Empty, error and offline states |
| `DSActionCard` | Assistant proposal: iris-edged while pending, ledger-computed effects, tool trace, Apply / Not now, then Applied / Dismissed / Didn't apply |
| "Filed by the model" | No per-row badge for what the decision model accepted on its own: Activity has a quick filter (and a Filters toggle) that lists exactly those rows to check or overrule, and each row's details say which model filed it and how sure it was |
| `DSTransactionRow` (v2) | `emphasis: .muted`, `isHidden` (eye-slash tag), `needsReview` (orchid dot); VoiceOver appends the statuses. The app's `LedgerRow` mutes rows that don't count (`LedgerTransaction.isCounted`), and its subtitle is "Category · Gold Card ••1008" in Activity (grouped by day) or "Category · Today" elsewhere; `Account.shortLabel` is the one way the app names an account |
| `DSListRow`, `DSListValue`, `DSToggleRow`, `DSIconTile` | Settings and detail lines, 52pt minimum; icon tiles use the tone's own ink |
| `.dsGroupedList()`, `DSListSection` | The one skin for settings-style `List`s: canvas, rows on `surface`, eyebrow headers |
| `DSNoticeCard`, `DSAttentionPill` | Something that needs you: a tinted card with one action, or a one-line pill |
| `DSToast`, `.dsToast($toast)` | Brief confirmation with Undo, a countdown line and a VoiceOver announcement |
| `DSChipLabel` | A chip's look without the button, for `Menu` labels |
| `DSSwatchGrid`, `DSSymbolGrid`, `DSSymbol.budgetCategories` | Category colour and icon pickers (48 curated symbols) |
| `DSAskButton` | Sparkle button that opens Ask about one card |
| `DSMonthSwitcher` | `‹ September 2026 ›`, stops at the current month |
| `DSWeekStrip`, `DSArcGauge` | Seven-day spending cells; the 270° flexible-budget gauge |
| `DSMonthBars`, `DSCashFlowChart` | A category month by month against its target; money in and out with the net line |

## Layering rule

`DesignSystem` knows nothing about money models, and `BudgetKit` knows nothing about SwiftUI. The app's `Bridges.swift` maps one onto the other (category → tone, categorization → confidence). This keeps the design system reusable and the wire models portable to the server.
