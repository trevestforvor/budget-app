import Foundation

/// What an action reaches, as the ledger has it now: a fingerprint of those rows and how many there are. An Ask
/// proposal carries the fingerprint; applying it checks the ledger still gives the same one.
public struct ActionBasis: Codable, Hashable, Sendable {
    public var fingerprint: String
    public var rowCount: Int

    public init(fingerprint: String, rowCount: Int) { self.fingerprint = fingerprint; self.rowCount = rowCount }
}

extension Ledger {
    /// The basis of `action`: the rows it reaches and the stored values it reads (a target, a rule, a category), so a
    /// proposal made before any of them changed is refused rather than applied to data it never saw. Nil for actions
    /// that read nothing worth guarding (navigate, rememberFact, a new category). Figures worked out from the rows
    /// ("spent this month") are left out on purpose: any sync would move them and refuse every proposal.
    ///
    /// Throws `.notFound` when a row or item the action names is gone, and whatever `perform` would refuse.
    func basis(for action: AppAction) throws -> ActionBasis? {
        guard let reach = try reach(action) else { return nil }
        let stamps = reach.rows.sorted { $0.id < $1.id }.map(Self.stamp)
        let text = (stamps + reach.values).joined(separator: "\n")
        return ActionBasis(fingerprint: "v1:" + StableHash.hex128(text), rowCount: reach.rows.count)
    }

    /// Every row the action reaches — the same rows its preview counts.
    func reachedRows(_ action: AppAction) throws -> [LedgerTransaction] {
        try reach(action)?.rows ?? []
    }

    /// A proposal card for `action` as the ledger stands: its preview, plus the basis, count and sample that apply
    /// checks and shows.
    func proposal(for action: AppAction) throws -> ProposedAction {
        var preview = try preview(action)
        preview.basis = try basis(for: action)?.fingerprint
        return ProposedAction(action: action, preview: preview, timeZone: calendar.timeZone) { category($0)?.name }
    }

    /// The rows `rule` matches, and of those the ones it wins among `list` (the rules after the change): a newer rule
    /// that also matches keeps its rows.
    func ruleMatches(_ rule: BudgetRule, in list: [BudgetRule]) -> (rows: [LedgerTransaction], winners: [LedgerTransaction]) {
        let known = Set(activeCategories.map(\.id))
        let (candidate, book) = (RuleMatcher(rule, filesMoneyIn: isMoneyIn(rule.categoryID)), ruleBook(list))
        var rows: [LedgerTransaction] = [], winners: [LedgerTransaction] = []
        for row in transactions {
            let text = RuleText(row)
            guard candidate.applies(to: row, text) else { continue }
            rows.append(row)
            if book.winner(for: row, text, known: known)?.id == rule.id { winners.append(row) }
        }
        return (rows, winners)
    }

    // MARK: Reach

    /// The rows an action reaches and the stored values it reads, as `key=value` lines.
    private func reach(_ action: AppAction) throws -> (rows: [LedgerTransaction], values: [String])? {
        switch action {
        case let .setCategoryTarget(p): return ([], ["target=" + Self.value(monthlyTargets[p.categoryID])])
        // A change is relative to the target it was proposed against, so a changed target must refuse.
        case let .adjustCategoryTarget(p): return ([], ["target=" + Self.value(monthlyTargets[p.categoryID])])
        case let .removeCategoryTarget(p): return ([], ["target=" + Self.value(monthlyTargets[p.categoryID])])
        case let .setMerchantTarget(p): return ([], ["cap=" + Self.value(merchantCap(p.merchant))])
        case let .removeMerchantTarget(p): return ([], ["cap=" + Self.value(merchantCap(p.merchant))])
        case .setMonthlySavings: return ([], ["savings=" + Self.value(monthlySavings)])
        case .createCategory, .restoreTransactions, .rememberFact, .navigate: return nil

        case let .updateCategory(p): return ([], ["category=" + Self.json(category(p.categoryID))])
        case let .mergeCategory(p):
            let plan = try mergePlan(p)
            return (plan.rows.map { transactions[$0] }, ["from=" + Self.json(categories[plan.from]), "into=" + Self.json(categories[plan.into])])

        case let .createBudgetRule(p):
            let category = try activeCategory(p.categoryID)
            let rule = BudgetRule(id: BudgetRule.nextID(after: rules, stampedOn: transactions), match: try validatedMatch(p.match, categoryID: category.id), categoryID: category.id)
            return ruleReach(rule, in: rules + [rule], values: [])
        case let .updateBudgetRule(p):
            let (index, rule) = try updatedRule(p)
            var list = rules
            list[index] = rule
            return ruleReach(rule, in: list, values: ["rule=" + Self.json(rules[index])])
        case let .deleteBudgetRule(p):
            guard let rule = rules.first(where: { $0.id == p.ruleID }) else { throw BudgetAPIError.notFound }
            return (transactions.filter { $0.categorization?.ruleID == rule.id }, ["rule=" + Self.json(rule)])

        case let .recategorize(p):
            let rows = try p.transactionIDs.map { id in
                guard let row = transactions.first(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
                return row
            }
            return (rows, [])
        case let .editTransactions(p):
            let plan = try editPlan(p)
            var seen = Set<Int>()
            return ((plan.rows + plan.renamed + plan.similar).filter { seen.insert($0).inserted }.map { transactions[$0] }, [])

        case .updateDecisionPolicy: return ([], ["policy=" + Self.json(decisionPolicy)])
        case let .forgetMerchant(p): return (try forgetPlan(p).rows, [])
        case let .setRecurring(p):
            let plan = try recurringPlan(p)
            return (plan.rows, ["choice=" + Self.json(plan.previous)])
        case let .reviewRecurring(p):
            let key = RecurringChoice.key(p.merchant)
            return (transactions.filter { RecurringChoice.key($0.merchant) == key && $0.amount.isNegative }, ["mark=" + Self.json(recurringReviews[key])])

        case let .saveManualAsset(p):
            guard let id = p.id ?? p.restore?.id else { return nil }
            return ([], ["asset=" + Self.json(manualAssets.first { $0.id == id })])
        case let .removeManualAsset(p):
            guard let asset = manualAssets.first(where: { $0.id == p.id }) else { throw BudgetAPIError.notFound }
            return ([], ["asset=" + Self.json(asset)])
        case let .savePlanScenario(p):
            guard let id = p.scenarioID else { return nil }
            return ([], ["scenario=" + Self.json(planScenarios.first { $0.id == id })])
        case let .deletePlanScenario(p): return ([], ["scenario=" + Self.json(try planScenario(p.scenarioID))])
        }
    }

    /// A rule's matches, and which of them it wins: a new or changed rule elsewhere moves what re-filing reaches.
    private func ruleReach(_ rule: BudgetRule, in list: [BudgetRule], values: [String]) -> (rows: [LedgerTransaction], values: [String]) {
        let (rows, winners) = ruleMatches(rule, in: list)
        return (rows, values + ["wins=" + winners.map(\.id).sorted().joined(separator: ",")])
    }

    /// The cap kept for a merchant, matched as the ledger matches merchant names.
    private func merchantCap(_ merchant: String) -> Money? {
        let name = (try? knownMerchant(merchant)) ?? merchant
        return merchantTargets.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// One row as the basis sees it: everything an action reads or changes on it, and nothing derived.
    private static func stamp(_ row: LedgerTransaction) -> String {
        let c = row.categorization
        let fields: [String] = [
            row.id, c?.categoryID ?? "", c?.tier.rawValue ?? "", c.map { $0.needsReview ? "1" : "0" } ?? "", row.isHidden ? "1" : "0",
            row.merchant, row.note ?? "", (row.tags ?? []).joined(separator: ","), row.transferPeerID ?? "",
            "\(row.amount.minorUnits) \(row.amount.currencyCode)", row.isPending ? "1" : "0", row.isYearly.map { $0 ? "1" : "0" } ?? "",
        ]
        // The unit separator can't come from a bank or a person, so no two rows' fields run together the same way.
        return fields.joined(separator: "\u{1F}")
    }

    private static func value(_ money: Money?) -> String {
        money.map { "\($0.minorUnits) \($0.currencyCode)" } ?? "none"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func json(_ value: (some Encodable)?) -> String {
        guard let value, let data = try? encoder.encode(value) else { return "none" }
        return String(decoding: data, as: UTF8.self)
    }
}
