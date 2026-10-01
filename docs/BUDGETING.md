# Budgeting method

Researched 2026-09-25 for a low-effort, automated app whose questions are near-term: "How much can I save?", "How much should I save?", "What's my DoorDash budget?"

## Chosen: pay yourself first + flex budgeting + safe to spend

1. **Pay yourself first.** A monthly savings amount comes off the top. It's either your plan (`setMonthlySavings`) or, until you set one, what the ledger sees you already move to savings ($500/mo in the demo).
2. **Three buckets: bills, subscriptions, everyday.** Every counted charge is one of them.
   - A merchant on the Recurring list counts as its kind, a **bill** or a **subscription** (you can change it on Recurring), whatever its category: a gym filed under Health is a subscription. Anything else counts as its category's type (`BudgetCategory.group`): Housing, Utilities and Fees & interest are bills, Subscriptions is subscriptions, and the rest is **everyday** (groceries, dining, shopping, transport, travel, health visits).
   - `everyday budget (flex number) = expected income − bills − subscriptions − savings`. Bills and subscriptions are a usual month: the last 3 months' average.
   - **Expected income** is the lower of two figures (server 0.3.3):
     - the last 3 months' average income;
     - a month of the latest paychecks: the last two for pay every two weeks or twice a month, the last one for monthly pay, the last four for weekly.
     The average alone ran high whenever one of its months had a third biweekly paycheck, a bonus or a refund. Say an average of $8,400 from a quarter with a three-paycheck month, against $7,700 from the last two paychecks.
     A paycheck is income of $100 or more filed under Income. Its parts count together when they land in different accounts within three days, so a split deposit reads as one whatever the bank named each part. Paydays have to keep a regular cadence. Interest is too small to count, and a deposit well between paydays (a bonus, a reimbursement) isn't one. With no regular pay (freelance, say), the average stands.
   - **Spread over the year** (an annual card fee, a yearly plan, a trip you choose to spread) counts a twelfth a month for twelve months, from its own month, in its bucket, instead of all at once in its month and in the usual month after. A charge is spread when you say so on it, when its merchant repeats yearly (found, or set by you on Recurring), or when its description says annual. It keeps its category.
   - This replaced Monarch-style fixed / flexible / non-monthly groups ([Monarch's flex budgeting](https://help.monarch.com/hc/en-us/articles/32125337244052-Using-Flex-Budgeting)) in 0.3.0: two of those said what spending is and the third how often it comes, and a yearly subscription was both. Stored categories read fixed as Bills (Subscriptions as Subscriptions, Health as Everyday) and flexible and non-monthly as Everyday.
   - **Expected income** is everything filed under a money-in category: Income (pay, interest) and any category you make with kind `moneyIn`, like "Card rewards" for statement credits, offers and points back. Money in is never spending and never budgeted, so it's in no bucket. Money coming in on a credit card is never pay: a card payment or a refund isn't filed as Income on its own (see [API.md](API.md#institutions)), so it can't inflate expected income.
3. **Safe to spend** = the everyday budget − everyday spending so far this month (a spread charge counting its twelfth). Home leads with it. The same idea appears as Simplifi's "available to spend" ([Simplifi](https://support.simplifi.quicken.com/en/articles/4212702-understanding-your-spending-plan)) and Copilot's "free to spend" ([Copilot](https://help.copilot.money/en/articles/6045480-dashboard-tab-overview)).
4. **Category targets and merchant caps are optional**, layered on top for the things you want to watch. They're flagged, never blocking.

### Why this over the alternatives

| Method | Verdict for this app |
|---|---|
| Zero-based / envelope (YNAB) | Too much effort. Every dollar is assigned by hand, and the measured gains show up for engaged users ([Financial Health Network](https://finhealthnetwork.org/research/ynab-helping-users-make-smarter-spending-decisions-with-money-labeling/)); automation works against it |
| 50/30/20 | A good source of targets (20% savings), not an in-month tracker. Used for guidance |
| Category targets | Kept as an optional layer; the app already had them |
| Pay yourself first alone | Lowest effort, but it can't answer "why did I overspend?" Used as step 1 |
| Flex budgeting + safe to spend | Designed for auto-categorized feeds; one number to watch. **Chosen** |

## "How much can I save?" (`savingsCapacity`)

`typical = average income − spending` over the last 3 complete months as it actually went out (so it matches Plan's cash flow; a spread charge counts whole in its month here), income being everything money-in categories took in. `stretch` is the same, with everyday spending held to its lowest month of the three. The tool also reports what you already move to savings, and how many months of essentials (fixed + groceries + transport) your cash covers. In the demo (as of September 25, 2026) average income is $7,740: $7,700 of pay and $40 a month of Card rewards credits.

## Plan's forecast (`projectBalance`)

Plan projects **cash after cards**: cash (checking and savings) less what's owed on cards. It moves forward at the last 3 complete months' average **income − spending**, spending as the budget counts it, so a charge spread over the year counts a twelfth a month. The chart's actual line is the same measure, so the two lines meet.

This replaced a projection of cash alone at the pace cash itself moved (server 0.3.1). Card bills land a month after the spending, so one month of big payoffs set the pace. One month of large card payoffs could make the forecast say cash was shrinking by thousands a month, even while income beat spending in the months around it. Counting spending when it's made, and starting from cash less card balances, keeps a payoff from moving either number. What cash itself did is still on the Cash flow card (`averageCashChange`), next to income less spending.

Money moved to an investment account isn't spending, so the pace doesn't count it, but it does leave cash. Someone who invests every month would see the forecast run ahead of their cash.

## "How much should I save?" (`savingsGuidance`)

Rules of thumb, each stated with its source and computed against your numbers:
- **Emergency fund:** 3–6 months of essential expenses for income shocks; about half a month covers spending shocks ([Vanguard](https://investor.vanguard.com/investor-resources-education/emergency-fund)). The CFPB treats emergency savings as a core metric but sets no month count.
- **Savings rate:** 20% of after-tax income under 50/30/20 (Warren & Tyagi, *All Your Worth*). Fidelity says 15% of pre-tax income for retirement, including any employer match ([Fidelity](https://www.fidelity.com/viewpoints/retirement/how-much-money-should-I-save)). Payroll 401(k) contributions don't show in the ledger (paychecks arrive net), so the 15% can't be checked from here, and the tool says so.
- **Order:** starter emergency fund → full employer match → high-interest debt → 3–6 month fund → retirement toward 15% → other goals. This is common practice, not a single source, and it's presented that way.

## "What's my DoorDash budget?" (`sumByMerchant`, `setMerchantTarget`)

Research found no mainstream personal-finance app with a native per-merchant cap. They approximate one with a merchant rule plus a sub-category target ([Monarch rules](https://help.monarch.com/hc/en-us/articles/360048393372-Transaction-Rules)). This app caps merchants directly, which is simpler for this question. `sumByMerchant` returns this period's total and order count, the 3-month monthly average, and the cap if one is set. `setMerchantTarget` proposes a cap, and Spending shows caps with progress.
