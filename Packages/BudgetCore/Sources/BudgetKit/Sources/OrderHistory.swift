import Foundation

/// A store's order history, as the store exports it — what a card charge's line in the bank data doesn't say. Today
/// that's Amazon's "Your Orders" file from Request My Data (`Retail.OrderHistory.1.csv`): one line per item, with
/// `Order ID`, `Order Date`, `Total Owed`, `Product Name`, `Quantity`, `Order Status` and `Ship Date` (some exports
/// say `Shipment Date`).
public enum OrderHistory {
    /// One order: its items, each with what was owed for it (price, tax and shipping, less discounts).
    public struct Order: Hashable, Sendable {
        public struct Item: Hashable, Sendable {
            public var name: String
            public var quantity: Int
            public var total: Money
            /// When it shipped; nil when the file doesn't say ("Not Available").
            public var shippedAt: Date?
        }

        public var id: String
        public var orderedAt: Date
        public var items: [Item]

        public var total: Money { items.map(\.total).sum() }

        /// The items by the day they shipped, in order, when they shipped on more than one day: each shipment is often
        /// charged on its own. Nil for an order that went out at once.
        public func shipments(in calendar: Calendar) -> [(key: String, date: Date, items: [Item])]? {
            let dated = items.filter { $0.shippedAt != nil }
            guard dated.count == items.count else { return nil }
            let byDay = Dictionary(grouping: dated) { Self.dayKey(calendar.startOfDay(for: $0.shippedAt!), calendar) }
            guard byDay.count > 1 else { return nil }
            return byDay.map { key, items in (key, items.map { $0.shippedAt! }.min()!, items) }.sorted { $0.date < $1.date }
        }

        static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
    }

    /// What reading a file found.
    public struct Parsed: Sendable {
        public var orders: [Order]
        /// Lines that couldn't be read, were cancelled, or belong to an order that owed nothing.
        public var skippedLines: Int
    }

    /// The store's name, as a matched charge says it.
    public static let amazon = "Amazon"

    /// Reads Amazon's order history CSV. Throws `FileImport.ParseError` when it isn't one (no `Order ID`, `Order Date`
    /// and `Total Owed` columns). Dates without a time zone read as UTC, as Amazon writes them.
    public static func parseAmazon(_ text: String) throws -> Parsed {
        let table = CSV.rows(text)
        guard let header = table.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else {
            throw FileImport.ParseError(message: "The file is empty.")
        }
        func column(_ names: String...) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let idColumn = column("order id"), let dateColumn = column("order date"),
              let owedColumn = column("total owed", "item total", "total charged") else {
            throw FileImport.ParseError(message: "This doesn't look like Amazon's order history: it needs the Order ID, Order Date and Total Owed columns of Retail.OrderHistory.1.csv.")
        }
        let nameColumn = column("product name", "title")
        let quantityColumn = column("quantity")
        let shipColumn = column("ship date", "shipment date")
        let statusColumn = column("order status")

        var orders: [String: Order] = [:]
        var order: [String] = []
        var skipped = 0
        for line in table.dropFirst() {
            func field(_ index: Int?) -> String? {
                guard let index, index < line.count else { return nil }
                let value = line[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty || value.lowercased() == "not available" ? nil : value
            }
            // A free item (nothing owed) is still part of what its order bought; only an order that owed nothing at all is
            // left out below, since no charge can be its.
            guard let id = field(idColumn), let date = field(dateColumn).flatMap(parseDate), let owed = field(owedColumn).flatMap(parseMoney),
                  owed.minorUnits >= 0, field(statusColumn)?.lowercased().contains("cancel") != true else {
                skipped += 1
                continue
            }
            let quantity = field(quantityColumn).flatMap { Int($0) } ?? 1
            var name = field(nameColumn) ?? "An item"
            if name.count > 80 { name = String(name.prefix(79)).trimmingCharacters(in: .whitespaces) + "…" }
            if quantity > 1 { name += " ×\(quantity)" }
            let item = Order.Item(name: name, quantity: quantity, total: owed, shippedAt: field(shipColumn).flatMap(parseDate))
            if orders[id] == nil {
                orders[id] = Order(id: id, orderedAt: date, items: [])
                order.append(id)
            }
            orders[id]!.items.append(item)
            orders[id]!.orderedAt = min(orders[id]!.orderedAt, date)
        }
        let all = order.compactMap { orders[$0] }
        let owing = all.filter { $0.total.minorUnits > 0 }
        skipped += all.filter { $0.total.minorUnits == 0 }.map(\.items.count).reduce(0, +)
        return Parsed(orders: owing, skippedLines: skipped)
    }

    /// "2026-09-14T18:22:11Z", "2026-09-14T18:22:11.000Z", "2026-09-14", "09/14/2026", "09/14/26" (Amazon's older reports).
    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        if let instant = try? Date(s, strategy: .iso8601) { return instant }
        if let instant = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return instant }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        if let m = s.prefixMatch(of: /(\d{4})-(\d{2})-(\d{2})/) {
            return utc.date(from: DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3), hour: 12))
        }
        if let m = s.wholeMatch(of: /(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})/), let year = Int(m.3) {
            return utc.date(from: DateComponents(year: year < 100 ? 2000 + year : year, month: Int(m.1), day: Int(m.2), hour: 12))
        }
        return nil
    }

    /// "$1,234.50", "12.3", "'12.30'" → minor units. Nil for anything else.
    static func parseMoney(_ raw: String) -> Money? {
        let s = raw.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        return DecimalAmount(string: s)?.money()
    }
}
