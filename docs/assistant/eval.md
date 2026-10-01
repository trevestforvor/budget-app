# Categorization eval: decision models

`categorize-v1`: 64 realistic US bank descriptors with gold labels and acceptable alternatives (`Sources/budget-assistant/Eval.swift`). Seven are marked *ambiguous*: a careful human couldn't call them from the descriptor alone (PayPal, Zelle, Venmo, ATM, insurance). Run with `swift run budget-assistant eval --provider qwen|jev|<shim URL> [--repeat N]`. Run 2026-09-25 against a self-hosted Qwen (before the eval's place names were made generic).

| Path | Accuracy | ECE | Filed at 80% (wrong) | Filed at 95% (wrong) | Mean conf. clear / ambiguous | Speed |
|---|---|---|---|---|---|---|
| **Jev 1.13** via OpenRouter | 100% | 0.058 | 89% (0) | 69% (0) | 94% / 93% | **28.7/s** at 4 concurrent |
| Qwen3.8-27B, `/v1/decision` direct (batched) | 98% | 0.056 | 91% (0) | 75% (0) | 95% / **87%** | 12.4/s single batch; 15.6/s over 512 |
| Qwen via jevshim, `system2: off` | 100% | 0.053 | 92% (0) | 75% (0) | 95% / **88%** | 9.8/s at 4 concurrent |
| Qwen via jevshim, `system2: auto` (the shim default) | 100% | 0.022 | **100%** (0) | 83% (0) | 98% / **98%** | 4.7/s |

## What it says

- **Every path is accurate on this set and none filed a wrong answer at 80%.** 98% vs 100% is a single item (Petco, which direct `/v1/decision` scored health at 59%: below the threshold, so it would have gone to review).
- **Jev is the fastest** (28.7/s at 4 concurrent; about $0.003 for this run at decision-bench's measured $0.044 per 1,000) and is calibrated like Qwen. But it barely separates ambiguous from clear descriptors (93% vs 94%). Qwen direct does separate them (87% vs 95%), which matters because those are the items review exists for.
- **The shim's system-2 pass is what makes it different.** Below 0.8 top probability, it has the chat model write a short worked analysis ending in "Answer: X", then re-scores with that analysis in the context. The second score mostly measures agreement with its own conclusion. That helps where reasoning adds information (dates and arithmetic, the JevBench hard tier it was tuned on). For categorization the missing information is simply absent (PayPal hides the merchant), so reasoning only commits: ambiguous items go from 88% to 98%, and at 80% nothing reaches review. With `system2: off`, the shim matches direct `/v1/decision`. `DecisionModels.make(.localDecide, …)` now sends `system2: off` through the shim.

## Caveats

64 items is small, and the labels are one person's calls with lenient alternatives. The real eval set is your own corrections: every review you answer becomes a labeled example (intent principle 4), and the role gate should rerun on those.
