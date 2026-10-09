import Foundation

/// Read tools over the demo ledger — the same results the server's Postgres queries return.
/// Money is rendered with `Money.display` so the grounding check can match what the model quotes.
struct DemoToolbox: AgentToolbox {
    let ledger: DemoLedger
    let decisions: (any DecisionModel)?
    var institutions: [InstitutionLink] = []

    /// What the model may file under: categories merged away are left out.
    var categories: [BudgetCategory] { ledger.activeCategories }

    var assistantContext: AssistantContext {
        AssistantContext(now: ledger.now, timeZone: ledger.calendar.timeZone, categories: categories, monthlyTargets: ledger.monthlyTargets)
    }

    func propose(_ action: AppAction) async throws -> ProposedAction {
        let action = action.proposedByAssistant()
        let preview = try ledger.preview(action)
        return ProposedAction(id: UUID().uuidString, action: action, title: preview.title, detail: preview.detail, effects: preview.effects)
    }

    func run(read tool: String, arguments: JSONValue) async throws -> (result: JSONValue, figures: [Figure]) {
        guard case let .object(args) = arguments else { throw BudgetAPIError.rejected("Arguments must be an object.") }
        func string(_ key: String) -> String? { if case let .string(v)? = args[key] { v } else { nil } }
        func int(_ key: String) -> Int? { if case let .number(v)? = args[key] { Int(v) } else { nil } }
        func bool(_ key: String) -> Bool? { if case let .bool(v)? = args[key] { v } else { nil } }

        switch tool {
        case "sumByCategory": return try sumByCategory(period: string("period")!, compareTo: string("compareTo"), categoryID: string("categoryID"))
        case "sumByMerchant": return try sumByMerchant(string("merchant")!, period: string("period")!, compareTo: string("compareTo"))
        case "merchantSummary": return try merchantSummaryTool(string("merchant")!)
        case "topMerchants":
            return try topMerchantsTool(period: string("period")!, sort: string("sort").flatMap(TopMerchants.Sort.init(rawValue:)) ?? .visits, limit: int("limit") ?? 5)
        case "queryTransactions":
            return queryTransactions(search: string("search"), categoryID: string("categoryID"), needsReviewOnly: bool("needsReviewOnly") ?? false,
                                     since: string("since"), until: string("until"), limit: int("limit") ?? 25,
                                     minAmount: string("minAmount").flatMap(DecimalAmount.init(string:))?.money(),
                                     maxAmount: string("maxAmount").flatMap(DecimalAmount.init(string:))?.money(),
                                     direction: string("direction").flatMap(TransactionFilter.Direction.init(rawValue:)), tag: string("tag"))
        case "projectBalance":
            var goal: GoalQuery?
            if case let .object(g)? = args["goal"], case let .string(a)? = g["amount"], case let .string(d)? = g["targetDate"],
               let amount = DecimalAmount(string: a), let date = isoDate(d) {
                goal = GoalQuery(amount: amount.money(), targetDate: date)
            }
            return projectBalance(horizon: int("horizonMonths") ?? 6, goal: goal)
        case "flexBudget": return flexBudget()
        case "cashFlow": return cashFlow(months: int("months") ?? 6)
        case "categoryHistory": return try categoryHistory(string("categoryID")!, months: int("months") ?? 12)
        case "savingsCapacity": return savingsCapacity(months: int("months") ?? 3)
        case "savingsGuidance": return savingsGuidance()
        case "runCheckup": return runCheckup()
        case "findSubscriptions": return findSubscriptions()
        case "findRules": return findRules()
        case "sumByTag": return try sumByTag(string("tag"), period: string("period"))
        case "categorize": return try await categorize(args["transactionIDs"])
        default: throw BudgetAPIError.rejected("Unknown read tool \(tool).")
        }
    }

    // MARK: Tools

    private func window(_ period: String) throws -> (start: Date, end: Date, label: String) {
        guard let w = ledger.interval(forPeriod: period) else { throw BudgetAPIError.rejected("Unknown period “\(period)”.") }
        return w
    }

    private func comparison(_ current: Money, _ previous: Money) -> (difference: Money, change: String) {
        (current - previous, DemoLedger.comparisonLine(current: current, previous: previous, against: "the comparison period"))
    }

    func sumByCategory(period: String, compareTo: String?, categoryID: String?) throws -> (result: JSONValue, figures: [Figure]) {
        let w = try window(period)
        if let category = categoryID.flatMap(ledger.category), category.isMoneyIn {
            return try received(category, window: w, period: period, compareTo: compareTo)
        }
        let total = ledger.spent(from: w.start, to: w.end, categoryID: categoryID)
        let subject = categoryID.flatMap(ledger.category)?.name ?? "All spending"
        var o: [String: JSONValue] = ["period": .string(w.label), "subject": .string(subject), "total": .string(total.display)]
        if w.end == ledger.now, period != "this_month" { o["through"] = .string(ledger.now.formatted(.dateTime.month(.abbreviated).day())) }
        var figures = [Figure(id: "total-\(period)", label: "\(subject) · \(w.label)", detail: nil, value: total)]
        if categoryID == nil {
            o["byCategory"] = .array(ledger.sumByCategory(from: w.start, to: w.end, includeTargets: false).filter { $0.spent.minorUnits > 0 }.map {
                .object(["id": .string($0.category.id), "name": .string($0.category.name), "spent": .string($0.spent.display)])
            })
            let moneyIn = ledger.receivedByCategory(from: w.start, to: w.end)
            if !moneyIn.isEmpty {
                o["moneyIn"] = .array(moneyIn.map {
                    .object(["id": .string($0.category.id), "name": .string($0.category.name), "received": .string($0.received.display)])
                })
            }
        } else if let target = ledger.monthlyTargets[categoryID!] {
            o["monthlyTarget"] = .string(target.display)
        }
        if let compareTo {
            let p = try window(compareTo)
            let previous = ledger.spent(from: p.start, to: p.end, categoryID: categoryID)
            let c = comparison(total, previous)
            o["compareTo"] = .object(["period": .string(p.label), "total": .string(previous.display),
                                      "difference": .string(c.difference.display), "change": .string(c.change)])
            figures += [Figure(id: "total-\(compareTo)", label: "\(subject) · \(p.label)", detail: nil, value: previous),
                        Figure(id: "difference", label: "Difference", detail: nil, value: c.difference)]
        }
        return (.object(o), figures)
    }

    /// One money-in category (Income, card rewards) over a period: what it received, not what it spent.
    private func received(_ category: BudgetCategory, window w: (start: Date, end: Date, label: String), period: String,
                          compareTo: String?) throws -> (result: JSONValue, figures: [Figure]) {
        let total = ledger.received(from: w.start, to: w.end, categoryID: category.id)
        var o: [String: JSONValue] = ["period": .string(w.label), "subject": .string(category.name), "countsAs": .string("money in"),
                                      "received": .string(total.display)]
        var figures = [Figure(id: "received-\(period)", label: "\(category.name) received · \(w.label)", detail: nil, value: total)]
        if let compareTo {
            let p = try window(compareTo)
            let previous = ledger.received(from: p.start, to: p.end, categoryID: category.id)
            let c = comparison(total, previous)
            o["compareTo"] = .object(["period": .string(p.label), "received": .string(previous.display),
                                      "difference": .string(c.difference.display), "change": .string(c.change)])
            figures += [Figure(id: "received-\(compareTo)", label: "\(category.name) received · \(p.label)", detail: nil, value: previous),
                        Figure(id: "difference", label: "Difference", detail: nil, value: c.difference)]
        }
        return (.object(o), figures)
    }

    func sumByMerchant(_ query: String, period: String, compareTo: String?) throws -> (result: JSONValue, figures: [Figure]) {
        guard let merchant = ledger.canonicalMerchant(query) else {
            return (.object(["merchant": .string(query), "found": .bool(false), "note": .string("No transactions from this merchant.")]), [])
        }
        let w = try window(period)
        let spend = ledger.merchantSpend(merchant, from: w.start, to: w.end)
        let average = ledger.merchantMonthlyAverage(merchant)
        var o: [String: JSONValue] = ["merchant": .string(merchant), "period": .string(w.label), "total": .string(spend.total.display),
                                      "orders": .number(Double(spend.count)), "monthlyAverageLast3Months": .string(average.display)]
        var figures = [Figure(id: "merchant", label: "\(merchant) · \(w.label)", detail: "\(spend.count) orders", value: spend.total),
                       Figure(id: "merchant-avg", label: "3-month monthly average", detail: nil, value: average)]
        if let cap = ledger.merchantTargets[merchant] {
            o["monthlyCap"] = .string(cap.display)
            figures.append(Figure(id: "merchant-cap", label: "Monthly cap", detail: nil, value: cap))
        } else {
            o["monthlyCap"] = .string("none set")
        }
        if let compareTo {
            let p = try window(compareTo)
            let previous = ledger.merchantSpend(merchant, from: p.start, to: p.end).total
            let c = comparison(spend.total, previous)
            o["compareTo"] = .object(["period": .string(p.label), "total": .string(previous.display), "difference": .string(c.difference.display), "change": .string(c.change)])
        }
        return (.object(o), figures)
    }

    /// The person's categorization rules, as the rules list shows them.
    func findRules() -> (result: JSONValue, figures: [Figure]) {
        let rules = ledger.ruleSummaries()
        return (.object([
            "count": .number(Double(rules.count)),
            "order": .string("Newest first; when several rules match a transaction, the first listed wins."),
            "rules": .array(rules.map { r in
                var o: [String: JSONValue] = ["id": .string(r.id), "matches": .string(r.matchDescription), "categoryID": .string(r.rule.categoryID),
                                              "on": .bool(r.rule.isEnabled), "transactionsFiled": .number(Double(r.hitCount)),
                                              "transactionsMatchingNow": .number(Double(r.matchCount))]
                if !r.conflicts.isEmpty { o["disagreesWith"] = .array(r.conflicts.map(JSONValue.string)) }
                if r.isDead { o["categoryGone"] = .bool(true) }
                return .object(o)
            }),
        ]), [])
    }

    /// The same query the Activity list runs, with the same totals as its summary: spending net of refunds and income,
    /// by the Spending tab's rules. Hidden rows are listed (marked) but left out of the totals.
    func queryTransactions(search: String?, categoryID: String?, needsReviewOnly: Bool, since: String?, until: String?, limit: Int,
                           minAmount: Money? = nil, maxAmount: Money? = nil, direction: TransactionFilter.Direction? = nil,
                           tag: String? = nil) -> (result: JSONValue, figures: [Figure]) {
        // The model's until is the last day it means ("2026-08-31" for August); the filter's is the instant after it.
        let through = until.flatMap(isoDate).flatMap { ledger.calendar.date(byAdding: .day, value: 1, to: $0) }
        let filter = TransactionFilter(search: search, categoryIDs: categoryID.map { [$0] }, since: since.flatMap(isoDate), until: through,
                                       direction: direction, minAmount: minAmount, maxAmount: maxAmount, needsReviewOnly: needsReviewOnly, limit: limit,
                                       tags: tag.map { [$0] })
        let rows = ledger.matching(filter)
        let summary = ledger.summary(filter)
        var figures = [Figure(id: "query-spent", label: "Spent · \(rows.count) transaction\(rows.count == 1 ? "" : "s")", detail: "Net of refunds", value: summary.spent)]
        if summary.income.minorUnits != 0 { figures.append(Figure(id: "query-income", label: "Income", detail: nil, value: summary.income)) }
        return (.object([
            "count": .number(Double(rows.count)),
            "spent": .string(summary.spent.display),
            "income": .string(summary.income.display),
            "rows": .array(rows.prefix(limit).map { row in
                var o: [String: JSONValue] = ["id": .string(row.id), "date": .string(isoDay(row.postedAt)), "merchant": .string(row.merchant),
                                              "amount": .string(row.amount.display), "category": .string(row.categorization?.categoryID ?? "uncategorized"),
                                              "accountID": .string(row.accountID)]
                if row.isHidden { o["hidden"] = .bool(true) }
                if ledger.isMoneyIn(row.categorization?.categoryID) { o["moneyIn"] = .bool(true) }
                if let note = row.note { o["note"] = .string(note) }
                if let tags = row.tags { o["tags"] = .array(tags.map(JSONValue.string)) }
                if let order = row.orderMatch { o["orderItems"] = .array(order.items.map(JSONValue.string)) }
                return .object(o)
            }),
        ]), figures)
    }

    func projectBalance(horizon: Int, goal: GoalQuery?) -> (result: JSONValue, figures: [Figure]) {
        let p = ledger.projection(horizonMonths: horizon, goal: goal)
        var o: [String: JSONValue] = [
            "cashNow": .string(ledger.cash(through: ledger.now).display), "cardsOwed": .string((p.cardsOwed ?? .zero).display),
            "cashAfterCardsNow": .string(p.projected[0].expected.display),
            "monthlyNet": .string(p.monthlyNet.display),
            "monthlyNetIs": .string("average income less spending over the last three complete months, a yearly charge counted a twelfth a month"),
            "horizonMonths": .number(Double(p.horizonMonths)), "projectedEnd": .string(p.endBalance.display),
            "projectedEndIs": .string("cash after cards: cash less what's owed on cards"),
            "likelyRange": .string("\(p.projected.last!.low.display) to \(p.projected.last!.high.display)"),
        ]
        var figures = [Figure(id: "projected", label: "Cash after cards in \(p.horizonMonths) months", detail: "At \(p.monthlyNet.display)/mo", value: p.endBalance)]
        if let g = p.goal {
            o["goal"] = .object(["amount": .string(g.query.amount.display), "by": .string(isoDay(g.query.targetDate)),
                                 "projectedSavings": .string(g.projectedSavings.display), "onTrack": .bool(g.isOnTrack),
                                 "shortfall": .string(g.shortfall.display), "monthlyNeeded": .string(g.monthlyNeeded.display)])
            figures += [Figure(id: "goal-saved", label: "Projected savings by then", detail: nil, value: g.projectedSavings),
                        Figure(id: "goal-need", label: "Needed per month", detail: nil, value: g.monthlyNeeded)]
        }
        return (.object(o), figures)
    }

    func flexBudget() -> (result: JSONValue, figures: [Figure]) {
        let f = ledger.flexBudget()
        return (.object([
            "expectedIncome": .string(f.expectedIncome.display), "expectedIncomeIs": .string("the lower of the last 3 months' average income and a month of the latest paychecks; here \(f.incomeSourcePhrase)"),
            "threeMonthAverageIncome": .string((f.averageIncome ?? f.expectedIncome).display),
            "recentPaychecks": f.recentPaychecks.map { .string("\($0.display) (the last \(f.paycheckCount ?? 2))") } ?? .null,
            "bills": .string(f.bills.display), "subscriptions": .string(f.subscriptions.display),
            "plannedSavings": .string(f.plannedSavings.display), "plannedSavingsSource": .string(f.plannedSavingsIsSet ? "the user's setting" : "detected recurring transfers"),
            "everydayBudget": .string(f.flexNumber.display), "everydaySpentThisMonth": .string(f.flexSpent.display),
            "safeToSpend": .string(f.safeToSpend.display), "daysLeftIncludingToday": .number(Double(f.daysLeftIncludingToday)),
        ]), [Figure(id: "flex", label: "Everyday budget", detail: nil, value: f.flexNumber),
             Figure(id: "flex-spent", label: "Everyday spent", detail: nil, value: f.flexSpent),
             Figure(id: "safe", label: "Safe to spend", detail: FlexBudget.daysLeftPhrase(f.daysLeftIncludingToday), value: f.safeToSpend)])
    }

    /// Income against spending by month, as Plan's cash flow shows it.
    func cashFlow(months: Int) -> (result: JSONValue, figures: [Figure]) {
        let flows = ledger.cashFlowHistory(months: max(1, min(months, 12)))
        var figures: [Figure] = []
        let list: [JSONValue] = flows.map { m in
            let label = monthLabel(m.month)
            figures += [Figure(id: "in-\(m.month)", label: "Income · \(label)", detail: m.isPartial ? "So far" : nil, value: m.income),
                        Figure(id: "out-\(m.month)", label: "Spending · \(label)", detail: m.isPartial ? "So far" : nil, value: m.spending),
                        Figure(id: "net-\(m.month)", label: "Net · \(label)", detail: m.isPartial ? "So far" : nil, value: m.net)]
            return .object(["month": .string(m.month), "income": .string(m.income.display), "spending": .string(m.spending.display),
                            "net": .string(m.net.display), "soFar": .bool(m.isPartial)])
        }
        return (.object(["months": .array(list)]), figures)
    }

    /// One category's months, as its detail screen shows them.
    func categoryHistory(_ categoryID: String, months: Int) throws -> (result: JSONValue, figures: [Figure]) {
        let history = try ledger.categoryHistory(categoryID, months: months)
        let name = ledger.category(categoryID)?.name ?? categoryID
        var figures = [Figure(id: "avg-\(categoryID)", label: "\(name) · monthly average", detail: "\(history.monthsAveraged) full months", value: history.averageMonthly)]
        let list: [JSONValue] = history.months.map { m in
            figures.append(Figure(id: "\(categoryID)-\(m.month)", label: "\(name) · \(monthLabel(m.month))", detail: nil, value: m.spent))
            var o: [String: JSONValue] = ["month": .string(m.month), "spent": .string(m.spent.display)]
            if let target = m.target { o["target"] = .string(target.display) }
            return .object(o)
        }
        return (.object(["category": .string(name), "months": .array(list), "averageMonthly": .string(history.averageMonthly.display),
                         "monthsAveraged": .number(Double(history.monthsAveraged))]), figures)
    }

    /// "Aug 2026" for "2026-08".
    private func monthLabel(_ key: String) -> String {
        guard let start = ledger.monthStart(key) else { return key }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).year()
        style.timeZone = ledger.calendar.timeZone
        return start.formatted(style)
    }

    func savingsCapacity(months: Int) -> (result: JSONValue, figures: [Figure]) {
        let c = ledger.capacity(months: months)
        return (.object([
            "monthsAveraged": .number(Double(c.months)), "averageIncome": .string(c.income.display),
            "bills": .string(c.bills.display), "subscriptions": .string(c.subscriptions.display), "everyday": .string(c.everyday.display),
            "canSaveTypical": .string(c.typical.display), "canSaveStretch": .string(c.stretch.display),
            "stretchMeans": .string("everyday spending held to its lowest month of the last \(c.months)"),
            "alreadyMovingToSavings": .string(c.alreadySaving.display),
            "cashOnHand": .string(c.cashOnHand.display), "essentialMonthly": .string(c.essentialMonthly.display),
            "monthsOfEssentialsCovered": .string(String(format: "%.1f", c.emergencyMonths)),
        ]), [Figure(id: "can-typical", label: "Can save a month (typical)", detail: "Income minus all spending, \(c.months)-mo avg", value: c.typical),
             Figure(id: "can-stretch", label: "Can save a month (stretch)", detail: "Flexible at its lowest month", value: c.stretch),
             Figure(id: "saving-now", label: "Already moving to savings", detail: nil, value: c.alreadySaving)])
    }

    /// Sourced rules of thumb (docs/BUDGETING.md), computed against the ledger.
    /// The whole checkup, compact: per finding its status, title, detail and metrics (money as display strings,
    /// every amount also a figure so the grounding check can match what the model quotes).
    func runCheckup() -> (result: JSONValue, figures: [Figure]) {
        let checkup = ledger.checkup(institutions: institutions)
        var figures: [Figure] = []
        let sections: [JSONValue] = checkup.sections.map { section in
            .object(["section": .string(section.title), "status": .string(section.status.rawValue),
                     "findings": .array(section.findings.map { f in
                         var metrics: [String: JSONValue] = [:]
                         for m in f.metrics {
                             if let money = m.money {
                                 metrics[m.label] = .string(money.display)
                                 figures.append(Figure(id: "\(f.id)-\(figures.count)", label: m.label, detail: f.title, value: money))
                             } else if let text = m.text { metrics[m.label] = .string(text) }
                         }
                         var o: [String: JSONValue] = ["status": .string(f.status.rawValue), "title": .string(f.title), "metrics": .object(metrics)]
                         if let d = f.detail { o["detail"] = .string(d) }
                         if let s = f.suggestion { o["suggestedNextStep"] = .string(s) }
                         return .object(o)
                     })])
        }
        return (.object(["asOf": .string(isoDate(checkup.asOf)), "headline": .string(checkup.headline), "sections": .array(sections)]), figures)
    }

    /// Every recurring charge, with money as display strings and each amount also a figure for grounding.
    func findSubscriptions() -> (result: JSONValue, figures: [Figure]) {
        let found = ledger.subscriptions()
        var figures = [Figure(id: "subs-monthly", label: "Subscriptions a month", detail: nil, value: found.subscriptionsMonthly),
                       Figure(id: "subs-yearly", label: "Subscriptions a year", detail: nil, value: found.subscriptionsYearly),
                       Figure(id: "bills-monthly", label: "Bills a month", detail: nil, value: found.billsMonthly)]
        let items: [JSONValue] = found.items.map { s in
            figures.append(Figure(id: "sub-\(s.merchant)", label: s.merchant, detail: s.cadence.rawValue, value: s.amount))
            figures.append(Figure(id: "sub-m-\(s.merchant)", label: "\(s.merchant) a month", detail: nil, value: s.monthlyCost))
            var o: [String: JSONValue] = ["merchant": .string(s.merchant), "kind": .string(s.kind.rawValue), "cadence": .string(s.cadence.rawValue),
                                          "status": .string(s.status == .active ? "active" : "missed its last expected charge — possibly cancelled"),
                                          "amount": .string(s.amount.display), "perMonth": .string(s.monthlyCost.display), "perYear": .string(s.yearlyCost.display),
                                          "lastCharged": .string(isoDate(s.lastCharged)), "nextExpected": .string(isoDate(s.nextExpected)),
                                          "timesCharged": .number(Double(s.charges))]
            if let previous = s.previousAmount {
                o["previousAmount"] = .string(previous.display)
                figures.append(Figure(id: "sub-p-\(s.merchant)", label: "\(s.merchant) before", detail: nil, value: previous))
            }
            if let account = s.accountName { o["account"] = .string(account) }
            return .object(o)
        }
        return (.object(["subscriptionsPerMonth": .string(found.subscriptionsMonthly.display), "subscriptionsPerYear": .string(found.subscriptionsYearly.display),
                         "billsPerMonth": .string(found.billsMonthly.display), "monthsOfHistorySearched": .number(Double(found.monthsSearched)),
                         "note": .string("Found from repeat charges in the ledger. Annual charges need about a year of history to appear."),
                         "items": .array(items)]), figures)
    }

    private func isoDate(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle(timeZone: ledger.calendar.timeZone).year().month().day()) }

    func savingsGuidance() -> (result: JSONValue, figures: [Figure]) {
        let g = ledger.guidance()
        return (.object([
            "emergencyFund": .object([
                "rule": .string("3–6 months of essential expenses for income shocks (Vanguard); about half a month covers spending shocks"),
                "essentialMonthly": .string(g.essentialMonthly.display),
                "target3Months": .string(g.threeMonths.display), "target6Months": .string(g.sixMonths.display),
                "cashOnHand": .string(g.cash.display), "gapTo3Months": .string(g.gapToThree.display), "gapTo6Months": .string(g.gapToSix.display),
            ]),
            "savingsRate": .object([
                "rule": .string("20% of after-tax income to savings and debt (50/30/20, Warren & Tyagi)"),
                "averageTakeHome": .string(g.income.display), "twentyPercent": .string(g.twentyPercent.display),
                "savingNow": .string(g.savingNow.display), "savingNowShare": .string("\(g.savingNowPercent)%"),
            ]),
            "retirement": .string("Fidelity: 15% of pre-tax income including any employer match. Payroll 401(k) contributions don't show in the ledger (paychecks arrive net), so this can't be checked here."),
            "order": .string("Starter emergency fund → full employer match → high-interest debt → 3–6 month fund → retirement toward 15% → other goals (common practice, not a single source)"),
        ]), [Figure(id: "ef-3", label: "3-month emergency fund", detail: nil, value: g.threeMonths),
             Figure(id: "ef-gap", label: "Gap to 3 months", detail: nil, value: g.gapToThree),
             Figure(id: "rate-20", label: "20% of take-home", detail: nil, value: g.twentyPercent)])
    }

    func categorize(_ ids: JSONValue?) async throws -> (result: JSONValue, figures: [Figure]) {
        guard case let .array(values)? = ids else { throw BudgetAPIError.rejected("transactionIDs required") }
        let rows = values.compactMap { v -> LedgerTransaction? in
            guard case let .string(id) = v else { return nil }
            return ledger.transactions.first { $0.id == id }
        }
        let model = decisions ?? DemoDecisionModel(provider: .localDecide)
        let responses = try await model.decide(rows.map { CategoryDecisions.request(for: $0, categories: categories) })
        return (.object(["model": .string(model.label), "suggestions": .array(zip(rows, responses).map { row, response in
            let answer = response.answers[CategoryDecisions.questionID]
            return .object(["id": .string(row.id), "merchant": .string(row.merchant),
                            "ranked": .array((answer?.ranked ?? []).prefix(3).map { .object(["category": .string($0.id), "probability": .string("\(Int(($0.probability * 100).rounded()))%")]) })])
        })]), [])
    }

    // MARK: Dates

    private func isoDay(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: ledger.calendar.timeZone).year().month().day())
    }

    private func isoDate(_ s: String) -> Date? {
        guard let m = s.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/) else { return nil }
        return ledger.calendar.date(from: DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3)))
    }
}

extension DemoLedger {
    struct Guidance {
        var essentialMonthly: Money
        var threeMonths: Money
        var sixMonths: Money
        var cash: Money
        var gapToThree: Money
        var gapToSix: Money
        var income: Money
        var twentyPercent: Money
        var savingNow: Money
        var savingNowPercent: Int
    }

    func guidance() -> Guidance {
        let c = capacity()
        let three = Money(minorUnits: c.essentialMonthly.minorUnits * 3)
        let six = Money(minorUnits: c.essentialMonthly.minorUnits * 6)
        func gap(_ target: Money) -> Money { Money(minorUnits: max(0, target.minorUnits - c.cashOnHand.minorUnits)) }
        let twenty = Money(minorUnits: c.income.minorUnits / 5)
        let percent = c.income.minorUnits > 0 ? Int((Double(c.alreadySaving.minorUnits) / Double(c.income.minorUnits) * 100).rounded()) : 0
        return Guidance(essentialMonthly: c.essentialMonthly, threeMonths: three, sixMonths: six, cash: c.cashOnHand,
                        gapToThree: gap(three), gapToSix: gap(six), income: c.income, twentyPercent: twenty,
                        savingNow: c.alreadySaving, savingNowPercent: percent)
    }
}
