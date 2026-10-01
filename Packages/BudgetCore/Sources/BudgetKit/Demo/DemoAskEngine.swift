import Foundation

/// Routes a question to ledger tools and writes a templated reply around the results.
/// The server does this with the `chat` model under `AssistantPrompt`; the tool calls it
/// emits here use the same names and JSON argument shapes as `ToolCatalog` (tests enforce it).
struct DemoAskEngine {
    let ledger: DemoLedger
    var institutions: [InstitutionLink] = []
    static let modelLabel = "demo · templated, no model"

    private var calendar: Calendar { ledger.calendar }

    func answer(_ question: String, conversationID: String) -> AskReply {
        let q = question.lowercased()
        let category = matchedCategory(in: q)

        if q.contains("q3"), q.contains("q2") { return compareQuarters(category: category, conversationID: conversationID) }
        if let r = cancelIntent(q, conversationID) { return r }
        if let r = subscriptionIntent(q, conversationID) { return r }
        if let r = checkupIntent(q, conversationID) { return r }
        if let r = decisionIntent(q, conversationID) { return r }
        if let r = ruleIntent(q, conversationID) { return r }
        if let r = createCategoryIntent(q, conversationID) { return r }
        if let r = cashFlowIntent(q, conversationID) { return r }
        if let r = weekIntent(q, conversationID) { return r }
        if let r = pastMonthIntent(q, conversationID) { return r }
        if let r = idleCashIntent(q, conversationID) { return r }
        if let r = planningIntent(q, conversationID) { return r }
        if let r = merchantIntent(q, conversationID) { return r }
        if let r = suggestTargetsIntent(q, conversationID) { return r }
        if let r = categoryHistoryIntent(q, category, conversationID) { return r }
        if let r = targetIntent(q, category, conversationID) { return r }
        if let r = navigateIntent(q, category, conversationID) { return r }
        if ["afford", "set aside", "save "].contains(where: q.contains) { return goal(q, conversationID: conversationID) }
        if q.contains("subscription") { return subscriptions(conversationID: conversationID) }
        if let category { return categoryThisMonth(category, conversationID: conversationID) }
        if q.contains("where") || q.contains("this month") || q.contains("spend") { return whereItWent(conversationID: conversationID) }
        return reply(conversationID,
                     text: "I can answer what the ledger can compute — spending by category and period, cash flow, subscriptions, whether a goal fits — and propose changes like targets, categories and filing rules.",
                     followUps: ["Set the dining target to $500", "Always file Venmo as transfer", "Show me groceries"])
    }

    /// A reply is a fallback when it names no tool and proposes nothing — what every "Ask about this" button must avoid.
    static func isFallback(_ reply: AskReply) -> Bool { reply.toolCalls.isEmpty && reply.proposedActions.isEmpty }

    // MARK: Read intents

    private func compareQuarters(category: BudgetCategory?, conversationID: String) -> AskReply {
        let year = calendar.component(.year, from: ledger.now)
        let q3 = ledger.quarter(3, year: year)
        let q2 = ledger.quarter(2, year: year)
        let a = ledger.spent(from: q3.start, to: q3.end, categoryID: category?.id)
        let b = ledger.spent(from: q2.start, to: q2.end, categoryID: category?.id)
        let subject = category?.name.lowercased() ?? "everything"
        let partial = q3.end < calendar.date(byAdding: .month, value: 3, to: q3.start)!
        let through = partial ? " (through \(q3.end.formatted(.dateTime.month(.abbreviated).day())))" : ""
        let line = DemoLedger.comparisonLine(current: a, previous: b, against: "Q2")
        let text = "You spent \(a.formatted()) on \(subject) in Q3\(through), versus \(b.formatted()) in Q2. That's \(line.lowercased().replacingOccurrences(of: "q2", with: "Q2"))."
        var args: [String: JSONValue] = ["period": .string("\(year)-Q3"), "compareTo": .string("\(year)-Q2")]
        if let category { args["categoryID"] = .string(category.id) }
        return reply(conversationID, text: text,
                     figures: [
                         Figure(id: "q3", label: "Q3 \(year)", detail: partial ? "In progress" : nil, value: a),
                         Figure(id: "q2", label: "Q2 \(year)", detail: nil, value: b),
                         Figure(id: "diff", label: "Difference", detail: nil, value: a - b),
                     ],
                     tools: [call("sumByCategory", args)],
                     followUps: category.map { ["Set the \($0.name.lowercased()) target to $600", "Show me \($0.name.lowercased())"] } ?? [])
    }

    private func goal(_ q: String, conversationID: String) -> AskReply {
        let amount = Self.parseAmount(q) ?? Money(5000)
        let target = parseMonth(q) ?? calendar.date(byAdding: .month, value: 6, to: ledger.now)!
        let plan = ledger.projection(horizonMonths: 12, goal: GoalQuery(amount: amount, targetDate: target))
        let check = plan.goal!
        var figures = [
            Figure(id: "goal", label: "Goal", detail: target.formatted(.dateTime.month(.wide).year()), value: amount),
            Figure(id: "pace", label: "Projected by then", detail: "At \(plan.monthlyNet.formatted(fractionDigits: 0))/mo", value: check.projectedSavings),
            Figure(id: "need", label: "Needed per month", detail: nil, value: check.monthlyNeeded),
        ]
        if !check.isOnTrack { figures.append(Figure(id: "short", label: "Shortfall", detail: nil, value: check.shortfall)) }
        return reply(conversationID, text: check.summary, figures: figures,
                     tools: [call("projectBalance", [
                         "account": .string("cash"), "horizonMonths": .number(12),
                         "goal": .object(["amount": .string(DecimalAmount(amount).description), "targetDate": .string(isoDay(target))]),
                     ])],
                     followUps: check.isOnTrack ? ["Open the plan", "Where did my money go this month?"] : ["Open the plan", "What could I cut to close the gap?"])
    }

    /// Subscriptions as Recurring and the checkup find them (repeat charges), never a category's last month.
    private func subscriptions(conversationID: String) -> AskReply {
        let found = ledger.subscriptions()
        let subs = found.items.filter { $0.kind == .subscription && $0.status == .active }
        guard !subs.isEmpty else {
            return reply(conversationID, text: "No subscriptions turned up — nothing charges you on a steady schedule yet.",
                         tools: [call("findSubscriptions", [:])])
        }
        return reply(conversationID,
                     text: "You're paying for \(subs.count) subscription\(subs.count == 1 ? "" : "s"), about \(found.subscriptionsMonthly.formatted()) a month.",
                     figures: subs.map { Figure(id: $0.merchant, label: $0.merchant, detail: "A month", value: $0.monthlyCost) }
                         + [Figure(id: "m", label: "Subscriptions a month", detail: nil, value: found.subscriptionsMonthly)],
                     tools: [call("findSubscriptions", [:])], followUps: ["Which of my subscriptions could I cancel?"])
    }

    /// "Which could I cancel?": each subscription with its price, the priciest first, and what dropping it saves a year.
    private func cancelIntent(_ q: String, _ cid: String) -> AskReply? {
        guard q.contains("cancel"), ["subscription", "these", "recurring"].contains(where: q.contains) else { return nil }
        let found = ledger.subscriptions()
        let subs = found.items.filter { $0.kind == .subscription && $0.status == .active }.sorted { $0.monthlyCost > $1.monthlyCost }
        guard !subs.isEmpty else { return subscriptions(conversationID: cid) }
        var lines = ["You're paying for \(subs.count) subscription\(subs.count == 1 ? "" : "s"), about \(found.subscriptionsMonthly.formatted()) a month. The priciest first:"]
        lines += subs.prefix(8).map { "• \($0.merchant) — \($0.monthlyCost.formatted()) a month (\($0.yearlyCost.formatted()) a year)" }
        lines.append("Only you know which you still use; cancelling \(subs[0].merchant) alone saves \(subs[0].yearlyCost.formatted()) a year.")
        let figures = subs.flatMap { [Figure(id: "m-\($0.merchant)", label: "\($0.merchant) a month", detail: nil, value: $0.monthlyCost),
                                      Figure(id: "y-\($0.merchant)", label: "\($0.merchant) a year", detail: nil, value: $0.yearlyCost)] }
            + [Figure(id: "m", label: "Subscriptions a month", detail: nil, value: found.subscriptionsMonthly)]
        return reply(cid, text: lines.joined(separator: "\n"), figures: figures, tools: [call("findSubscriptions", [:])],
                     followUps: ["Open my recurring charges"])
    }

    private func categoryThisMonth(_ category: BudgetCategory, conversationID: String) -> AskReply {
        let month = ledger.interval(for: .thisMonth)
        let previous = ledger.previousInterval(for: .thisMonth)!
        let spent = ledger.spent(from: month.start, to: month.end, categoryID: category.id)
        let prior = ledger.spent(from: previous.start, to: previous.end, categoryID: category.id)
        var figures = [Figure(id: "now", label: "This month", detail: nil, value: spent),
                       Figure(id: "then", label: "Same point last month", detail: nil, value: prior)]
        var text = "\(category.name) is at \(spent.formatted()) this month — \(DemoLedger.comparisonLine(current: spent, previous: prior, against: "the same point last month").lowercased())."
        if let target = ledger.monthlyTargets[category.id] {
            figures.append(Figure(id: "target", label: "Monthly target", detail: nil, value: target))
            let days = ledger.flexBudget().daysLeftIncludingToday
            if spent > target {
                figures.append(Figure(id: "over", label: "Over the target", detail: nil, value: spent - target))
                text += " That's \((spent - target).formatted()) over its \(target.formatted(fractionDigits: 0)) target; anything more this month adds to it."
            } else {
                let left = target - spent
                let perDay = Money(minorUnits: left.minorUnits / Int64(max(days, 1)))
                figures += [Figure(id: "left", label: "Left of the target", detail: nil, value: left),
                            Figure(id: "per-day", label: "A day to stay under", detail: FlexBudget.daysLeftPhrase(days), value: perDay)]
                text += " Its target is \(target.formatted(fractionDigits: 0)), so \(left.formatted()) is left — about \(perDay.formatted()) a day for the \(days == 1 ? "last day" : "\(days) days left")."
            }
        }
        return reply(conversationID, text: text, figures: figures,
                     tools: [call("sumByCategory", ["categoryID": .string(category.id), "period": .string("this_month")])],
                     followUps: ["Raise the \(category.name.lowercased()) target by $50", "Show me \(category.name.lowercased())"])
    }

    private func whereItWent(conversationID: String) -> AskReply {
        let summary = ledger.spendingSummary(.thisMonth)
        let top = summary.categories.prefix(4)
        let names = top.prefix(3).map(\.category.name.localizedLowercase)
        return reply(conversationID,
                     text: "\(summary.total.formatted()) has gone out so far this month. Most of it went to \(Array(names).spokenList).",
                     figures: top.map { Figure(id: $0.id, label: $0.category.name, detail: Self.transactions($0.transactionCount), value: $0.spent) }
                         + [Figure(id: "total", label: "Total so far", detail: nil, value: summary.total)],
                     tools: [call("sumByCategory", ["period": .string("this_month")])],
                     followUps: ["Show me spending"])
    }

    /// "1 transaction", "4 transactions".
    static func transactions(_ n: Int) -> String { "\(n) transaction\(n == 1 ? "" : "s")" }

    // MARK: Per-card questions — each "Ask about this" button lands on an answer to what it asked

    /// "How has my cash flow changed?", "What's driving my cash down?" → the months Plan's cash flow card shows.
    private func cashFlowIntent(_ q: String, _ cid: String) -> AskReply? {
        guard ["cash flow", "cashflow", "cash down", "driving my cash", "cash going down", "income and spending"].contains(where: q.contains) else { return nil }
        let flows = ledger.cashFlowHistory(months: 6)
        let complete = flows.filter { !$0.isPartial }
        let out = toolbox.cashFlow(months: 6)
        guard let latest = complete.last, let first = complete.first else {
            return reply(cid, text: "There isn't a full month in the ledger yet, so there's no cash flow to compare.", figures: out.figures,
                         tools: [call("cashFlow", ["months": .number(6)])])
        }
        let income = DemoLedger.average(complete.map(\.income)), spending = DemoLedger.average(complete.map(\.spending))
        let net = DemoLedger.average(complete.map(\.net))
        let worst = complete.min { $0.net < $1.net }!
        var lines = ["Over the last \(complete.count) full month\(complete.count == 1 ? "" : "s"), income averaged \(income.formatted()) and spending \(spending.formatted()), so about \(net.formatted()) a month was left over."]
        if complete.count > 1 {
            let change = latest.spending - first.spending
            lines.append("Spending went from \(first.spending.formatted()) in \(monthName(first.month)) to \(latest.spending.formatted()) in \(monthName(latest.month))\(change.isNegative ? ", down \(change.magnitude.formatted())" : change.minorUnits > 0 ? ", up \(change.formatted())" : "").")
        }
        if worst.net.isNegative { lines.append("\(monthName(worst.month)) spent \(worst.net.magnitude.formatted()) more than came in.") }
        return reply(cid, text: lines.joined(separator: " "),
                     figures: out.figures + [Figure(id: "avg-in", label: "Average income", detail: nil, value: income),
                                             Figure(id: "avg-out", label: "Average spending", detail: nil, value: spending),
                                             Figure(id: "avg-net", label: "Average left over", detail: nil, value: net)],
                     tools: [call("cashFlow", ["months": .number(6)])], followUps: ["Where did my money go this month?", "How much can I save each month?"])
    }

    /// "Where did my everyday spending go in the last 7 days?" → the week the strip shows, by category.
    private func weekIntent(_ q: String, _ cid: String) -> AskReply? {
        guard ["last 7 days", "last seven days", "past week", "last week", "this week"].contains(where: q.contains) else { return nil }
        let window = ledger.interval(forPeriod: "last_7_days")!
        let flexible = ledger.sumByCategory(from: window.start, to: window.end, includeTargets: false)
            .filter { $0.category.group == .everyday && $0.spent.minorUnits > 0 }
        let total = ledger.everydaySpent(from: window.start, to: window.end)
        let out = try? toolbox.sumByCategory(period: "last_7_days", compareTo: nil, categoryID: nil)
        let figures = [Figure(id: "week", label: "Everyday · last 7 days", detail: nil, value: total)]
            + flexible.prefix(4).map { Figure(id: "week-\($0.category.id)", label: $0.category.name, detail: Self.transactions($0.transactionCount), value: $0.spent) }
            + (out?.figures ?? [])
        let text = total.minorUnits == 0 ? "No everyday spending in the last 7 days."
            : "\(total.formatted()) of everyday spending in the last 7 days, most of it \(flexible.prefix(3).map { "\($0.category.name.lowercased()) (\($0.spent.formatted()))" }.spokenList)."
        return reply(cid, text: text, figures: figures, tools: [call("sumByCategory", ["period": .string("last_7_days")])],
                     followUps: ["What's safe to spend this month?"])
    }

    /// "How did my everyday spending go in August?" → that month's budget as it ended.
    private func pastMonthIntent(_ q: String, _ cid: String) -> AskReply? {
        guard q.contains("flex") || q.contains("budget") || q.contains("everyday"), let key = pastMonthKey(q), let month = try? ledger.budgetMonth(key), !month.isCurrent else { return nil }
        let name = ledger.monthStart(key).map { $0.formatted(DemoLedger.monthStyle(calendar, year: false)) } ?? key
        let flex = month.flex
        var figures = [Figure(id: "spent-\(key)", label: "Everyday spent · \(name)", detail: nil, value: flex.flexSpent)]
        let text: String
        if month.hasFullHistory == false {
            text = "\(name) was early in the ledger, so there weren't three full months before it to budget from. Everyday spending came to \(flex.flexSpent.formatted())."
        } else {
            figures += [Figure(id: "budget-\(key)", label: "Everyday budget · \(name)", detail: nil, value: flex.flexNumber),
                        Figure(id: "left-\(key)", label: flex.safeToSpend.isNegative ? "Over" : "Left over", detail: nil, value: flex.safeToSpend.magnitude)]
            text = "In \(name) everyday spending came to \(flex.flexSpent.formatted()) of a \(flex.flexNumber.formatted()) everyday budget — "
                + (flex.safeToSpend.isNegative ? "\(flex.safeToSpend.magnitude.formatted()) over." : "\(flex.safeToSpend.formatted()) left over.") + " \(month.summary)"
        }
        return reply(cid, text: text, figures: figures, tools: [call("sumByCategory", ["period": .string(key)])],
                     followUps: ["What's safe to spend this month?"])
    }

    /// "Where should the extra cash in checking go?" → checking against the cushion the bills need.
    private func idleCashIntent(_ q: String, _ cid: String) -> AskReply? {
        guard ["extra cash", "cash in checking", "idle cash", "too much in checking"].contains(where: q.contains) else { return nil }
        let c = ledger.capacity()
        let checking = ledger.accounts.filter { $0.kind == .checking }.map { ledger.balance(of: $0.id, through: ledger.now) }.sum()
        let cushion = Money(minorUnits: c.essentialMonthly.minorUnits * 3 / 2)
        let extra = Money(minorUnits: max(0, (checking - cushion).minorUnits))
        let g = ledger.guidance()
        let out = toolbox.savingsGuidance()
        var text = "Checking holds \(checking.formatted()); a month and a half of essentials is about \(cushion.formatted()), so \(extra.formatted()) is more than the bills need."
        text += g.gapToThree.minorUnits > 0
            ? " Moving it to savings first builds your emergency fund: you're \(g.gapToThree.formatted()) short of three months of essentials (\(g.threeMonths.formatted()))."
            : " Your cash already covers three months of essentials, so savings — or investing — would put it to work."
        return reply(cid, text: text,
                     figures: out.figures + [Figure(id: "checking", label: "In checking", detail: nil, value: checking),
                                             Figure(id: "cushion", label: "A month and a half of essentials", detail: nil, value: cushion),
                                             Figure(id: "extra", label: "More than the bills need", detail: nil, value: extra)],
                     tools: [call("savingsGuidance", [:])], followUps: ["How much should I be saving?"])
    }

    /// "How has my dining spending changed over the last year?" → the category's months.
    private func categoryHistoryIntent(_ q: String, _ category: BudgetCategory?, _ cid: String) -> AskReply? {
        guard let category, category.countsAsSpending,
              ["last year", "over the year", "over time", "changed", "history", "month by month", "past year"].contains(where: q.contains),
              let history = try? ledger.categoryHistory(category.id, months: 12), let out = try? toolbox.categoryHistory(category.id, months: 12) else { return nil }
        let full = history.months.dropLast()
        let name = category.name
        var lines: [String] = []
        if history.monthsAveraged > 0 {
            lines.append("\(name) has averaged \(history.averageMonthly.formatted()) a month over \(history.monthsAveraged) full month\(history.monthsAveraged == 1 ? "" : "s").")
        }
        if let high = full.max(by: { $0.spent < $1.spent }), let low = full.min(by: { $0.spent < $1.spent }), high.month != low.month {
            lines.append("The most was \(high.spent.formatted()) in \(monthName(high.month)), the least \(low.spent.formatted()) in \(monthName(low.month)).")
        }
        if let now = history.months.last { lines.append("This month is at \(now.spent.formatted()) so far.") }
        if lines.isEmpty { lines.append("There isn't enough history for \(name.lowercased()) yet.") }
        return reply(cid, text: lines.joined(separator: " "), figures: out.figures,
                     tools: [call("categoryHistory", ["categoryID": .string(category.id), "months": .number(12)])],
                     followUps: ["Show me \(name.lowercased())"])
    }

    /// "Suggest targets for dining and transport from my last three months." → each one's recent average.
    private func suggestTargetsIntent(_ q: String, _ cid: String) -> AskReply? {
        guard q.contains("suggest"), q.contains("target") else { return nil }
        let named = ledger.activeCategories.filter { $0.countsAsSpending && q.contains($0.name.lowercased()) }
        guard !named.isEmpty else { return nil }
        var figures: [Figure] = [], lines: [String] = [], followUps: [String] = []
        for category in named {
            guard let history = try? ledger.categoryHistory(category.id, months: 4) else { continue }
            // Rounded up to the next $10, so a typical month fits.
            let suggested = Money(minorUnits: (history.averageMonthly.minorUnits + 999) / 1000 * 1000)
            figures.append(Figure(id: "avg-\(category.id)", label: "\(category.name) · 3-month average", detail: nil, value: history.averageMonthly))
            lines.append("• \(category.name): about \(history.averageMonthly.formatted()) a month, so \(suggested.formatted(fractionDigits: 0)) fits a typical month.")
            followUps.append("Set the \(category.name.lowercased()) target to \(suggested.formatted(fractionDigits: 0))")
        }
        guard !lines.isEmpty else { return nil }
        return reply(cid, text: (["From your last three full months:"] + lines).joined(separator: "\n"), figures: figures,
                     tools: named.map { call("categoryHistory", ["categoryID": .string($0.id), "months": .number(4)]) }, followUps: followUps)
    }

    /// "September" for "2026-09".
    private func monthName(_ key: String) -> String {
        ledger.monthStart(key).map { $0.formatted(DemoLedger.monthStyle(calendar, year: false)) } ?? key
    }

    /// The most recent month named in the question that has started ("august" in September → this year's August).
    private func pastMonthKey(_ q: String) -> String? {
        let names = calendar.monthSymbols.map { $0.lowercased() }
        guard let index = names.firstIndex(where: q.contains) else { return nil }
        var components = calendar.dateComponents([.year], from: ledger.now)
        components.month = index + 1
        components.day = 1
        guard var date = calendar.date(from: components) else { return nil }
        if date > ledger.now { date = calendar.date(byAdding: .year, value: -1, to: date)! }
        return ledger.monthKey(date)
    }

    // MARK: Near-term planning — same toolbox the live agent uses, templated prose

    private var toolbox: DemoToolbox { DemoToolbox(ledger: ledger, decisions: nil) }

    /// "What subscriptions am I paying for?" → one findSubscriptions call.
    private func subscriptionIntent(_ q: String, _ cid: String) -> AskReply? {
        guard ["subscription", "recurring", "paying for every", "what am i paying for"].contains(where: q.contains), !q.contains("cancel"),
              // "Open my recurring charges" asks for the screen, not a list.
              !["open ", "go to", "take me", "pull up"].contains(where: q.contains) else { return nil }
        let found = ledger.subscriptions()
        let subs = found.items.filter { $0.kind == .subscription && $0.status == .active }
        guard !subs.isEmpty else { return nil }
        var lines = ["You're paying for \(subs.count) subscription\(subs.count == 1 ? "" : "s"), about \(found.subscriptionsMonthly.formatted()) a month (\(found.subscriptionsYearly.formatted()) a year):"]
        lines += subs.prefix(8).map { "• \($0.merchant) — \($0.amount.formatted()) \($0.cadence.rawValue)" }
        if found.billsMonthly.minorUnits > 0 { lines.append("Bills like rent and utilities add \(found.billsMonthly.formatted()) a month.") }
        let figures = [Figure(id: "m", label: "Subscriptions a month", detail: nil, value: found.subscriptionsMonthly),
                       Figure(id: "y", label: "Subscriptions a year", detail: nil, value: found.subscriptionsYearly),
                       Figure(id: "b", label: "Bills a month", detail: nil, value: found.billsMonthly)]
            + subs.map { Figure(id: $0.merchant, label: $0.merchant, detail: nil, value: $0.amount) }
        return reply(cid, text: lines.joined(separator: "\n"), figures: figures, tools: [call("findSubscriptions", [:])],
                     followUps: ["Which of my subscriptions could I cancel?", "Run a checkup"])
    }

    /// "Check everything", "how am I doing", "give me a review" → one runCheckup call, led by what needs action.
    private func checkupIntent(_ q: String, _ cid: String) -> AskReply? {
        let asks = ["checkup", "check-up", "check everything", "check it all", "how am i doing", "full review", "assess", "overall", "look over everything"]
        guard asks.contains(where: q.contains) else { return nil }
        let checkup = ledger.checkup(institutions: institutions)
        let ranked = checkup.sections.flatMap(\.findings).filter { $0.status != .good }.sorted { $0.status > $1.status }
        var lines = [checkup.headline]
        lines += ranked.prefix(4).map { "• \($0.title)" }
        if ranked.isEmpty { lines.append("Categories are on track, saving fits, and nothing unusual turned up.") }
        let figures = checkup.sections.flatMap(\.findings).flatMap { f in f.metrics.compactMap { m in m.money.map { Figure(id: "\(f.id)-\(m.label)", label: m.label, detail: f.title, value: $0) } } }
        return reply(cid, text: lines.joined(separator: "\n"), figures: figures, tools: [call("runCheckup", [:])],
                     followUps: ranked.compactMap(\.suggestion).prefix(3).map { $0 })
    }

    private func planningIntent(_ q: String, _ cid: String) -> AskReply? {
        let perMonth = ["a month", "per month", "each month", "every month", "monthly"].contains(where: q.contains)
        if perMonth, ["set aside", "save ", "put away", "savings to"].contains(where: q.contains), !q.contains("can i"), !q.contains("should"),
           let amount = Self.parseAmount(q) {
            return proposal(.setMonthlySavings(SetMonthlySavings(monthlyAmount: DecimalAmount(amount))), cid,
                            lead: "Here's that plan: savings come off the top, and safe-to-spend follows. It takes effect if you apply it.")
        }
        if (q.contains("should") && (q.contains("save") || q.contains("saving"))) || ["months of essentials", "emergency fund"].contains(where: q.contains) {
            let out = toolbox.savingsGuidance()
            let g = ledger.guidance()
            let fund = g.gapToThree.minorUnits == 0
                ? "Your cash already covers three months of essentials (\(g.threeMonths.display)), the low end of the 3–6 month emergency fund rule."
                : "You're \(g.gapToThree.display) short of three months of essentials (\(g.threeMonths.display)), the low end of the 3–6 month emergency fund rule."
            return reply(cid, text: "\(fund) The 50/30/20 rule puts savings at 20% of take-home, about \(g.twentyPercent.display) a month; you're moving \(g.savingNow.display) now.",
                         figures: out.figures, tools: [call("savingsGuidance", [:])],
                         followUps: ["How much can I save each month?", "Set aside \(g.twentyPercent.formatted(fractionDigits: 0)) a month"])
        }
        if ["can i save", "could i save", "able to save", "savings amount", "save each month"].contains(where: q.contains) {
            let out = toolbox.savingsCapacity(months: 3)
            let c = ledger.capacity()
            return reply(cid, text: "Over the last three months you could save about \(c.typical.display) a month, or up to \(c.stretch.display) holding everyday spending to your lowest month. You're moving \(c.alreadySaving.display) to savings now.",
                         figures: out.figures, tools: [call("savingsCapacity", ["months": .number(3)])],
                         followUps: ["How much should I be saving?", "What's safe to spend this month?"])
        }
        if q.contains("safe to spend") || q.contains("can i spend") || q.contains("left to spend") || q.contains("flex") {
            let out = toolbox.flexBudget()
            let f = ledger.flexBudget()
            let days = f.daysLeftIncludingToday
            return reply(cid, text: "After bills, subscriptions and \(f.plannedSavings.display) of savings, your everyday budget is \(f.flexNumber.display). You've spent \(f.flexSpent.display) of it, so \(f.safeToSpend.display) is safe to spend \(days <= 1 ? "on the month's last day" : "in the \(days) days left")\(f.safeToSpend.isNegative ? " — you're past it" : "").",
                         figures: out.figures, tools: [call("flexBudget", [:])])
        }
        return nil
    }

    /// "What's my DoorDash budget?", "Cap DoorDash at $150".
    private func merchantIntent(_ q: String, _ cid: String) -> AskReply? {
        guard matchedCategory(in: q, includeNonSpending: true) == nil,
              let merchant = ledger.merchant(mentionedIn: q) else { return nil }
        let wantsCap = ["cap", "limit", "budget", "target"].contains(where: q.contains)
        guard wantsCap || q.contains("spend") else { return nil }
        if wantsCap, let amount = Self.parseAmount(q), ["cap", "set", "limit", "to $", "at $"].contains(where: q.contains) {
            return proposal(.setMerchantTarget(SetMerchantTarget(merchant: merchant, monthlyAmount: DecimalAmount(amount))), cid,
                            lead: "Here's a cap for \(merchant). Going over is flagged, never blocked.")
        }
        if wantsCap, ["remove", "delete", "drop"].contains(where: q.contains) {
            return proposal(.removeMerchantTarget(RemoveMerchantTarget(merchant: merchant)), cid, lead: "Here's that change.")
        }
        guard let out = try? toolbox.sumByMerchant(merchant, period: "this_month", compareTo: nil) else { return nil }
        let month = ledger.interval(for: .thisMonth)
        let spent = ledger.merchantSpend(merchant, from: month.start, to: month.end)
        let average = ledger.merchantMonthlyAverage(merchant)
        let capLine = ledger.merchantTargets[merchant].map { " Your cap is \($0.display)." } ?? " There's no cap on \(merchant) yet."
        return reply(cid, text: "\(merchant) is at \(spent.total.display) this month across \(spent.count) orders, against a three-month average of \(average.display).\(capLine)",
                     figures: out.figures, tools: [call("sumByMerchant", ["merchant": .string(merchant), "period": .string("this_month")])],
                     followUps: ["Cap \(merchant) at \(Money(minorUnits: (average.minorUnits / 1000) * 1000).formatted(fractionDigits: 0)) a month"])
    }

    // MARK: Change intents — each returns a proposal, never a change

    private func decisionIntent(_ q: String, _ cid: String) -> AskReply? {
        let triggers = ["decision model", "auto-accept", "auto accept", "autoaccept", "jev", "laya", "qwen decide", "threshold"]
        guard triggers.contains(where: q.contains) else { return nil }
        var provider: DecisionProvider?
        if ["turn off", "disable", "stop using", "switch off"].contains(where: q.contains) { provider = .off }
        else if q.contains("jev") { provider = .jev }
        else if q.contains("laya") { provider = .laya }
        else if q.contains("qwen") || q.contains("local") { provider = .localDecide }
        else if ["turn on", "enable", "use", "start"].contains(where: q.contains) {
            provider = ledger.decisionPolicy.isActive ? nil : .localDecide
        }
        let percent = q.firstMatch(of: /(\d{2})\s?(?:%|percent)/).flatMap { Int($0.1) }
        var escalate: Bool?
        if ["escalate", "fall back", "fallback", "backup", "second opinion"].contains(where: q.contains) {
            escalate = !["don't", "stop", "no longer", "without"].contains(where: q.contains)
            if provider == .jev { provider = ledger.decisionPolicy.isActive && ledger.decisionPolicy.provider.runsLocally ? nil : .localDecide }
        }
        guard provider != nil || percent != nil || escalate != nil else {
            let policy = ledger.decisionPolicy
            return reply(cid, text: policy.isActive
                ? "The decision model is \(policy.provider.displayName), auto-accepting at \(policy.autoAcceptPercent)% and above. Anything less sure comes to you for review."
                : "The decision model is off, so every uncertain transaction comes to you. Turning it on lets it file the ones it's sure about.",
                followUps: policy.isActive ? ["Auto-accept above 90%", "Turn off the decision model"] : ["Turn on the decision model at 80%"])
        }
        return proposal(.updateDecisionPolicy(UpdateDecisionPolicy(provider: provider, autoAcceptPercent: percent, escalateToJev: escalate, rerunPending: true)), cid,
                        lead: "Here's that change to the decision model. It only takes effect if you apply it.")
    }

    private func ruleIntent(_ q: String, _ cid: String) -> AskReply? {
        guard ["always", "from now on", "every time", "whenever"].contains(where: q.contains),
              let m = q.firstMatch(of: /(?:categorize|categorise|file|put|treat|count|mark|classify)\s+(?:all\s+|my\s+|any\s+|the\s+)?(.+?)\s+(?:charges\s+|payments\s+|transactions\s+|purchases\s+)?(?:as|under|in|into)\s+(?:a\s+|an\s+)?(.+)/)
        else { return nil }
        let term = String(m.1).trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else { return nil }
        guard let category = matchedCategory(in: String(m.2), includeNonSpending: true) else {
            return reply(cid, text: "Which category should “\(term)” go under?", followUps: ledger.activeCategories.prefix(4).map { "Always file \(term) as \($0.name.lowercased())" })
        }
        return proposal(.createBudgetRule(CreateBudgetRule(match: .init(merchantContains: term), categoryID: category.id, applyToExisting: true)), cid,
                        lead: "Here's a rule for that. Nothing is re-filed until you apply it.")
    }

    private func createCategoryIntent(_ q: String, _ cid: String) -> AskReply? {
        guard let m = q.firstMatch(of: /(?:add|create|make|new)\s+(?:a\s+)?(?:new\s+)?category\s+(?:for|called|named)\s+([a-z][a-z &'\-]{0,30}?)(?:\s+(?:with|at|and|of)\b.*)?[.?!]?$/) else { return nil }
        let name = String(m.1).trimmingCharacters(in: .whitespaces).capitalized
        let symbols = ["pets": "pawprint", "pet": "pawprint", "kids": "figure.and.child.holdinghands", "childcare": "figure.and.child.holdinghands",
                       "gifts": "gift", "gift": "gift", "education": "graduationcap", "coffee": "cup.and.saucer", "home": "hammer", "charity": "hands.sparkles"]
        let target = Self.parseAmount(q).map(DecimalAmount.init)
        return proposal(.createCategory(CreateCategory(name: name, symbol: symbols[name.lowercased()], monthlyTarget: target)), cid,
                        lead: "Here's the new category. It's added when you apply it.")
    }

    private func targetIntent(_ q: String, _ category: BudgetCategory?, _ cid: String) -> AskReply? {
        guard ["target", "budget", "limit", "cap"].contains(where: q.contains), let category else { return nil }
        // "How can I keep dining under its target?" asks about spending, not for a new target.
        if Self.parseAmount(q) == nil, ["how ", "why ", "where ", "what ", "am i", "is my"].contains(where: q.hasPrefix) { return nil }
        let lead = "Here's that change. It only happens if you apply it."
        if ["remove", "delete", "drop the", "clear", "get rid of", "no longer"].contains(where: q.contains) {
            return proposal(.removeCategoryTarget(RemoveCategoryTarget(categoryID: category.id)), cid, lead: lead)
        }
        guard let amount = Self.parseAmount(q) else {
            return reply(cid, text: "What should the \(category.name.lowercased()) target be?",
                         followUps: ["Set the \(category.name.lowercased()) target to $400", "Raise the \(category.name.lowercased()) target by $50"])
        }
        if q.contains(" by ") {
            let raise = ["raise", "increase", "bump", " up ", "add", "more"].contains(where: q.contains)
            let lower = ["lower", "decrease", "reduce", "cut", "drop", "less", "trim"].contains(where: q.contains)
            if raise != lower {
                let change = DecimalAmount(minorUnits: raise ? amount.minorUnits : -amount.minorUnits)
                return proposal(.adjustCategoryTarget(AdjustCategoryTarget(categoryID: category.id, change: change)), cid, lead: lead)
            }
        }
        return proposal(.setCategoryTarget(SetCategoryTarget(categoryID: category.id, monthlyAmount: DecimalAmount(amount))), cid, lead: lead)
    }

    private func navigateIntent(_ q: String, _ category: BudgetCategory?, _ cid: String) -> AskReply? {
        guard ["show me", "open", "go to", "take me", "pull up", "see my"].contains(where: q.contains) else { return nil }
        let action: Navigate
        if let category { action = Navigate(screen: .spending, categoryID: category.id) }
        else if q.contains("recurring") || q.contains("bills") { action = Navigate(screen: .recurring) }
        else if q.contains("plan") || q.contains("forecast") { action = Navigate(screen: .plan) }
        else if q.contains("review") || q.contains("activity") || q.contains("transactions") { action = Navigate(screen: .activity) }
        else if q.contains("setting") { action = Navigate(screen: .settings) }
        else if q.contains("spending") { action = Navigate(screen: .spending) }
        else if q.contains("home") { action = Navigate(screen: .home) }
        else { return nil }
        return proposal(.navigate(action), cid, lead: "Here's where to look.")
    }

    private func proposal(_ action: AppAction, _ cid: String, lead: String) -> AskReply {
        do {
            let preview = try ledger.preview(action)
            let proposed = ProposedAction(id: UUID().uuidString, action: action.proposedByAssistant(), title: preview.title, detail: preview.detail, effects: preview.effects)
            let args = String(decoding: try action.argumentsJSON(), as: UTF8.self)
            return reply(cid, text: lead, tools: [ToolCall(id: "w1", name: action.toolName, arguments: args)], actions: [proposed])
        } catch {
            return reply(cid, text: error.localizedDescription)
        }
    }

    // MARK: Parsing

    private func matchedCategory(in q: String, includeNonSpending: Bool = false) -> BudgetCategory? {
        let synonyms = ["eating out": "dining", "restaurant": "dining", "food": "dining", "coffee": "dining",
                        "rent": "housing", "gas": "transport", "uber": "transport", "grocer": "groceries"]
        for (word, id) in synonyms where q.contains(word) { return ledger.category(id) }
        return ledger.activeCategories.first { ($0.countsAsSpending || includeNonSpending) && (q.contains($0.name.lowercased()) || q.contains($0.id)) }
    }

    /// Prefers an explicit "$" amount; falls back to a bare number.
    static func parseAmount(_ q: String) -> Money? {
        func money(_ digits: Substring, thousands: Bool) -> Money? {
            guard var value = Decimal(string: digits.replacingOccurrences(of: ",", with: "")) else { return nil }
            if thousands { value *= 1000 }
            return Money(value)
        }
        if let m = q.firstMatch(of: /\$\s?(\d[\d,]*(?:\.\d{1,2})?)\s?(k)?\b/) { return money(m.1, thousands: m.2 != nil) }
        if let m = q.firstMatch(of: /(?:^|\s)(\d[\d,]*(?:\.\d{1,2})?)\s?(k)?(?:\s|$|[.?!,])/) { return money(m.1, thousands: m.2 != nil) }
        return nil
    }

    private func parseMonth(_ q: String) -> Date? {
        let names = calendar.monthSymbols.map { $0.lowercased() }
        guard let index = names.firstIndex(where: q.contains) else { return nil }
        let now = ledger.now
        var components = calendar.dateComponents([.year], from: now)
        components.month = index + 1
        components.day = 1
        guard var date = calendar.date(from: components) else { return nil }
        if date <= now { date = calendar.date(byAdding: .year, value: 1, to: date)! }
        return date
    }

    private func isoDay(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day())
    }

    private func call(_ name: String, _ args: [String: JSONValue]) -> ToolCall {
        let json = (try? JSONValue.object(args).data()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ToolCall(id: UUID().uuidString, name: name, arguments: json)
    }

    private func reply(_ conversationID: String, text: String, figures: [Figure] = [], tools: [ToolCall] = [],
                       followUps: [String] = [], actions: [ProposedAction] = []) -> AskReply {
        AskReply(id: UUID().uuidString, conversationID: conversationID, text: text, figures: figures, toolCalls: tools,
                 model: Self.modelLabel, followUps: followUps, proposedActions: actions)
    }
}
