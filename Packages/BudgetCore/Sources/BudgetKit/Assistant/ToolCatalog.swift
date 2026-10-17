import Foundation

public enum ToolKind: String, Hashable, Sendable, Codable {
    /// Runs on the server against the ledger; results go back to the model.
    case read
    /// Produces a proposal the person must apply. Never executes on its own.
    case write
    /// Produces a proposal the device handles (navigation). Never reaches the server.
    case client
}

/// A tool as the chat model sees it (OpenAI-compatible `function` shape).
public struct ToolDefinition: Hashable, Sendable, Codable, Identifiable {
    public var name: String
    public var description: String
    public var kind: ToolKind
    /// JSON Schema for the arguments.
    public var parameters: JSONValue
    public var id: String { name }
}

public struct ToolArgumentError: LocalizedError, Equatable {
    public var tool: String
    public var problems: [String]
    public var errorDescription: String? { "Invalid arguments for \(tool): " + problems.joined(separator: "; ") }
}

public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let kind: ToolKind
    public let schema: JSONSchema

    public var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, kind: kind, parameters: schema.jsonValue)
    }
}

/// Every tool the chat model can call. This is the single source of truth: the server hands these
/// to the model, validates the model's calls against them, and the app shows them in Settings.
public enum ToolCatalog {
    static let period = JSONSchema.string(
        "A period: this_month, last_month, last_7_days, last_90_days, year_to_date, a month like 2026-09, or a quarter like 2026-Q3.",
        pattern: #"^(this_month|last_month|last_7_days|last_90_days|year_to_date|[0-9]{4}-Q[1-4]|[0-9]{4}-(0[1-9]|1[0-2]))$"#)
    static let amount = JSONSchema.string(
        "A positive amount exactly as the user stated it, digits only, e.g. \"500\" or \"42.50\".",
        pattern: DecimalAmount.unsignedPattern)
    static let signedAmount = JSONSchema.string(
        "A signed change exactly as the user stated it, e.g. \"+50\" or \"-25\". Do not compute a new total.",
        pattern: DecimalAmount.signedPattern)
    static let categoryID = JSONSchema.string("A category id from the category list.")
    static let date = JSONSchema.string("A date, YYYY-MM-DD.", format: "date")
    static let transactionIDs = JSONSchema.array("Transaction ids returned by queryTransactions.", of: .string("A transaction id."), minItems: 1, maxItems: 50)
    static let ruleID = JSONSchema.string("A rule id returned by findRules.", minLength: 1, maxLength: 40)
    static let tag = JSONSchema.string("A tag, e.g. \"Austin trip\" or \"Reimbursable\".", minLength: 1, maxLength: TransactionTags.maxLength)
    static let symbol = JSONSchema.string("An SF Symbol name, e.g. \"pawprint\".", pattern: #"^[a-z0-9.]{1,40}$"#)
    static let color = JSONSchema.string("One of the category colors.", enum: CategoryColor.allCases.map(\.rawValue))
    static let group = JSONSchema.string("Which part of the budget it counts in: bills (rent, utilities, insurance), subscriptions (streaming, apps, memberships) or everyday (groceries, dining, shopping, travel). A merchant on the recurring list counts as its own kind whatever its category.",
                                         enum: CategoryGroup.allCases.map(\.rawValue))
    static let kind = JSONSchema.string("spending (the default), or moneyIn for money coming in that counts like income, e.g. card rewards and statement credits. A money-in category has no budget type or target, and its kind never changes.",
                                        enum: CategoryKind.allCases.map(\.rawValue))
    /// What a rule matches; every condition given must hold. Text ignores case and numbers.
    static let ruleMatch = JSONSchema.object("What to match. Give text, an account, or both; every condition given must hold.", [
        "merchantContains": .string("Text in the merchant name. Case and numbers are ignored.", minLength: 2, maxLength: 60),
        "descriptorContains": .string("Text in the bank descriptor. Case and numbers are ignored.", minLength: 2, maxLength: 60),
        "direction": .string("Only money going out, or only money coming in.", enum: TransactionFilter.Direction.allCases.map(\.rawValue)),
        "minAmount": .string("Only amounts at least this big, digits only, e.g. \"1000\".", pattern: DecimalAmount.unsignedPattern),
        "maxAmount": .string("Only amounts at most this big, digits only, e.g. \"50\".", pattern: DecimalAmount.unsignedPattern),
        "accountID": .string("Only transactions on this account: an accountID from queryTransactions.", minLength: 1, maxLength: 120),
    ], minProperties: 1)

    public static let specs: [ToolSpec] = [
        // Read — computed by the ledger, returned to the model.
        ToolSpec(name: "queryTransactions", description: "Find transactions. Returns rows newest first with id, date, merchant, amount, category, accountID, and the user's note if any; rows in a money-in category are marked moneyIn. Also returns spent (spending net of refunds, transfers aside) and income (everything filed under a money-in category: Income and any like card rewards) over every matching row — the same totals the Activity list shows. Rows the user hid are marked hidden and left out of both. Rows list their tags.", kind: .read,
                 schema: .object(nil, [
                     "search": .string("Text to match in the merchant name, bank descriptor or note, or one exact amount like 42.50. For more or less than an amount (\"over $500\"), use minAmount or maxAmount, not search.", maxLength: 80),
                     "categoryID": categoryID,
                     "minAmount": .string("Only rows at least this big, either way (a charge or money in), digits only: \"500\" for \"over $500\".", pattern: DecimalAmount.unsignedPattern),
                     "maxAmount": .string("Only rows at most this big, either way, digits only: \"20\" for \"under $20\".", pattern: DecimalAmount.unsignedPattern),
                     "direction": .string("Only money going out (\"out\": charges, purchases, bills) or only money coming in (\"in\").", enum: TransactionFilter.Direction.allCases.map(\.rawValue)),
                     "needsReviewOnly": .boolean("Only rows the categorizer flagged for review."),
                     "tag": .string("Only rows carrying this tag (the user's own label, like a trip or a project).", minLength: 1, maxLength: TransactionTags.maxLength),
                     "since": .string("The first day to include, YYYY-MM-DD.", format: "date"),
                     "until": .string("The last day to include, YYYY-MM-DD: \"2026-08-31\" for all of August.", format: "date"),
                     "limit": .integer("Maximum rows to return.", minimum: 1, maximum: 200),
                 ])),
        ToolSpec(name: "sumByCategory", description: "Total spending for a period, per category or for one category, plus what each money-in category (Income, card rewards) received. For one money-in category it returns what that category received instead of spending. With compareTo, the ledger also returns the difference and percent change — use those instead of computing them.", kind: .read,
                 schema: .object(nil, [
                     "period": period,
                     "compareTo": period,
                     "categoryID": categoryID,
                 ], required: ["period"])),
        ToolSpec(name: "projectBalance", description: "Project cash after cards (cash less what's owed on cards) forward at the recent pace of income less spending — the last three complete months, a yearly charge counted a twelfth a month — optionally checking whether a savings goal fits. With scenarioID (from planScenarios), the projection and the goal include that Plan scenario's switched-on changes, with the plain forecast's end beside them.", kind: .read,
                 schema: .object(nil, [
                     "account": .string("Which balance to project.", enum: ["cash"]),
                     "horizonMonths": .integer("How many months ahead.", minimum: 1, maximum: 36),
                     "goal": .object("A goal to check against the projection.", ["amount": amount, "targetDate": date], required: ["amount", "targetDate"]),
                     "scenarioID": .string("A Plan scenario id from planScenarios, to project with its changes; leave out for the plain forecast.", minLength: 1, maxLength: 64),
                 ], required: ["account", "horizonMonths"])),
        ToolSpec(name: "planScenarios", description: "The user's Plan scenarios: named sets of planned changes (a car payment from a month on, a one-time bonus, rent going up), each change with its amount, money in or out, how often, its months and whether it's switched on — and where each scenario leaves cash after cards at the end of the horizon against the plain forecast (projectBalance's). With scenarioID it also projects that scenario month by month and, with a goal, checks the goal against it. Read only: the user edits scenarios on the Plan screen.", kind: .read,
                 schema: .object(nil, [
                     "scenarioID": .string("A scenario id from an earlier planScenarios result.", minLength: 1, maxLength: 64),
                     "horizonMonths": .integer("How many months ahead.", minimum: 1, maximum: 36),
                     "goal": .object("A goal to check against the scenario.", ["amount": amount, "targetDate": date], required: ["amount", "targetDate"]),
                 ])),
        ToolSpec(name: "monthFlow", description: "Where one month's money came from and where it went — the Flow view in Spending: income by source (the smaller sources together), what Bills, Subscriptions and Everyday took with each one's top categories (spending as the budget counts it: each category net of refunds, a yearly charge a twelfth a month), and what was left (saved) or drawn from cash when spending passed income.", kind: .read,
                 schema: .object(nil, ["month": .string("A month like 2026-09; this month so far when left out.", pattern: #"^[0-9]{4}-(0[1-9]|1[0-2])$"#)])),
        ToolSpec(name: "sumByMerchant", description: "Spending at one merchant (e.g. DoorDash) for a period, its monthly average over the last three months, and its cap if one is set. With compareTo, the ledger also returns the difference.", kind: .read,
                 schema: .object(nil, [
                     "merchant": .string("Merchant name as the user said it, e.g. \"DoorDash\".", minLength: 2, maxLength: 60),
                     "period": period,
                     "compareTo": period,
                 ], required: ["merchant", "period"])),
        ToolSpec(name: "merchantSummary", description: "Everything about one merchant: spending there this month, over the last 12 months and all time (net of refunds), how many charges and how often (\"about 6 times a month\"), the average charge, first and last charge, its usual category, whether it recurs (cadence, amount, next charge) and its monthly cap if one is set.", kind: .read,
                 schema: .object(nil, [
                     "merchant": .string("Merchant name as the user said it, e.g. \"Blue Bottle\".", minLength: 2, maxLength: 60),
                 ], required: ["merchant"])),
        ToolSpec(name: "topMerchants", description: "The merchants of a period, most charges first (where the user goes most) or most spent first, each with its number of charges and spending net of refunds.", kind: .read,
                 schema: .object(nil, [
                     "period": period,
                     "sort": .string("visits (most charges first, the default) or spent (most money first).", enum: TopMerchants.Sort.allCases.map(\.rawValue)),
                     "limit": .integer("How many merchants.", minimum: 1, maximum: 20),
                 ], required: ["period"])),
        ToolSpec(name: "flexBudget", description: "This month's budget: expected income, a usual month of bills and of subscriptions (a charge spread over the year counts a twelfth), planned savings, the everyday budget that leaves, everyday spending so far, safe-to-spend and the days left (today included).", kind: .read,
                 schema: .object(nil, [:])),
        ToolSpec(name: "cashFlow", description: "Income against spending month by month: up to `months` complete months, then this month so far, oldest first — each month's income, spending (every category net of its refunds) and net. Use it for questions about cash flow, how income or spending changed, or what's driving cash up or down.", kind: .read,
                 schema: .object(nil, ["months": .integer("How many complete months before this one.", minimum: 1, maximum: 12)])),
        ToolSpec(name: "categoryHistory", description: "One spending category month by month, this month last, each against its current target, and its average over the complete months the ledger covers. Use it for how a category changed over time.", kind: .read,
                 schema: .object(nil, ["categoryID": categoryID, "months": .integer("How many months, this one included.", minimum: 2, maximum: 36)],
                                 required: ["categoryID"])),
        ToolSpec(name: "savingsCapacity", description: "How much the user can save per month: average income minus bills, subscriptions and everyday spending over recent months, a stretch figure with everyday spending at its lowest recent month, what they already move to savings, and months of essentials their cash covers.", kind: .read,
                 schema: .object(nil, ["months": .integer("How many recent complete months to average.", minimum: 1, maximum: 12)])),
        ToolSpec(name: "savingsGuidance", description: "Rules of thumb for how much the user should save, each with its source, computed against their numbers: emergency-fund target and gap, savings-rate targets, and the usual order of priorities.", kind: .read,
                 schema: .object(nil, [:])),
        ToolSpec(name: "findSubscriptions", description: "Every recurring charge found in the ledger: subscriptions (streaming, software, memberships) and bills (rent, utilities, fees), each with its cadence (weekly, monthly, quarterly, yearly), latest amount, cost per month and per year, last and next expected charge, price changes, and whether it missed its last expected charge (possibly cancelled). Use it for questions about subscriptions, recurring charges, or what the user is paying for regularly.", kind: .read,
                 schema: .object(nil, [:])),
        ToolSpec(name: "recurringReview", description: "Questions waiting on the Recurring screen: repeat charges that might be recurring but aren't on the list yet (mightBeRecurring), and recurring charges with no charge for about a cycle and a half that might have stopped (mightHaveStopped), each with its amount, cadence and last charge; plus ones the user marked as stopped. Only the user answers these, in the app. Use it when the user asks what might have stopped, whether they still pay for something, or what's new among their recurring charges.", kind: .read,
                 schema: .object(nil, [:])),
        ToolSpec(name: "monthlyRecap", description: "A finished month in review: income, spending (every category net of its refunds) and what was left over, money moved to savings, bills, subscriptions and everyday each against that month's budget, the categories that changed most against the month before, and the change in cash. Use it for how a past month went, or a recap of last month.", kind: .read,
                 schema: .object(nil, ["month": .string("A finished month like 2026-08. Leave it out for last month.", pattern: #"^[0-9]{4}-(0[1-9]|1[0-2])$"#)])),
        ToolSpec(name: "findUpcoming", description: "What's expected from today through `days` ahead, soonest first: paychecks predicted from the user's pay schedule (date, payer, the typical recent paycheck), bills and subscriptions the recurring list expects, and card bills from the card issuer when the server has them (Plaid with card bills turned on; what's left of the statement balance, the minimum and the due date; paid or past due); otherwise it says none are known, and they must not be estimated. Returns totals by kind for the window and for the next seven days, the next paycheck and how often pay comes. Card bills pay for spending already made, so never add them to bills and subscriptions. Use it for questions about the next paycheck, what's coming up or due, and card bills.", kind: .read,
                 schema: .object(nil, ["days": .integer("How many days ahead, today included.", minimum: 1, maximum: 90)])),
        ToolSpec(name: "runCheckup", description: "A full checkup in one call: this month's pace and safe to spend, categories over or on pace to exceed their targets, merchant caps and top merchants, recurring charges and price increases, unusual transactions, saving and emergency cushion, the cash outlook, and data health. Each finding is good, watch or act. Use it when the user asks how they're doing overall, to check everything, or for a review — then lead with what needs action.", kind: .read,
                 schema: .object(nil, [:])),
        ToolSpec(name: "checkPace", description: "This month's pace, as pace alerts see it: the everyday budget, every category target and every merchant cap with what's spent, where the month lands at the pace so far (from the second week; before it there's no projection), and what a day can take for the rest of the month and stay on budget; plus which are 80% used, on pace to finish over, or already over. Use it for whether the user is on track or will go over this month.", kind: .read,
                 schema: .object(nil, [:])),
        ToolSpec(name: "categorize", description: "Run the categorization pipeline on transactions and return ranked suggestions with confidence. Does not change anything.", kind: .read,
                 schema: .object(nil, ["transactionIDs": transactionIDs], required: ["transactionIDs"])),
        ToolSpec(name: "sumByTag", description: "Spending on one of the user's tags (their own labels for a trip, a project, or what work pays back): spent (net of refunds, hidden rows and transfers aside), income, how many transactions carry it, its first and last date, and spending by category. Without tag, every tag with its totals, most recently used first.", kind: .read,
                 schema: .object(nil, [
                     "tag": tag,
                     "period": period,
                 ])),
        ToolSpec(name: "findRules", description: "The user's categorization rules, newest first (the first that matches a transaction files it): each rule's id, what it matches, its category, whether it's on, how many transactions it filed and matches now, the rules it disagrees with, and whether its category is gone.", kind: .read,
                 schema: .object(nil, [:])),
        ToolSpec(name: "netWorth", description: "Net worth today — what the user owns (cash, investments, assets they keep by hand such as a home or car) less what they owe (cards, loans) — with its change over a range and the breakdown by account and item. Investments hold their latest recorded balance, so part of a longer range can be estimated; the result says when. Use it for questions about net worth, what they own or owe, or how their overall position changed.", kind: .read,
                 schema: .object(nil, ["range": .string("How far back to compare: 1M, 3M (the default), YTD, 1Y or ALL.", enum: NetWorthRange.allCases.map(\.rawValue))])),

        // Write — each call becomes a proposal card the person applies or dismisses.
        ToolSpec(name: "setCategoryTarget", description: "Propose setting a category's monthly target to an exact amount the user stated.", kind: .write,
                 schema: .object(nil, ["categoryID": categoryID, "monthlyAmount": amount], required: ["categoryID", "monthlyAmount"])),
        ToolSpec(name: "adjustCategoryTarget", description: "Propose raising or lowering a category's monthly target by an amount the user stated. The ledger computes the new target.", kind: .write,
                 schema: .object(nil, ["categoryID": categoryID, "change": signedAmount], required: ["categoryID", "change"])),
        ToolSpec(name: "removeCategoryTarget", description: "Propose removing a category's monthly target.", kind: .write,
                 schema: .object(nil, ["categoryID": categoryID], required: ["categoryID"])),
        ToolSpec(name: "setMerchantTarget", description: "Propose a monthly cap for one merchant, e.g. \"DoorDash: $150 a month\", at an amount the user stated.", kind: .write,
                 schema: .object(nil, [
                     "merchant": .string("Merchant name, e.g. \"DoorDash\".", minLength: 2, maxLength: 60),
                     "monthlyAmount": amount,
                 ], required: ["merchant", "monthlyAmount"])),
        ToolSpec(name: "setMonthlySavings", description: "Propose the amount to set aside each month before anything else (pay yourself first). The flex number and safe-to-spend follow from it.", kind: .write,
                 schema: .object(nil, ["monthlyAmount": amount], required: ["monthlyAmount"])),
        ToolSpec(name: "removeMerchantTarget", description: "Propose removing a merchant's monthly cap.", kind: .write,
                 schema: .object(nil, ["merchant": .string("Merchant name.", minLength: 2, maxLength: 60)], required: ["merchant"])),
        ToolSpec(name: "createCategory", description: "Propose a new category: a spending one, optionally with a monthly target and a budget type, or (kind moneyIn) one for money coming in that counts like income, such as card rewards. Optionally a color and an icon.", kind: .write,
                 schema: .object(nil, [
                     "name": .string("Display name, e.g. \"Pets\" or \"Card rewards\".", minLength: 1, maxLength: 32),
                     "symbol": symbol,
                     "monthlyTarget": amount,
                     "group": group,
                     "color": color,
                     "kind": kind,
                 ], required: ["name"])),
        ToolSpec(name: "updateCategory", description: "Propose renaming a category or changing its icon, color or budget type. Income and Transfer can only change icon and color; a money-in category has no budget type. A category's kind never changes.", kind: .write,
                 schema: .object(nil, [
                     "categoryID": categoryID,
                     "name": .string("New display name.", minLength: 1, maxLength: 32),
                     "symbol": symbol,
                     "color": color,
                     "group": group,
                 ], required: ["categoryID"], minProperties: 2)),
        ToolSpec(name: "mergeCategory", description: "Propose folding one category into another of the same kind — spending into spending, or money in into money in: its transactions, rules and review suggestions move, and it goes away. Income and Transfer are never merged away.", kind: .write,
                 schema: .object(nil, [
                     "from": .string("The category id to fold in and remove."),
                     "into": .string("The category id that takes everything."),
                     "combineTargets": .boolean("Add the removed category's monthly target to the other's. Otherwise it's dropped."),
                 ], required: ["from", "into"])),
        ToolSpec(name: "createBudgetRule", description: "Propose a categorization rule: transactions matching the text, account, direction or amount given are filed under a category, now and in future. The newest matching rule wins.", kind: .write,
                 schema: .object(nil, [
                     "match": ruleMatch,
                     "categoryID": categoryID,
                     "applyToExisting": .boolean("Also re-file existing matching transactions."),
                 ], required: ["match", "categoryID", "applyToExisting"])),
        ToolSpec(name: "updateBudgetRule", description: "Propose changing a rule found with findRules: what it matches (replaced as a whole), its category, or turning it off or on.", kind: .write,
                 schema: .object(nil, [
                     "ruleID": ruleID,
                     "match": ruleMatch,
                     "categoryID": categoryID,
                     "isEnabled": .boolean("false turns the rule off; true turns it back on."),
                     "applyToExisting": .boolean("Also re-file existing transactions the changed rule matches."),
                 ], required: ["ruleID"], minProperties: 2)),
        ToolSpec(name: "deleteBudgetRule", description: "Propose deleting a rule found with findRules. Transactions it filed keep their category.", kind: .write,
                 schema: .object(nil, ["ruleID": ruleID], required: ["ruleID"])),
        ToolSpec(name: "recategorize", description: "Propose filing specific transactions under a category.", kind: .write,
                 schema: .object(nil, ["transactionIDs": transactionIDs, "categoryID": categoryID], required: ["transactionIDs", "categoryID"])),
        ToolSpec(name: "editTransactions", description: "Propose changes to specific transactions: file them under a category (optionally with every other transaction from the same merchant), keep the category they already have, hide them from spending and budget totals (or count them again), mark a yearly charge to spread it over the year (or not), add a note, rename the merchant, or add or remove tags. Give only the fields to change.", kind: .write,
                 schema: .object(nil, [
                     "transactionIDs": transactionIDs,
                     "categoryID": categoryID,
                     "acceptGuess": .boolean("Keep the category each transaction already has, as the user's own choice."),
                     "isHidden": .boolean("true leaves the transactions out of spending, income and budget totals (balances still include them); false counts them again."),
                     "isYearly": .boolean("true: spread over the year (an annual fee, a yearly plan, a big trip): the budget counts a twelfth a month for twelve months instead of all in its month; it keeps its category. false: counted in its month."),
                     "note": .string("A note to attach, in the user's words. An empty string removes the note.", maxLength: 500),
                     "merchant": .string("A new merchant name, e.g. \"Blue Bottle\".", minLength: 1, maxLength: 60),
                     "renameSimilar": .boolean("With merchant: also rename every transaction with the same bank descriptor, and future ones."),
                     "fileSimilar": .boolean("With categoryID: also file every other transaction from the same merchant or with the same bank descriptor, going the same way (a purchase's refunds go with it), under it. Ones the user filed themselves keep their category."),
                     "addTags": .array("Tags to add, in the user's words.", of: tag, minItems: 1, maxItems: TransactionTags.maxPerTransaction),
                     "removeTags": .array("Tags to take off.", of: tag, minItems: 1, maxItems: TransactionTags.maxPerTransaction),
                 ], required: ["transactionIDs"], minProperties: 2)),

        ToolSpec(name: "rememberFact", description: "Propose keeping one fact about the user in assistant memory, for later conversations: a plan, a person, a preference, in their words (\"Saving for a trip to Lisbon in March\"). Not for figures from tool results, and not for budget changes, which have their own tools.", kind: .write,
                 schema: .object(nil, ["fact": .string("One short sentence in the user's words.", minLength: 3, maxLength: AssistantMemory.maxLength)],
                                 required: ["fact"])),
        ToolSpec(name: "updateDecisionPolicy", description: "Propose changing the decision model: which provider categorizes uncertain transactions, and the confidence percent at or above which its decisions are accepted without review.", kind: .write,
                 schema: .object(nil, [
                     "provider": .string("off, localDecide (Qwen Decide on the user's server), laya (on the user's server), or jev (TypeSafe; receives merchant, cleaned descriptor and amount band).", enum: DecisionProvider.allCases.map(\.rawValue)),
                     "escalateToJev": .boolean("With a local provider, re-ask Jev about decisions below the threshold."),
                     "autoAcceptPercent": .integer("Auto-accept decisions at or above this confidence, as a whole percent the user stated, e.g. 80.", minimum: DecisionPolicy.allowedPercents.lowerBound, maximum: DecisionPolicy.allowedPercents.upperBound),
                     "rerunPending": .boolean("Re-run the model on transactions waiting for review. Defaults to true when the provider, threshold or escalation changes."),
                     "reviewNewMerchants": .boolean("true sends every new merchant to review, however sure the model is."),
                     "holdPending": .boolean("true keeps pending charges out of review until they post."),
                     "reviewAbove": .string("Send anything bigger than this to review unless a rule covers it, digits only; \"0\" turns it off.", pattern: DecimalAmount.unsignedPattern),
                 ], minProperties: 1)),

        // Client — handled by the app.
        ToolSpec(name: "navigate", description: "Offer to open a screen in the app, optionally focused on a category, budget month, period, search, or planning horizon. recurring lists subscriptions and bills.", kind: .client,
                 schema: .object(nil, [
                     "screen": .string("The screen to open.", enum: AppScreen.allCases.map(\.rawValue)),
                     "categoryID": categoryID,
                     "range": .string("Spending range to show.", enum: SpendingRange.allCases.map(\.rawValue)),
                     "month": .string("A budget month for Spending, like 2026-09.", pattern: #"^[0-9]{4}-(0[1-9]|1[0-2])$"#),
                     "search": .string("Search text for Activity.", maxLength: 80),
                     "horizonMonths": .integer("Planning horizon for Plan.", minimum: 1, maximum: 36),
                 ], required: ["screen"])),
    ]

    public static func spec(named name: String) -> ToolSpec? { specs.first { $0.name == name } }

    /// Tools whose category must be a spending category: only spending has targets.
    static let spendingOnlyTools: Set = ["setCategoryTarget", "adjustCategoryTarget", "removeCategoryTarget"]
    /// Tools whose categories must be spending or money in: Transfer is never merged (the ledger also refuses
    /// mixing the two kinds, and merging Income away).
    static let mergeTools: Set = ["mergeCategory"]

    /// Fields that hold a category id.
    static let categoryFields = ["categoryID", "from", "into"]

    /// Specs with every category field constrained to the ledger's current categories, so a
    /// constrained decoder can't emit an unknown id — or a non-spending one for target tools, or Transfer to merge.
    /// - Parameter mergeableCategoryIDs: spending and money-in categories; the spending ones when nil.
    public static func specs(categoryIDs: [String], spendingCategoryIDs: [String]? = nil, mergeableCategoryIDs: [String]? = nil) -> [ToolSpec] {
        specs.map { spec in
            let allowed = spendingOnlyTools.contains(spec.name) ? (spendingCategoryIDs ?? categoryIDs)
                : mergeTools.contains(spec.name) ? (mergeableCategoryIDs ?? spendingCategoryIDs ?? categoryIDs) : categoryIDs
            let schema = categoryFields.reduce(spec.schema) { schema, field in
                schema.mapProperties(named: field) { s in
                    var s = s
                    s.enumValues = allowed
                    return s
                }
            }
            return ToolSpec(name: spec.name, description: spec.description, kind: spec.kind, schema: schema)
        }
    }

    /// Specs narrowed to a ledger's categories. Categories merged away are left out.
    public static func specs(for categories: [BudgetCategory]) -> [ToolSpec] {
        let active = categories.filter { !$0.isArchived }
        return specs(categoryIDs: active.map(\.id), spendingCategoryIDs: active.filter(\.countsAsSpending).map(\.id),
                     mergeableCategoryIDs: active.filter { $0.countsAsSpending || $0.isMoneyIn }.map(\.id))
    }

    public static func definitions(for categories: [BudgetCategory]? = nil, capabilities: AskCapabilities = .all) -> [ToolDefinition] {
        specs(categories.map { specs(for: $0) } ?? specs, for: capabilities).map(\.definition)
    }

    /// The `tools` array for an OpenAI-compatible chat completion request, without what the asking app can't take.
    public static func openAITools(for categories: [BudgetCategory]? = nil, capabilities: AskCapabilities = .all) -> JSONValue {
        .array(definitions(for: categories, capabilities: capabilities).map { d in
            .object(["type": .string("function"), "function": .object([
                "name": .string(d.name), "description": .string(d.description), "parameters": d.parameters,
            ])])
        })
    }

    /// Parses and validates a tool call's arguments. Throws `ToolArgumentError` with messages
    /// suitable for sending back to the model so it can repair the call.
    @discardableResult
    public static func validateArguments(tool: String, json: Data, categoryIDs: [String]? = nil, spendingCategoryIDs: [String]? = nil,
                                         mergeableCategoryIDs: [String]? = nil, capabilities: AskCapabilities = .all) throws -> JSONValue {
        let all = categoryIDs.map { specs(categoryIDs: $0, spendingCategoryIDs: spendingCategoryIDs, mergeableCategoryIDs: mergeableCategoryIDs) } ?? specs
        guard let spec = specs(all, for: capabilities).first(where: { $0.name == tool }) else {
            throw ToolArgumentError(tool: tool, problems: ["unknown tool"])
        }
        let value: JSONValue
        do { value = try JSONValue.parse(json) } catch { throw ToolArgumentError(tool: tool, problems: ["arguments are not valid JSON"]) }
        let problems = spec.schema.validate(value)
        guard problems.isEmpty else { throw ToolArgumentError(tool: tool, problems: problems) }
        return value
    }
}

extension ToolCall {
    /// `categoryID: "dining", period: "2026-Q3"` from the JSON arguments, for display.
    public var displayArguments: String {
        guard let data = arguments.data(using: .utf8), case let .object(fields)? = try? JSONValue.parse(data) else { return arguments }
        return fields.sorted { $0.key < $1.key }.map { key, value in
            let rendered = (try? value.data()).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            return "\(key): \(rendered)"
        }.joined(separator: ", ")
    }
}
