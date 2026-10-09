import Foundation

extension Ledger {
    /// The start of `day` ("2026-09-28") in the ledger's calendar; nil when it isn't a date.
    func startOfDay(named day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]),
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// The morning summary's figures and facts for the day starting at `start`, with the template's summary. The
    /// chat model may retell it (`DigestWriter`); it never adds to it.
    func dayDigest(_ day: String, from start: Date) -> DayDigest {
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spendingIDs = Set(categories.filter(\.countsAsSpending).map(\.id))
        let rows = transactions(from: start, to: end).filter { ($0.categorization?.categoryID).map(spendingIDs.contains) ?? false }
        let spent = netSpend(rows)
        let everyday = everydaySpent(from: start, to: end)
        let charges = rows.filter(\.amount.isNegative)

        // Each merchant net of its refunds that day, like every other total.
        let places = Dictionary(grouping: rows, by: \.merchant).compactMap { merchant, rows -> DayDigest.Place? in
            let net = -rows.map(\.amount.minorUnits).reduce(0, +)
            guard net > 0 else { return nil }
            let largest = rows.min { $0.amount < $1.amount }
            return DayDigest.Place(merchant: merchant, spent: Money(minorUnits: net), count: rows.filter(\.amount.isNegative).count,
                                   category: largest?.categorization.flatMap { byID[$0.categoryID]?.name })
        }
        .sorted { $0.spent == $1.spent ? $0.merchant < $1.merchant : $0.spent > $1.spent }

        let typical = typicalDay(before: start)
        var facts: [DayDigest.Fact] = []
        if let typical, typical.minorUnits > 0, everyday.minorUnits > 0 {
            let ratio = Double(everyday.minorUnits) / Double(typical.minorUnits)
            if ratio >= 1.5 {
                facts.append(.init(kind: .pace, text: "Everyday spending was \(Self.times(ratio)) a typical day's \(Self.amount(typical))."))
            } else if ratio <= 0.5 {
                facts.append(.init(kind: .pace, text: "Everyday spending was well under a typical day's \(Self.amount(typical))."))
            }
        }
        // Banks name one merchant several ways ("Amazon", "Amazon Marketplace"), so a name is new only when nothing
        // before shares its first word — and only once the ledger reaches back far enough to know.
        let earlier = transactions.filter { $0.postedAt < start }
        if let first = earlier.map(\.postedAt).min(), start.timeIntervalSince(first) >= 90 * 86_400 {
            let seen = Set(earlier.map { Self.firstWord($0.merchant) })
            if let new = places.first(where: { $0.spent.minorUnits >= 1_000 && Self.firstWord($0.merchant).count >= 3 && !seen.contains(Self.firstWord($0.merchant)) }) {
                facts.append(.init(kind: .firstTime, text: "First time at \(new.merchant)."))
            }
        }
        let index = recurringIndex
        let scheduled = charges.filter { [.bills, .subscriptions].contains(bucket(of: $0, categories: byID, kinds: index.kinds)) }
        if !scheduled.isEmpty {
            let named = scheduled.sorted { $0.amount < $1.amount }.prefix(2).map { "\($0.merchant) (\(Self.amount($0.amount.magnitude)))" }
            let more = scheduled.count > 2 ? " and \(scheduled.count - 2) more" : ""
            facts.append(.init(kind: .bills, text: "Bills and subscriptions in it: \(named.joined(separator: ", "))\(more)."))
        }
        let flex = flexBudget()
        if flex.flexNumber.minorUnits > 0 {
            facts.append(flex.safeToSpend.minorUnits >= 0
                ? .init(kind: .safeToSpend, text: "\(Self.amount(flex.safeToSpend)) is safe to spend for the rest of the month"
                        + (flex.perDayLeft.map { ", \(Self.amount($0)) a day." } ?? "."))
                : .init(kind: .safeToSpend, text: "Everyday spending is \(Self.amount(flex.safeToSpend.magnitude)) past this month's safe to spend."))
        }
        facts += dueSoonFacts(from: end)
        let pending = charges.filter(\.isPending).count
        if pending > 0 {
            facts.append(.init(kind: .pending, text: pending == 1 ? "One charge is still pending, so the total can change."
                                                                  : "\(pending) charges are still pending, so the total can change."))
        }

        let top = Array(places.prefix(3))
        // Anything posted from this day on, spending or not, means the bank has sent the day.
        let received = transactions.contains { $0.postedAt >= start }
        let summary = !received && charges.isEmpty ? "Nothing from yesterday has come in from your bank yet. Banks often send a day's charges the next morning."
                                                   : Self.templateSummary(places: top, facts: facts)
        return DayDigest(day: day, spent: spent, everydaySpent: everyday, typicalDay: typical, count: charges.count, pendingCount: pending,
                         received: received, places: top, facts: facts, summary: summary, writtenBy: nil)
    }

    /// Everyday spending on an average day of the 28 before `start`; nil when the ledger doesn't reach back a week.
    func typicalDay(before start: Date) -> Money? {
        guard let first = transactions.map(\.postedAt).min() else { return nil }
        let reach = calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: start).day ?? 0
        let days = min(reach, 28)
        guard days >= 7 else { return nil }
        let total = everydaySpent(from: calendar.date(byAdding: .day, value: -days, to: start)!, to: start)
        return Money(minorUnits: total.minorUnits / Int64(days))
    }

    /// "Shell $62, Trader Joe's $44 and Blue Bottle $6.50." then the most useful fact; a day with nothing spent says so.
    static func templateSummary(places: [DayDigest.Place], facts: [DayDigest.Fact]) -> String {
        let lead = facts.first { $0.kind != .pending }?.text
        guard !places.isEmpty else { return (["Nothing spent."] + [lead].compactMap { $0 }).joined(separator: " ") }
        let named = places.map { "\($0.merchant) \(amount($0.spent))" }
        let list = named.count == 1 ? named[0] : named.dropLast().joined(separator: ", ") + " and " + named.last!
        return ([list + "."] + [lead].compactMap { $0 }).joined(separator: " ")
    }

    /// "amazon" for "Amazon Marketplace" and "AMAZON.COM*2K4".
    static func firstWord(_ merchant: String) -> String {
        merchant.lowercased().split { !$0.isLetter && !$0.isNumber }.first.map(String.init) ?? ""
    }

    /// Whole dollars from $10, cents below.
    static func amount(_ money: Money) -> String {
        money.formatted(fractionDigits: money.minorUnits >= 1_000 ? 0 : 2)
    }

    /// "2×", "2.5×" — to the half, which is all a glance needs.
    static func times(_ ratio: Double) -> String {
        let halves = (ratio * 2).rounded() / 2
        return halves == halves.rounded() ? "\(Int(halves))×" : "\(halves.formatted(.number.precision(.fractionLength(1))))×"
    }
}
