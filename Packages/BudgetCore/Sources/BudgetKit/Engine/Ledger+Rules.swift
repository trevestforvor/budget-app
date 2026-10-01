import Foundation

/// A row's text as rules read it, worked out once per row: upper-cased, without numbers or processor prefixes, and
/// without spaces or punctuation, so "GOOGLE*FI", "GOOGLE *FI" and "Google Fi" read alike.
struct RuleText {
    /// One field (the merchant or the bank description) in each of the forms a rule compares.
    struct Field {
        let plain: String
        let digitFree: String
        let squashed: String
        let digitFreeSquashed: String

        init(_ raw: String) {
            plain = raw.uppercased()
            digitFree = Descriptor.normalize(raw)
            squashed = Self.squash(plain)
            digitFreeSquashed = Self.squash(digitFree)
        }

        /// Letters and numbers only.
        static func squash(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
        }
    }

    let merchant: Field
    let descriptor: Field

    init(_ row: LedgerTransaction) {
        merchant = Field(row.merchant)
        descriptor = Field(row.rawDescription)
    }
}

/// One rule made ready to test many rows: its conditions tidied and its text case-folded once.
struct RuleMatcher {
    /// Text to find: as typed, without numbers ("PARAMOUNT PAYROLL 0923" also finds "PARAMOUNT PAYROLL 1007 PPD"),
    /// or without spaces and punctuation ("Google Fi" also finds "GOOGLE*FI AB12CD").
    private struct Needle {
        let text: RuleText.Field
        init(_ raw: String) { text = RuleText.Field(raw) }
        func found(in field: RuleText.Field) -> Bool {
            field.plain.contains(text.plain)
                || (!text.digitFree.isEmpty && field.digitFree.contains(text.digitFree))
                || (!text.squashed.isEmpty && field.squashed.contains(text.squashed))
                || (!text.digitFreeSquashed.isEmpty && field.digitFreeSquashed.contains(text.digitFreeSquashed))
        }
    }

    let rule: BudgetRule
    private let match: RuleMatch
    private let merchant: Needle?
    private let descriptor: Needle?
    /// The rule files under a money-in category, so it never takes money going out.
    private let filesMoneyIn: Bool

    /// - Parameter filesMoneyIn: whether the rule's category counts as money in (`Ledger.ruleBook` works it out).
    init(_ rule: BudgetRule, filesMoneyIn: Bool) {
        self.rule = rule
        match = rule.match.normalized
        merchant = match.merchantContains.map(Needle.init)
        descriptor = match.descriptorContains.map(Needle.init)
        self.filesMoneyIn = filesMoneyIn
    }

    /// Every condition holds (the cheap ones checked first), and it isn't money going out filed as money in.
    func applies(to row: LedgerTransaction, _ text: RuleText) -> Bool {
        guard merchant != nil || descriptor != nil || match.accountID != nil else { return false }
        if let accountID = match.accountID, row.accountID != accountID { return false }
        switch match.direction {
        case .moneyOut?: if row.amount.minorUnits >= 0 { return false }
        case .moneyIn?: if row.amount.minorUnits <= 0 { return false }
        case nil: break
        }
        let size = row.amount.magnitude.minorUnits
        if let min = match.minAmount, size < min.minorUnits { return false }
        if let max = match.maxAmount, size > max.minorUnits { return false }
        if filesMoneyIn, row.amount.isNegative { return false }
        if let merchant, !merchant.found(in: text.merchant) { return false }
        if let descriptor, !descriptor.found(in: text.descriptor) { return false }
        return true
    }
}

/// Rules made ready to test many rows at once, in their stored order (oldest first).
struct RuleBook {
    let matchers: [RuleMatcher]

    /// - Parameter moneyIn: the money-in category ids; a rule filing under one of them never takes money going out.
    init(_ rules: [BudgetRule], moneyIn: Set<String>) { matchers = rules.map { RuleMatcher($0, filesMoneyIn: moneyIn.contains($0.categoryID)) } }

    /// The rules that apply to the row, oldest first.
    func applying(to row: LedgerTransaction, _ text: RuleText) -> [BudgetRule] {
        matchers.filter { $0.applies(to: row, text) }.map(\.rule)
    }

    /// The rule that files the row: the newest one that's on, applies, and files under a category in `known`
    /// (a rule whose category was merged away files nothing, and the next rule gets its turn).
    func winner(for row: LedgerTransaction, _ text: RuleText, known: Set<String>) -> BudgetRule? {
        matchers.last { $0.rule.isEnabled && known.contains($0.rule.categoryID) && $0.applies(to: row, text) }?.rule
    }
}

/// Rules: which one files a row, what each has done, where two disagree, and how a rule reads in words.
extension Ledger {
    /// The rule that files `row` (see `RuleBook.winner`). For many rows, build one `RuleBook` instead.
    func rule(for row: LedgerTransaction, known: Set<String>) -> BudgetRule? {
        ruleBook().winner(for: row, RuleText(row), known: known)
    }

    /// `list` (the ledger's rules when nil) made ready to test many rows, knowing which categories are money in.
    func ruleBook(_ list: [BudgetRule]? = nil) -> RuleBook { RuleBook(list ?? rules, moneyIn: moneyInCategoryIDs) }

    /// Every rule, newest first (the order they're tried in), with its hits, its matches, the rules it
    /// disagrees with and whether it's dead.
    func ruleSummaries() -> [RuleSummary] {
        let active = Set(activeCategories.map(\.id))
        let live = Set(rules.filter { $0.isEnabled && active.contains($0.categoryID) }.map(\.id))
        let hits = ruleHits(rules)
        var matchCount: [String: Int] = [:]
        for matched in hits { for id in matched { matchCount[id, default: 0] += 1 } }
        let filed = Dictionary(grouping: transactions.compactMap { $0.categorization?.ruleID }, by: { $0 }).mapValues(\.count)
        return rules.reversed().map { rule in
            RuleSummary(rule: rule, matchDescription: describe(rule.match), hitCount: filed[rule.id] ?? 0, matchCount: matchCount[rule.id] ?? 0,
                        conflicts: live.contains(rule.id) ? conflicts(of: rule, hits: hits, live: live) : [],
                        isDead: !active.contains(rule.categoryID))
        }
    }

    /// Other live rules that disagree with `candidate`: a different category, and either the same match or a
    /// row they both file. Newest first. `candidate` may be a rule not saved yet (a preview); a saved rule with
    /// its id is left out of its own list.
    func conflicts(of candidate: BudgetRule) -> [String] {
        let active = Set(activeCategories.map(\.id))
        let others = rules.filter { $0.id != candidate.id }
        let live = Set(others.filter { $0.isEnabled && active.contains($0.categoryID) }.map(\.id))
        return conflicts(of: candidate, hits: ruleHits(others + [candidate]), live: live)
    }

    private func conflicts(of candidate: BudgetRule, hits: [[String]], live: Set<String>) -> [String] {
        var ids = Set<String>()
        let categoryOf = Dictionary(rules.map { ($0.id, $0.categoryID) }, uniquingKeysWith: { _, last in last })
        for matched in hits where matched.contains(candidate.id) {
            for id in matched where id != candidate.id && live.contains(id) && categoryOf[id] != candidate.categoryID { ids.insert(id) }
        }
        for other in rules where other.id != candidate.id && live.contains(other.id) && other.categoryID != candidate.categoryID
            && other.match.isSame(as: candidate.match) {
            ids.insert(other.id)
        }
        let order = Dictionary(rules.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.sorted { (order[$0] ?? 0) > (order[$1] ?? 0) }
    }

    /// For each row at least one of `rules` applies to, the ids of those that do.
    private func ruleHits(_ rules: [BudgetRule]) -> [[String]] {
        let book = ruleBook(rules)
        return transactions.compactMap { row in
            let matched = book.applying(to: row, RuleText(row)).map(\.id)
            return matched.isEmpty ? nil : matched
        }
    }

    /// "Bank description contains “PARAMOUNT PAYROLL” · money in · $1,000 or more · Total Checking" — in the rule
    /// editor's own words.
    func describe(_ match: RuleMatch) -> String {
        let m = match.normalized
        var parts: [String] = []
        if let text = m.merchantContains { parts.append("Merchant name contains “\(text)”") }
        if let text = m.descriptorContains { parts.append("\(parts.isEmpty ? "Bank description" : "bank description") contains “\(text)”") }
        let rest = qualifiers(m)
        if parts.isEmpty, let first = rest.first { return ([first.prefix(1).uppercased() + first.dropFirst()] + rest.dropFirst()).joined(separator: " · ") }
        return (parts + rest).joined(separator: " · ")
    }

    /// "“Withdrawal” (money out, Cash Account)", or "everything on Cash Account (money out)": what a rule files,
    /// for titles like "Always file … under Transfer".
    func ruleSubject(_ match: RuleMatch) -> String {
        let m = match.normalized
        var rest = qualifiers(m)
        var subject = [m.merchantContains, m.descriptorContains].compactMap { $0 }.map { "“\($0)”" }.joined(separator: " + ")
        if subject.isEmpty, m.accountID != nil { subject = "everything on \(rest.removeLast())" }
        return subject + (rest.isEmpty ? "" : " (\(rest.joined(separator: ", ")))")
    }

    /// Direction, amount and account, in words, account last.
    private func qualifiers(_ m: RuleMatch) -> [String] {
        var parts: [String] = []
        switch m.direction {
        case .moneyOut?: parts.append("money out")
        case .moneyIn?: parts.append("money in")
        case nil: break
        }
        func text(_ amount: DecimalAmount) -> String { amount.money().formatted(fractionDigits: amount.minorUnits % 100 == 0 ? 0 : 2) }
        switch (m.minAmount, m.maxAmount) {
        case let (min?, max?): parts.append("\(text(min))–\(text(max))")
        case let (min?, nil): parts.append("\(text(min)) or more")
        case let (nil, max?): parts.append("up to \(text(max))")
        case (nil, nil): break
        }
        if let id = m.accountID {
            // The last digits tell apart two cards with the same name.
            parts.append(accounts.first { $0.id == id }?.shortLabel ?? "an account that's gone")
        }
        return parts
    }

    /// A rule's conditions checked and tidied: some text or an account to go on, text 2–60 characters, a known
    /// account, sizes that aren't negative and in order. A rule filing under a money-in category takes only money
    /// coming in, and says so: asking for money out is refused, and "either way" becomes money in.
    func validatedMatch(_ match: RuleMatch, categoryID: String) throws -> RuleMatch {
        var m = match.normalized
        guard m.merchantContains != nil || m.descriptorContains != nil || m.accountID != nil else {
            throw BudgetAPIError.rejected("A rule needs text to match, or an account.")
        }
        for text in [m.merchantContains, m.descriptorContains].compactMap({ $0 }) where !(2...60).contains(text.count) {
            throw BudgetAPIError.rejected("Keep the text to match between 2 and 60 characters.")
        }
        if let id = m.accountID, !accounts.contains(where: { $0.id == id }) { throw BudgetAPIError.rejected("That account isn't in the ledger.") }
        if [m.minAmount, m.maxAmount].contains(where: { ($0?.minorUnits ?? 0) < 0 }) {
            throw BudgetAPIError.rejected("Amounts in a rule are sizes, so they can't be negative.")
        }
        if let min = m.minAmount, let max = m.maxAmount, min.minorUnits > max.minorUnits {
            throw BudgetAPIError.rejected("The smallest amount is more than the largest.")
        }
        if let category = category(categoryID), category.isMoneyIn {
            guard m.direction != .moneyOut else {
                throw BudgetAPIError.rejected(category.id == BudgetCategory.incomeID ? "Money going out is never income."
                    : "Money going out never counts as money in, so a rule can't file it under \(category.name).")
            }
            m.direction = .moneyIn
        }
        return m
    }

    /// Rows filed before matched transfers and statement rows had their own tiers say `.rule`, and rows a rule
    /// filed then don't name it. This gives the first two their honest tier and traces the rest to the newest
    /// rule that matches and agrees, so its hits count them. Runs on every load; a no-op once done.
    mutating func upgradeLegacyProvenance() {
        for index in transactions.indices {
            guard var c = transactions[index].categorization, c.tier == .rule else { continue }
            if (c.decidedBy ?? "").hasPrefix(Categorizer.matchedTransfer) {
                c.tier = .transferMatch
            } else if c.decidedBy == Categorizer.statementDecidedBy {
                c.tier = .statement
            } else if c.decidedBy == nil, let rule = rules.last(where: {
                $0.categoryID == c.categoryID && RuleMatcher($0, filesMoneyIn: isMoneyIn($0.categoryID)).applies(to: transactions[index], RuleText(transactions[index]))
            }) {
                c.decidedBy = rule.stamp
            } else {
                continue
            }
            transactions[index].categorization = c
        }
    }
}
