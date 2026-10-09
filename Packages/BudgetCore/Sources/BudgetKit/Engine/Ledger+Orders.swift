import Foundation

extension Ledger {
    /// How far a charge can be from its order's date, or a shipment's, and still be its charge.
    static let orderMatchDays: Double = 7

    /// Whether a row reads as an Amazon charge: "AMAZON.COM*RT4", "AMZN MKTP US*2K4LL", "Amazon".
    static func looksLikeAmazon(_ row: LedgerTransaction) -> Bool {
        let text = (row.merchant + " " + row.rawDescription).lowercased()
        return text.contains("amazon") || text.contains("amzn")
    }

    /// Matches a store's orders to the card charges they made and attaches what each bought (`orderMatch`). A charge
    /// matches an order — or, for an order charged a shipment at a time, one shipment — when it's an Amazon charge for
    /// the same amount to the cent, within `orderMatchDays` of the order or ship date; the closest date wins and each
    /// charge pays for one order at most.
    ///
    /// Nothing is re-filed. When a matched charge's items read as another category than the one it's filed under, and
    /// neither the person nor a rule filed it, it goes to review with that category as the first suggestion. Charges
    /// already matched, and orders already matched, are left as they are, so importing the same file again changes
    /// nothing.
    mutating func matchOrders(_ orders: [OrderHistory.Order], store: String = OrderHistory.amazon, skippedLines: Int = 0, apply: Bool)
        -> OrderImportReport {
        let matchedUnits = Set(transactions.compactMap { row in row.orderMatch.map { "\($0.orderID)|\($0.shipment ?? "")" } })
        let matchedOrders = Set(transactions.compactMap(\.orderMatch?.orderID))
        let firstDay = transactions.last.map { calendar.startOfDay(for: $0.postedAt).addingTimeInterval(-Self.orderMatchDays * 86_400) }
        // The charges an order could be: Amazon money out not already matched, oldest first.
        var open = transactions.indices.filter { i in
            let row = transactions[i]
            return row.amount.isNegative && row.orderMatch == nil && Self.looksLikeAmazon(row)
        }
        var matches: [OrderImportReport.Match] = []
        var unmatched: [OrderImportReport.Unmatched] = []
        var already = 0, before = 0, suggested = 0

        /// The open charge for `amount` closest to one of `dates`, within the window; taken from `open` when found.
        func take(_ amount: Money, near dates: [Date]) -> Int? {
            let limit = Self.orderMatchDays * 86_400
            let fits = open.compactMap { i -> (index: Int, distance: Double)? in
                let row = transactions[i]
                guard abs(row.amount.magnitude.minorUnits - amount.minorUnits) <= 1 else { return nil }
                let distance = dates.map { abs(row.postedAt.timeIntervalSince($0)) }.min() ?? .infinity
                return distance <= limit ? (i, distance) : nil
            }
            guard let best = fits.min(by: { ($0.distance, transactions[$0.index].id) < ($1.distance, transactions[$1.index].id) }) else { return nil }
            open.removeAll { $0 == best.index }
            return best.index
        }

        func attach(_ index: Int, order: OrderHistory.Order, shipment: String?, items: [OrderHistory.Order.Item]) {
            let match = OrderMatch(store: store, orderID: order.id, shipment: shipment, items: items.map(\.name), orderedAt: order.orderedAt)
            let suggestion = orderSuggestion(for: transactions[index], items: items)
            if apply {
                transactions[index].orderMatch = match
                if let suggestion { sendToReview(index, suggesting: suggestion, match: match) }
            }
            if suggestion != nil { suggested += 1 }
            let row = transactions[index]
            matches.append(.init(transactionID: row.id, orderID: order.id, postedAt: row.postedAt, amount: row.amount, items: match.items,
                                 suggestedCategoryID: suggestion?.categoryID))
        }

        for order in orders.sorted(by: { ($0.orderedAt, $0.id) < ($1.orderedAt, $1.id) }) {
            if matchedUnits.contains("\(order.id)|") { already += 1; continue }
            let shipments = order.shipments(in: calendar)
            let shipDates = order.items.compactMap(\.shippedAt)
            var found = 0
            if !matchedOrders.contains(order.id), let index = take(order.total, near: [order.orderedAt] + shipDates) {
                attach(index, order: order, shipment: nil, items: order.items)
                found += 1
            } else if let shipments {
                for shipment in shipments where !matchedUnits.contains("\(order.id)|\(shipment.key)") {
                    let total = shipment.items.map(\.total).sum()
                    if let index = take(total, near: [shipment.date, order.orderedAt]) {
                        attach(index, order: order, shipment: shipment.key, items: shipment.items)
                        found += 1
                    }
                }
            }
            if found > 0 { continue }
            if matchedOrders.contains(order.id) { already += 1; continue }
            if let firstDay, order.orderedAt < firstDay { before += 1; continue }
            unmatched.append(.init(orderID: order.id, orderedAt: order.orderedAt, total: order.total, items: order.items.map(\.name)))
        }
        return OrderImportReport(
            store: store, applied: apply, orders: orders.count, matched: matches.count, alreadyMatched: already, unmatched: unmatched.count,
            beforeLedger: before, suggested: suggested, skippedLines: skippedLines,
            matches: Array(matches.sorted { $0.postedAt > $1.postedAt }.prefix(OrderImportReport.sampleSize)),
            unmatchedOrders: Array(unmatched.sorted { $0.orderedAt > $1.orderedAt }.prefix(OrderImportReport.sampleSize)))
    }

    /// The category a matched charge's items read as, when it's worth asking about: another category than the charge
    /// is filed under, on a row nobody settled (not the person's, a rule's, the statement's, or a matched transfer) and
    /// not hidden. Nil otherwise.
    func orderSuggestion(for row: LedgerTransaction, items: [OrderHistory.Order.Item]) -> CategorySuggestion? {
        guard !row.isHidden, !(row.categorization?.tier.isSettledByPersonOrData ?? false),
              let suggestion = OrderItemCategories.suggest(items, among: activeCategories),
              suggestion.categoryID != row.categorization?.categoryID else { return nil }
        return suggestion
    }

    /// Puts a matched charge in review with its items' category first: the category it's filed under stays its
    /// answer until the person picks.
    private mutating func sendToReview(_ index: Int, suggesting suggestion: CategorySuggestion, match: OrderMatch) {
        let id = transactions[index].id
        let current = transactions[index].categorization
        if var categorization = current {
            categorization.needsReview = true
            transactions[index].categorization = categorization
        } else {
            transactions[index].categorization = Categorization(categoryID: suggestion.categoryID, confidence: suggestion.confidence, tier: .model,
                                                                needsReview: true, decidedBy: "\(match.store) order")
        }
        let rest = (suggestions[id] ?? []).filter { $0.categoryID != suggestion.categoryID }
        let keep = current.map { [CategorySuggestion(categoryID: $0.categoryID, confidence: $0.confidence)] } ?? []
        suggestions[id] = [suggestion] + (rest.isEmpty ? keep.filter { $0.categoryID != suggestion.categoryID } : rest)
        let name = category(suggestion.categoryID)?.name ?? suggestion.categoryID
        reviewReasons[id] = "\(match.store) order \(match.orderID): \(match.itemsLine). The items read as \(name)."
    }
}

/// Reads a category from what an order bought: each item votes, by what was owed for it, for the category its name
/// reads as (groceries, health, entertainment, travel, transport), else shopping. Only categories the ledger has and
/// that count as spending take part.
enum OrderItemCategories {
    static let keywords: [(categoryID: String, words: [String])] = [
        ("groceries", ["coffee", "tea", "snack", "snacks", "cereal", "pasta", "rice", "flour", "sugar", "spice", "spices", "chocolate",
                       "almonds", "nuts", "granola", "oatmeal", "oats", "olive oil", "sauce", "soup", "beans", "honey", "jam", "crackers",
                       "chips", "juice", "sparkling water", "protein bar", "k-cup", "k-cups", "whole bean", "grocery", "pantry", "organic"]),
        ("health", ["vitamin", "vitamins", "supplement", "supplements", "probiotic", "ibuprofen", "acetaminophen", "allergy", "bandage",
                    "bandages", "first aid", "thermometer", "toothpaste", "toothbrush", "floss", "sunscreen", "medicine", "pain relief",
                    "contact lens", "contact lenses", "multivitamin", "electrolyte"]),
        ("entertainment", ["book", "novel", "hardcover", "paperback", "kindle edition", "board game", "card game", "puzzle", "dvd",
                           "blu-ray", "vinyl", "video game", "audiobook"]),
        ("travel", ["luggage", "suitcase", "carry-on", "packing cubes", "travel adapter", "passport", "neck pillow"]),
        ("transport", ["wiper blade", "wiper blades", "motor oil", "tire inflator", "car charger", "bike tube", "bike light"]),
    ]
    static let fallback = "shopping"

    static func suggest(_ items: [OrderHistory.Order.Item], among categories: [BudgetCategory]) -> CategorySuggestion? {
        let usable = Set(categories.filter { $0.countsAsSpending && !$0.isArchived }.map(\.id))
        var votes: [String: Int64] = [:]
        for item in items {
            let words = " " + item.name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : " " }.reduce(into: "") { $0.append($1) } + " "
            let id = keywords.first { usable.contains($0.categoryID) && $0.words.contains { words.contains(" \($0) ") } }?.categoryID
                ?? (usable.contains(fallback) ? fallback : nil)
            if let id { votes[id, default: 0] += max(item.total.minorUnits, 1) }
        }
        let total = votes.values.reduce(0, +)
        guard total > 0, let best = votes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        let share = Double(best.value) / Double(total)
        return CategorySuggestion(categoryID: best.key, confidence: ((0.5 + 0.4 * share) * 100).rounded() / 100)
    }
}
