# Design system: "Lit Charcoal"

Derived from a *midnight gallery* idea: a cool near-black room lit from above and in front, like the glow in the app icon. Numbers are set in a quiet serif, and saturated colour shows up only where it means something: category panels, data signals, the assistant. Code: `Packages/BudgetCore/Sources/DesignSystem`. Live catalog: Settings → Advanced → Design system (or launch with `-gallery`); its Effects and States pages show every recipe and control state side by side.

## Principles

1. **One light source.** The light sits above and in front of the screen. Cards are lit along their top edge and are slightly brighter at the top. Depth comes from shade and light, never from drop shadows; only floating layers (toasts, menus, the segmented thumb) cast one.
2. **Colour means something.** Cyan is data: lines, money in, focus, toggles, links. Iris is the assistant. Orchid is caution, and it always comes with a glyph or a tag. Amber means "watch". The 12 tones are categories. Nothing is coloured just for decoration.
3. **White is commitment.** White fills are reserved for the primary button and selected chips.
4. **Muted, not faded.** Dim things by dropping one ink tier, never with opacity. Disabled controls too: they use `inkDisabled`.
5. **Saturated, never dusty.** Tone hexes don't change. Gloss may brighten a tone; nothing may grey it.
6. **Show the math's provenance.** Any ledger-computed figure can carry a `DSToolTrace` naming the tool that produced it. This is the design-level expression of "the model never does math."

## Tokens

### Surfaces, back to front

| Token | Value | Use |
|---|---|---|
| `canvasDeep` | `#050607` | Field wells, the segmented track, code |
| `canvas` | `#08090B` | Screen and sheet background |
| `surface` | `#121418`, drawn as a gradient from `#16181D` (`DSFill.surface`) | Cards, list sections, chips |
| `surfaceRaised` | `#1B1D22`, from `#1F2227` (`DSFill.raised`) | Raised cards, the ask field, user bubbles |
| `surfaceOverlay` | `#24272D` | Toasts, menus, the segmented thumb. Never a field here |
| `surfacePressed` | `#2B2E35` | Pressed rows and tiles |

The neutrals have a slight cool cast (blue a few steps above red). The canvas-to-card step is 1.08, enough to read as depth without borders.

### Lines

| Token | Value | Use |
|---|---|---|
| `divider` | white 5% | Row separators, dividers inside cards, chart grid |
| `hairline` | white 8% | Flat outlines, the bottom of the lit edge |
| `hairlineStrong` | white 14% | Chip and progress tracks |
| `fieldBorder` | `#6B6E76`, opaque | Text fields: at least 3:1 on canvasDeep, canvas, surface and raised (not the overlay, 2.9) |

### Ink

| Token | Value | Use |
|---|---|---|
| `ink` / `inkSoft` | `#FFFFFF` / `#F2F3F5` | Headlines, numbers / answer prose |
| `inkSecondary` | `#AEB1B8` | Body, descriptions, eyebrows. AA on every layer |
| `inkTertiary` | `#888B93` | Captions, provenance. AA up to `surfaceRaised`; never on the overlay, pressed or caution-wash layers |
| `inkDisabled` | `#56595F` | Disabled labels only (WCAG exempts them; never carries information) |
| `inkInverse` | `#08090B` | On white, pearl, cyan and iris fills |

### Accents and states

| Token | Value | Use |
|---|---|---|
| `accent` / `inflow` | `#00B3DD` | Data lines, money in, focus, links |
| `iris` | `#847DFF` | The assistant, projections |
| `caution` | `#EF72E3` orchid | Over target, needs review |
| `cautionFill` / `cautionFillPressed` | `#B0309F` / `#9A2A8B` | Destructive fills under white labels |
| `pearl` / `pearlPressed` | `#E4E7EB` / `#D5D9DF` | The primary button's ramp |
| `DSState` | hover 4%, pressed 8%, selected 10% white; focus ring 1.5pt + 3pt halo at 24% | Interaction states, laid over any control |

Tones (`DSTone`): iris `#847DFF`, lilac `#D08FFF`, orchid `#EF72E3`, azure `#5AA0FF`, cyan `#00B3DD`, irisDeep `#4B49AA`, amber `#FFB42E`, coral `#FF7A59`, rose `#FF5C8A`, teal `#14C7B4`, lime `#B8E62E`, violet `#9B5CFF`. Each tone carries its own on-fill ink and an on-canvas foreground (irisDeep lifts to iris, violet to `#AE80FF`). Washes come in four strengths (`DSWash`): tag 12%, glyph 16%, bloom 18%, edge 28%; text sits only on the 12% wash, over canvas or surface. A category stores its colour as the tone's token name (`DSTone(token:)` / `.token`), never a hex value; `DSTone.swatches` is the picker order, around the colour wheel.

**Revision (2026-09-25):** pale tints (pale iris `#D1C9FF`, periwinkle `#90B8F0`, orchid `#DD90D8`, silver `#CACACA`) read dusty next to the saturated iris, cyan and irisDeep. They were replaced with saturated tones at the same weight. Amber is the one warm tone: a neutral gray can't be made un-dusty, since a gray is exactly what a desaturated color is. Black text still clears AA on every tile (tested).

**Revision (2026-09-26):** five tones added so each default category owns a colour: health rose, travel teal, fees coral, utilities lime, transfer violet (the app's `CategoryStyle`). None is a pure red or green, and all take black ink at AA or better.

**Revision (2026-10-08), Lit Charcoal:** the neutral ladder went deeper and cooler, and gained an overlay layer and a pressed step one notch above it. Cards gained the lit edge and fill; fields, a segmented control, more button variants and an icon button joined the system. Tertiary ink was lifted again (now AA on raised cards), and violet text lifts to `#AE80FF`, since violet itself is 4.3:1 on a raised card.

**Contrast is tested.** `DesignSystemTests/ContrastTests` checks every ink on every ladder step it may sit on, the field border at 3:1, inverse ink on every fill, each tone's foreground on its own wash, tile ink through the gloss, and secondary ink on the caution wash and screen blooms.

**No bright green or red.** Money in is cyan with a `+`; money out is plain white. Spending trends use `inkSecondary` with an arrow, no hue. "Over" uses orchid, but never orchid alone: orchid is also the Dining tone. `DSProgressBar` notches at the target with a white tick, `DSMonthBars` marks over months with an exclamation mark, `DSArcGauge` shows an "Over" tag, and rows add `DSTag.over()`.

## Light and gradients (`Tokens/Effects.swift`)

All static. The only motion is the AI edge breathing while the model works, which holds still under Reduce Motion.

| ID | Recipe | Where |
|---|---|---|
| G1 lit edge | `.dsLitEdge(radius:)`: 1pt, white 12% → 5% → 4% top to bottom (`.strong`: 16%) | Cards, toasts, ask field, secondary and icon buttons, segmented thumb |
| G2 lit fill | `DSFill.surface` / `.raised` | `DSCard`, `.dsPanel()` |
| G3 tone bloom | radial from the top-leading corner, tone at 18% | `DSCard(tone:)`, `DSInsightCard`, notices (14%), toasts (12%) |
| G4 caution wash | caution 18% down to clear at 55% | Checkup sections to act on, caution notices. Always with words |
| G5 screen bloom | `.dsScreenBackground(bloom: .data / .ai)`: cyan 10% or iris 14% above the top edge | Home and Plan (data), Ask (AI). One per screen |
| G6 pearl | `DSFill.pearl`, white → `#E4E7EB`; pressed flat `#D5D9DF` | Primary button only |
| G7 AI edge | `.dsAIEdge(_:isWorking:)`: iris → violet → lilac, never cyan | Pending proposals, the ask field while working, `.ai` buttons, `DSAskButton` |
| G8 AI aura | iris 12% rising from the bottom-trailing corner | Pending `DSActionCard` |
| G9 tile gloss | `DSTileFill`: white 14% fading by 45% plus an inner top stroke; irisDeep caps at 10% | `DSCategoryTile`, `DSIconTile` from 36pt |
| G10 chart line | area cyan 26% → 8% → 0; the line casts a cyan glow | `DSLineChart` |
| G11 progress fill | tint at 85% → full | `DSProgressBar`, `DSArcGauge` |
| G12 edge fade | canvas from clear over 32pt; `.scrollEdgeEffectStyle(.soft, for: .top)` on the main scroll views | Ask composer, tab screens |

Not adopted: rotating or conic borders, comets, glows on cards, dot grids, drop shadows on cards.

## Type

| Style | Face | Size / weight / tracking |
|---|---|---|
| `displayXL` / `amountXL` | New York (serif) | 56 light, −1.4. The hero keeps proportional figures and rolls its digits |
| `display` | New York | 40 light, −0.9 |
| `title` / `amount` | New York | 28 regular, −0.3 (light goes thin at 28 on OLED) |
| `headline` | New York | 20 regular, −0.2 |
| `body` / `bodyEmphasis` / `amountRow` | SF Pro | 16 regular / medium / medium tabular |
| `callout` / `calloutEmphasis` | SF Pro | 14 regular / medium |
| `label` | SF Pro | 13 medium: field and segment labels |
| `caption` | SF Pro | 12 |
| `eyebrow` | SF Mono | 11 medium, uppercase, +1.3; sans caption at accessibility sizes |
| `mono` | SF Mono | 12 medium, tool traces and descriptors |
| `code` | SF Mono | 14 regular tabular: tokens, URLs, keys |
| `axis` | SF Mono | 11 regular tabular: chart axes |

System faces only — no bundled fonts — so Dynamic Type and optical sizes work and nothing needs a licence. SF gets no extra tracking (it has optical tracking built in). Every style scales through `@ScaledMetric`; apply with `.dsFont(_:)`. `DSHeroAmount` sets its cents superior: 0.58× the dollars, lifted 0.36×, in `inkSecondary`.

## Shape, size and space

- Radius (soft rectangles, never pills): 6 tags · 10 glyphs · 12 buttons, chips, fields · 13 picker rings · 20 cards · 30 category tiles · icon tiles a quarter of their side (`DSRadius.iconTile(side:)`). The ask field and bubbles keep 16.
- Sizes (`DSSize`): 44 hit target, 52 list row, 48 field, buttons 52 / 44 / 32 (inside 44), chips 36, segmented 40, icon buttons 36. Icon glyphs: `DSIconSize` 12 / 14 / 17 / 20 / 22.
- Motion (`DSMotion`): standard snappy 0.28, gentle 0.45, press 0.12, focus 0.16, breathe 1.4.
- Space: 4pt base; rhythm 8 / 12 / 16 / 24 / 32 / 48; 20pt page gutter.

## Components

| Component | Purpose |
|---|---|
| `DSCard`, `DSCardHeader`, `.dsPanel()` | Lit charcoal panel, flat or raised, no shadow; `tone:` blooms it, `wash:` adds caution or the assistant's light. The header is an eyebrow, an optional chevron and a divider |
| `DSEyebrow`, `DSSectionHeader`, `DSDivider` | Labels and structure |
| `DSHeroAmount` | Serif hero number with superior cents and a digit roll |
| `DSAmountText`, `DSStatBlock`, `DSFigureRow` | Amounts in running UI |
| `DSLineChart` | Actual (cyan) + projected (dashed iris) + range band + goal rule |
| `DSCategoryTile` | Chromatic, glossed 30pt panel for top categories; press with `.dsPress` |
| `DSTransactionRow`, `DSGlyph` | Ledger lines with tone-washed category glyph |
| `DSConfidenceBadge` | Auto / Likely / Decided / Review, for provenance views. Rows don't carry it: review is the orchid dot, and how a row was filed (tier, model, how sure) is in its details |
| `DSInsightCard` | "Found for you" card that blooms in its tone, with a provenance footer |
| `DSToolTrace` | `ƒ(x) sumByCategory(range: "2026-Q3")` |
| `DSPrivacyBadge` | On your server / Aggregates only / Offline copy / Demo |
| `DSAskField`, `DSUserBubble`, `DSThinkingLine` | Conversation surface. The ask field is a raised lit panel, rings in iris when focused and breathes the AI edge while working |
| `DSField` (`.boxed` / `.inline` / `.search`, `isCode`) | Label above, an engraved well with an opaque border, helper or error below; cyan ring and halo on focus, caution ring and glyph on error, `inkDisabled` when disabled, a lock when read-only. `.inline` is a list row with a cyan leading bar on focus. Wraps any input, so `SecureField`, paste buttons and formatted amounts keep their own modifiers |
| `DSAmountField` | A big amount entry: serif, superior "$", an underline that turns cyan on focus |
| `DSSegmented` | A recessed track with a lit charcoal key that slides to the choice; a menu at accessibility sizes |
| `DSButtonStyle` (`.ds(.primary, size:, fullWidth:, isLoading:)`) | primary (pearl), secondary (lit slab), tinted (cyan wash), ai (iris wash, AI edge, sparkle), quiet, destructive, destructiveArmed, glass; sizes large / regular / compact. Disabled is a faint fill and `inkDisabled`, never a fade; loading keeps the width |
| `DSIconButton`, `.dsPress` | A 36pt lit round key in a 44pt hit area (glass when floating); press feedback for custom tappable views |
| `DSChip`, `DSTag`, `DSFlowLayout` | Controls. Chips are 36pt rounded rectangles (never capsules): white when selected, a tone wash for a category filter. At accessibility text sizes `DSTag` speaks in the sans callout voice instead of the uppercase monospace, so a tag wraps between words instead of mid-word |
| `DSStateView`, `.dsLoading` | Empty, error and offline states |
| `DSActionCard` | Assistant proposal: AI edge and aura while pending, Apply as the `.ai` button, ledger-computed effects, tool trace, Apply / Not now, then Applied / Dismissed / Didn't apply |
| "Filed by the model" | No per-row badge for what the decision model accepted on its own: Activity has a quick filter (and a Filters toggle) that lists exactly those rows to check or overrule, and each row's details say which model filed it and how sure it was |
| `DSTransactionRow` (v2) | `emphasis: .muted`, `isHidden` (eye-slash tag), `needsReview` (orchid dot); VoiceOver appends the statuses. The app's `LedgerRow` mutes rows that don't count (`LedgerTransaction.isCounted`), and its subtitle is "Category · Gold Card ••1008" in Activity (grouped by day) or "Category · Today" elsewhere; `Account.shortLabel` is the one way the app names an account |
| `DSListRow`, `DSListValue`, `DSToggleRow`, `DSIconTile` | Settings and detail lines, 52pt minimum; icon tiles use the tone's own ink |
| `.dsGroupedList()`, `DSListSection` | The one skin for settings-style `List`s: canvas, rows on flat `surface` with 5% separators, eyebrow headers |
| `DSNoticeCard`, `DSAttentionPill` | Something that needs you: a lit card washed in its tint (caution washes down from the top) with one action, or a one-line pill |
| `DSToast`, `.dsToast($toast)` | Brief confirmation on the overlay layer with its shadow: Undo, a countdown line and a VoiceOver announcement |
| `DSChipLabel` | A chip's look without the button, for `Menu` labels |
| `DSSwatchGrid`, `DSSymbolGrid`, `DSSymbol.budgetCategories` | Category colour and icon pickers (48 curated symbols) |
| `DSAskButton` | Sparkle icon button that opens Ask about one card; breathes the AI edge while working |
| `DSMonthSwitcher` | `‹ September 2026 ›`, stops at the current month |
| `DSWeekStrip`, `DSArcGauge` | Seven-day spending cells; the 270° flexible-budget gauge |
| `DSMonthBars`, `DSCashFlowChart` | A category month by month against its target; money in and out with the net line |

## Layering rule

`DesignSystem` knows nothing about money models, and `BudgetKit` knows nothing about SwiftUI. The app's `Bridges.swift` maps one onto the other (category → tone, categorization → confidence). This keeps the design system reusable and the wire models portable to the server.
