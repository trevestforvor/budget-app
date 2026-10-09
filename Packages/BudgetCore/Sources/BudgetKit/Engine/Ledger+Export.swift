import Foundation

// Transactions as a CSV file (RFC 4180): `GET /v1/transactions/export.csv` and the app's Export.

/// RFC 4180 writing (reading is `CSV.rows`, for statement imports): CRLF after every record, a field quoted when it
/// holds a comma, a double quote, CR or LF, and a double quote inside one doubled.
extension CSV {
    static let lineBreak = "\r\n"
    /// U+FEFF, which the export's file starts with (`LedgerBudgetAPI.exportCSV`).
    static let byteOrderMark = "\u{FEFF}"

    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func record(_ fields: [String]) -> String { fields.map(field).joined(separator: ",") }

    /// Every record followed by CRLF, the first being the header.
    static func document(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { record($0) + lineBreak }.joined()
    }

    /// Text a spreadsheet would run as a formula ("=HYPERLINK(…)", "+1", "@SUM") gets a leading apostrophe, so a merchant
    /// name or a note from bank data stays text. Amounts are written apart and never pass through here.
    static func text(_ value: String) -> String {
        guard let first = value.first, ["=", "+", "-", "@", "\t", "\r"].contains(first) else { return value }
        return "'" + value
    }
}

extension Ledger {
    static let exportHeader = ["Date", "Merchant", "Description", "Amount", "Category", "Bucket", "Account", "Tags", "Note", "Status", "Hidden"]

    /// Every row `filter` matches, in its order, paging ignored. Dates are days in the ledger's time zone; amounts are
    /// signed (negative is money out) with two decimals; the bucket is Bills, Subscriptions or Everyday for spending (a
    /// recurring charge counts as its series' kind), Money in for a money-in category, Transfer for a move between
    /// accounts, and empty while unfiled. Tags are joined with "; ".
    func exportCSV(_ filter: TransactionFilter) -> String {
        var all = filter
        all.offset = 0
        let rows = matching(all)
        let byCategory = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byAccount = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kinds = recurringIndex.kinds
        let day = Date.ISO8601FormatStyle(timeZone: calendar.timeZone).year().month().day()
        let records = rows.map { row -> [String] in
            let category = row.categorization.flatMap { byCategory[$0.categoryID] }
            let bucket: String = if let group = bucket(of: row, categories: byCategory, kinds: kinds) { group.label }
                else if category?.isMoneyIn == true { "Money in" }
                else if let category, !category.countsAsSpending { category.name }
                else { "" }
            return [
                row.postedAt.formatted(day),
                CSV.text(row.merchant),
                CSV.text(row.rawDescription),
                Self.plainAmount(row.amount),
                CSV.text(category?.name ?? "Uncategorized"),
                bucket,
                CSV.text(byAccount[row.accountID]?.shortLabel ?? row.accountID),
                CSV.text((row.tags ?? []).joined(separator: "; ")),
                CSV.text(row.note ?? ""),
                row.isPending ? "Pending" : "Posted",
                row.isHidden ? "Yes" : "No",
            ]
        }
        return CSV.document(header: Self.exportHeader, rows: records)
    }

    /// "-42.50", "1250.00": no currency sign or grouping, so any spreadsheet reads it as a number.
    static func plainAmount(_ money: Money) -> String {
        let cents = money.minorUnits.magnitude
        let fraction = cents % 100
        return "\(money.minorUnits < 0 ? "-" : "")\(cents / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}
