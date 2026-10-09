import Foundation

/// Net worth over time: what you own less what you owe, day by day.
///
/// - Cash and cards are walked back from today's balance through their transactions, a day at a time. Where a sync
///   recorded the balance a bank reported (`BalanceSnapshot`), the walk starts again from that figure, so the history
///   keeps what the bank said even when rows arrive late.
/// - Investments are balance-only: each day holds its latest recorded balance. Before the first one it holds that first
///   value (or today's, with none recorded), and those days are marked estimated.
/// - Hand-kept assets and debts count from the day they were added, at each value they were given.
extension Ledger {
    /// "2026-09-28" for `date` in the ledger's calendar: the key balance snapshots are kept under.
    func dayName(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Hand-kept assets and debts today, each summed (debts as what's owed).
    func manualTotals() -> (assets: Money, debts: Money) {
        (manualAssets.filter { !$0.isLiability }.map(\.value).sum(), manualAssets.filter(\.isLiability).map(\.value).sum())
    }

    /// Today's balance of each of `accountIDs` the ledger holds, to record after a sync.
    func balanceSnapshots(for accountIDs: some Sequence<String>) -> [BalanceSnapshot] {
        let known = Set(accounts.map(\.id))
        let day = dayName(now)
        return Set(accountIDs).filter(known.contains).sorted().map {
            BalanceSnapshot(accountID: $0, day: day, balance: balance(of: $0, through: now))
        }
    }

    // MARK: History

    /// The breakdown and the series for `range`, from the snapshots recorded so far.
    func netWorth(range: NetWorthRange, snapshots recordedSnapshots: [BalanceSnapshot]) -> NetWorth {
        // An account that's gone (unlinked, reset) leaves its records behind; they don't stretch the history back.
        let known = Set(accounts.map(\.id))
        let snapshots = recordedSnapshots.filter { known.contains($0.accountID) }
        let today = calendar.startOfDay(for: now)
        let start = netWorthStart(range, snapshots: snapshots, today: today)
        let dayCount = max(1, (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1)
        let days = (0..<dayCount).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        var index: [String: Int] = [:]
        for (i, day) in days.enumerated() { index[dayName(day)] = i }
        let last = dayCount - 1

        let rowsByAccount = Dictionary(grouping: transactions.filter { $0.postedAt <= now }, by: \.accountID)
        let snapshotsByAccount = Dictionary(grouping: snapshots, by: \.accountID)

        var assets = [Int64](repeating: 0, count: dayCount)
        var liabilities = [Int64](repeating: 0, count: dayCount)
        var estimated = [Bool](repeating: false, count: dayCount)
        var assetLines: [NetWorthLine] = []
        var liabilityLines: [NetWorthLine] = []

        for account in accounts {
            let recorded = snapshotsByAccount[account.id] ?? []
            let series: [Int64]
            var isEstimated = false
            if account.kind == .investment {
                let (values, guessed) = heldSeries(account.id, recorded: recorded, days: days, index: index)
                series = values
                for i in guessed.indices where guessed[i] && values[i] != 0 { estimated[i] = true; isEstimated = true }
            } else {
                series = walkedSeries(account.id, rows: rowsByAccount[account.id] ?? [], recorded: recorded, days: days, index: index)
            }
            let isDebt = account.kind == .credit
            for i in 0..<dayCount {
                if isDebt { liabilities[i] -= series[i] } else { assets[i] += series[i] }
            }
            let now = Money(minorUnits: isDebt ? -series[last] : series[last])
            let then = Money(minorUnits: isDebt ? -series[0] : series[0])
            let line = NetWorthLine(id: account.id, name: account.shortLabel, detail: account.institution, group: Self.group(account.kind),
                                    value: now, change: now - then, isEstimated: isEstimated ? true : nil)
            if isDebt { liabilityLines.append(line) } else { assetLines.append(line) }
        }

        for item in manualAssets {
            let series = manualSeries(item, days: days)
            for i in 0..<dayCount {
                if item.isLiability { liabilities[i] += series[i] } else { assets[i] += series[i] }
            }
            let line = NetWorthLine(id: item.id, name: item.name, detail: item.category.label, group: Self.group(item),
                                    value: item.value, change: Money(minorUnits: series[last] - series[0]), isManual: true)
            if item.isLiability { liabilityLines.append(line) } else { assetLines.append(line) }
        }

        func ordered(_ lines: [NetWorthLine]) -> [NetWorthLine] {
            let order = Dictionary(uniqueKeysWithValues: NetWorthGroup.allCases.enumerated().map { ($1, $0) })
            return lines.sorted { (order[$0.group] ?? 0, $1.value.minorUnits, $0.name) < (order[$1.group] ?? 0, $0.value.minorUnits, $1.name) }
        }

        let all = (0..<dayCount).map { i in
            NetWorthPoint(date: days[i], netWorth: Money(minorUnits: assets[i] - liabilities[i]), assets: Money(minorUnits: assets[i]),
                          liabilities: Money(minorUnits: liabilities[i]), isEstimated: estimated[i] ? true : nil)
        }
        let first = all[0].netWorth, current = all[last].netWorth
        let estimatedThrough = estimated.lastIndex(of: true).map { days[$0] }
        var dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
        dayStyle.timeZone = calendar.timeZone
        let note = estimatedThrough.map {
            "Investments through \($0.formatted(dayStyle)) are estimated: no sync had recorded their balance yet, so they're held at the first one recorded."
        }
        return NetWorth(range: range.rawValue, asOf: now, start: start, points: Self.thinned(all), netWorth: current,
                        assets: all[last].assets, liabilities: all[last].liabilities, change: current - first,
                        changePercent: first.minorUnits > 0 ? Double(current.minorUnits - first.minorUnits) / Double(first.minorUnits) * 100 : nil,
                        assetLines: ordered(assetLines), liabilityLines: ordered(liabilityLines), manualAssets: manualAssets,
                        estimatedThrough: estimatedThrough, note: note)
    }

    /// The range's first day, never before the ledger's first: its first row, recorded balance or hand-kept value.
    func netWorthStart(_ range: NetWorthRange, snapshots: [BalanceSnapshot], today: Date) -> Date {
        let earliestRow = transactions.lazy.map(\.postedAt).min()
        let earliestSnapshot = snapshots.compactMap { startOfDay(named: $0.day) }.min()
        let earliestManual = manualAssets.compactMap { $0.history?.first?.date ?? $0.createdAt }.min()
        let earliest = calendar.startOfDay(for: [earliestRow, earliestSnapshot, earliestManual].compactMap { $0 }.min() ?? today)
        let wanted: Date = switch range {
        case .oneMonth: calendar.date(byAdding: .month, value: -1, to: today)!
        case .threeMonths: calendar.date(byAdding: .month, value: -3, to: today)!
        case .yearToDate: calendar.date(from: calendar.dateComponents([.year], from: today))!
        case .oneYear: calendar.date(byAdding: .year, value: -1, to: today)!
        case .all: earliest
        }
        return min(max(calendar.startOfDay(for: wanted), earliest), today)
    }

    /// A cash or card account's balance at the end of each day: today's balance, walked back through each day's rows, and
    /// reset to the bank's figure on each day a sync recorded one.
    private func walkedSeries(_ accountID: String, rows: [LedgerTransaction], recorded: [BalanceSnapshot], days: [Date],
                              index: [String: Int]) -> [Int64] {
        let last = days.count - 1
        var moved = [Int64](repeating: 0, count: days.count)
        for row in rows {
            if let i = index[dayName(row.postedAt)] { moved[i] += row.amount.minorUnits }
        }
        var reported: [Int: Int64] = [:]
        for snapshot in recorded { if let i = index[snapshot.day], i < last { reported[i] = snapshot.balance.minorUnits } }
        var values = [Int64](repeating: 0, count: days.count)
        values[last] = balance(of: accountID, through: now).minorUnits
        for i in stride(from: last - 1, through: 0, by: -1) {
            values[i] = reported[i] ?? values[i + 1] - moved[i + 1]
        }
        return values
    }

    /// An investment's balance at the end of each day: its latest recorded balance, today's as it stands now. Before the
    /// first record it holds that first value (today's with none), and those days are guesses.
    private func heldSeries(_ accountID: String, recorded: [BalanceSnapshot], days: [Date], index: [String: Int]) -> (values: [Int64], guessed: [Bool]) {
        let last = days.count - 1
        let current = balance(of: accountID, through: now).minorUnits
        let sorted = recorded.sorted { $0.day < $1.day }
        let firstDay = dayName(days[0])
        // The latest record before the range began carries into its first day.
        var held = sorted.last { $0.day < firstDay }?.balance.minorUnits
        var reported: [Int: Int64] = [:]
        for snapshot in sorted { if let i = index[snapshot.day] { reported[i] = snapshot.balance.minorUnits } }
        let stand = sorted.first?.balance.minorUnits ?? current
        var values = [Int64](repeating: 0, count: days.count)
        var guessed = [Bool](repeating: false, count: days.count)
        for i in 0...last {
            if let value = reported[i] { held = value }
            if i == last {
                values[i] = current
            } else if let held {
                values[i] = held
            } else {
                values[i] = stand
                guessed[i] = true
            }
        }
        return (values, guessed)
    }

    /// A hand-kept item's value at the end of each day: nothing before it was added, then each value it was given.
    private func manualSeries(_ item: ManualAsset, days: [Date]) -> [Int64] {
        let points = (item.history?.isEmpty == false ? item.history! : [ManualAssetValue(date: item.createdAt ?? item.updatedAt, value: item.value)])
            .map { (day: calendar.startOfDay(for: $0.date), value: $0.value.minorUnits) }
            .sorted { $0.day < $1.day }
        var values = [Int64](repeating: 0, count: days.count)
        var next = 0
        var held: Int64 = 0
        for (i, day) in days.enumerated() {
            while next < points.count, points[next].day <= day { held = points[next].value; next += 1 }
            values[i] = held
        }
        // Today is what it's worth now, whatever its history says.
        if points.contains(where: { $0.day <= days[days.count - 1] }) { values[days.count - 1] = item.value.minorUnits }
        return values
    }

    /// At most about 120 points: every day for a short range, every few days for a long one. Today is always last and
    /// the first day always first.
    static func thinned(_ points: [NetWorthPoint], target: Int = 120) -> [NetWorthPoint] {
        guard points.count > target else { return points }
        let step = Int((Double(points.count) / Double(target)).rounded(.up))
        var kept = Array(stride(from: points.count - 1, through: 0, by: -step).reversed())
        if kept.first != 0 { kept.insert(0, at: 0) }
        return kept.map { points[$0] }
    }

    static func group(_ kind: AccountKind) -> NetWorthGroup {
        switch kind {
        case .checking, .savings: .cash
        case .investment: .investments
        case .credit: .cards
        }
    }

    static func group(_ item: ManualAsset) -> NetWorthGroup {
        switch (item.kind, item.category) {
        case (.asset, .realEstate): .realEstate
        case (.asset, .vehicle): .vehicles
        case (.asset, _): .otherAssets
        case (.liability, .other): .otherDebts
        case (.liability, _): .loans
        }
    }

    // MARK: Demo

    /// A couple of months of recorded balances for the demo's investment accounts, drifting up to today's balance — so
    /// the chart shows investments moving recently and estimated before that. An account whose connection waits for a
    /// sign-in (`quiet`) stopped recording that many days ago.
    func demoBalanceSnapshots(days: Int = 60, quiet: [String: Int] = ["tidewater": 12]) -> [BalanceSnapshot] {
        let today = calendar.startOfDay(for: now)
        var out: [BalanceSnapshot] = []
        for (n, account) in accounts.filter({ $0.kind == .investment }).enumerated() {
            let current = Double(balance(of: account.id, through: now).minorUnits)
            let pause = quiet[account.id] ?? 0
            let phase = Double(n) * 1.7
            for back in pause...days {
                let k = Double(back - pause)
                let factor = 1 - 0.0009 * k + 0.006 * (sin(k * 0.45 + phase) - sin(phase))
                let day = calendar.date(byAdding: .day, value: -back, to: today)!
                out.append(BalanceSnapshot(accountID: account.id, day: dayName(day), balance: Money(minorUnits: Int64((current * factor).rounded()))))
            }
        }
        return out
    }

    /// The demo household's car and the loan on it, kept by hand since four months ago.
    mutating func addManualAssetExamples(today: Date) {
        func day(_ back: Int) -> Date { calendar.date(byAdding: .hour, value: 12, to: calendar.date(byAdding: .day, value: -back, to: today)!)! }
        let car = [(120, 19_600), (75, 19_000), (20, 18_400)].map { ManualAssetValue(date: day($0.0), value: Money(Decimal($0.1))) }
        let loan = [(120, 12_600), (90, 12_150), (60, 11_700), (30, 11_250)].map { ManualAssetValue(date: day($0.0), value: Money(Decimal($0.1))) }
        manualAssets = [
            ManualAsset(id: "asset-car", name: "Car", kind: .asset, category: .vehicle, value: car.last!.value, updatedAt: car.last!.date,
                        createdAt: car[0].date, history: car),
            ManualAsset(id: "asset-car-loan", name: "Car loan", kind: .liability, category: .loan, value: loan.last!.value,
                        updatedAt: loan.last!.date, createdAt: loan[0].date, history: loan),
        ]
    }

    // MARK: Actions

    /// What saving a hand-kept item would do: the checks `perform` runs, and net worth before and after.
    func manualAssetPreview(_ p: SaveManualAsset) throws -> ActionPreview {
        let (next, previous) = try manualAssetPlan(p)
        var after = self
        after.putManualAsset(next, replacing: previous?.id)
        let what = next.isLiability ? "debt" : "asset"
        let title = p.restore != nil ? "Put back \(next.name)"
            : previous == nil ? "Add \(next.name) as \(next.isLiability ? "a debt" : "an asset") of \(next.value.formatted(fractionDigits: 0))"
            : "Update \(next.name)"
        return ActionPreview(title: title, detail: previous == nil && p.restore == nil ? "It counts in net worth from today." : nil,
                             effects: [Figure(id: "value", label: next.isLiability ? "Owed" : "Worth", detail: next.category.label, value: next.value),
                                       Figure(id: "before", label: "Net worth now", detail: nil, value: balances().netWorth),
                                       Figure(id: "after", label: "Net worth with this \(what)", detail: nil, value: after.balances().netWorth)])
    }

    func manualAssetRemovalPreview(_ p: RemoveManualAsset) throws -> ActionPreview {
        guard let item = manualAssets.first(where: { $0.id == p.id }) else { throw BudgetAPIError.notFound }
        var after = self
        after.manualAssets.removeAll { $0.id == p.id }
        return ActionPreview(title: "Remove \(item.name)", detail: "Its history leaves net worth too.",
                             effects: [Figure(id: "before", label: "Net worth now", detail: nil, value: balances().netWorth),
                                       Figure(id: "after", label: "Net worth without it", detail: nil, value: after.balances().netWorth)])
    }

    mutating func performSaveManualAsset(_ p: SaveManualAsset) throws -> ActionResult {
        let (next, previous) = try manualAssetPlan(p)
        putManualAsset(next, replacing: previous?.id)
        let undo: AppAction = previous.map { .saveManualAsset(SaveManualAsset(restore: $0)) } ?? .removeManualAsset(RemoveManualAsset(id: next.id))
        let message = p.restore != nil ? "Put \(next.name) back." : previous == nil ? "Added \(next.name). Net worth is now \(balances().netWorth.formatted(fractionDigits: 0))."
            : "Updated \(next.name). Net worth is now \(balances().netWorth.formatted(fractionDigits: 0))."
        return ActionResult(message: message, undo: undo)
    }

    mutating func performRemoveManualAsset(_ p: RemoveManualAsset) throws -> ActionResult {
        guard let item = manualAssets.first(where: { $0.id == p.id }) else { throw BudgetAPIError.notFound }
        manualAssets.removeAll { $0.id == p.id }
        return ActionResult(message: "Removed \(item.name).", undo: .saveManualAsset(SaveManualAsset(restore: item)))
    }

    private mutating func putManualAsset(_ item: ManualAsset, replacing id: String?) {
        if let id, let index = manualAssets.firstIndex(where: { $0.id == id }) {
            manualAssets[index] = item
        } else {
            manualAssets.append(item)
        }
    }

    static let manualNameLimit = 60
    static let manualValueLimit = Money(1_000_000_000)

    /// The item a save leaves, and the one it replaces (nil when it adds one).
    private func manualAssetPlan(_ p: SaveManualAsset) throws -> (next: ManualAsset, previous: ManualAsset?) {
        if let restore = p.restore {
            // Undo sends the item back whole; it still has to be one the ledger could have kept.
            let name = restore.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !restore.id.isEmpty, !name.isEmpty, name.count <= Self.manualNameLimit,
                  !restore.value.isNegative, restore.value < Self.manualValueLimit,
                  (restore.history ?? []).allSatisfy({ !$0.value.isNegative && $0.value < Self.manualValueLimit })
            else { throw BudgetAPIError.rejected("That can't be put back as it was.") }
            return (restore, manualAssets.first { $0.id == restore.id })
        }
        let name = p.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name {
            guard !name.isEmpty else { throw BudgetAPIError.rejected("Give it a name.") }
            guard name.count <= Self.manualNameLimit else { throw BudgetAPIError.rejected("Keep the name to \(Self.manualNameLimit) characters.") }
        }
        let value = p.value?.money()
        if let value {
            guard !value.isNegative else { throw BudgetAPIError.rejected("Enter what it's worth (or what's owed) as a positive amount.") }
            guard value < Self.manualValueLimit else { throw BudgetAPIError.rejected("That's more than Budget can keep.") }
        }
        let today = now
        guard let id = p.id else {
            guard let name else { throw BudgetAPIError.rejected("Give it a name.") }
            guard let value else { throw BudgetAPIError.rejected("Enter what it's worth, or what's owed.") }
            let kind = p.kind ?? (p.category == .loan ? .liability : .asset)
            let item = ManualAsset(id: "asset-\(UUID().uuidString.prefix(8).lowercased())", name: name, kind: kind,
                                   category: p.category ?? (kind == .liability ? .loan : .other), value: value, updatedAt: today,
                                   createdAt: today, history: [ManualAssetValue(date: today, value: value)])
            return (item, nil)
        }
        guard let previous = manualAssets.first(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
        var item = previous
        if let name { item.name = name }
        if let kind = p.kind { item.kind = kind }
        if let category = p.category { item.category = category }
        if let value, value != previous.value {
            item.value = value
            var history = previous.history ?? [ManualAssetValue(date: previous.createdAt ?? previous.updatedAt, value: previous.value)]
            if let last = history.last, calendar.isDate(last.date, inSameDayAs: today) { history.removeLast() }
            history.append(ManualAssetValue(date: today, value: value))
            item.history = history
        }
        guard item != previous else { throw BudgetAPIError.rejected("Nothing to change.") }
        item.updatedAt = today
        return (item, previous)
    }
}
