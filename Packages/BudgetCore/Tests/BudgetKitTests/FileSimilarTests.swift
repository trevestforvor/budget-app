import Foundation
import Testing
@testable import BudgetKit

extension Rows {
    static func fileSimilar(_ ids: [String], _ categoryID: String?) -> AppAction {
        .editTransactions(EditTransactions(transactionIDs: ids, categoryID: categoryID, fileSimilar: true))
    }
}

@Suite("Filing similar transactions")
struct FileSimilarTests {
    /// Blue Bottle under several descriptors and states, plus rows that only look alike.
    static var rows: [LedgerTransaction] {
        var online = Rows.row("online", "card", 6, -11, "BBC ONLINE ORDER", "shopping")
        online.merchant = "Blue Bottle Coffee 0423" // the same merchant name under another descriptor
        return [
            Rows.row("a", "card", 1, -6, "BLUE BOTTLE COFFEE 0423", "shopping"),
            Rows.row("b", "card", 2, -7, "BLUE BOTTLE COFFEE 0501", "shopping"),
            Rows.row("mine", "card", 3, -8, "BLUE BOTTLE COFFEE", "groceries", tier: .user),
            Rows.row("settled", "chk", 4, -9, "BLUE BOTTLE COFFEE", "dining"),
            Rows.row("waiting", "card", 5, -5, "BLUE BOTTLE COFFEE", "dining", tier: .model, review: true),
            online,
            Rows.row("refund", "card", 7, 6, "BLUE BOTTLE COFFEE", "shopping"),
            Rows.row("other", "card", 8, -10, "SQ *CASA TACO 0423", "shopping"),
        ]
    }

    @Test("Re-filing one row offers the rest from its merchant or descriptor, going the same way, with its refunds; the person's own answers stay")
    func preview() throws {
        let ledger = Rows.ledger(Self.rows)
        let similar = ledger.similarRows(to: [0], under: "dining")
        // The refund follows the purchases, so Dining stays net of it and Shopping isn't left holding it.
        #expect(Set(similar.rows.map { ledger.transactions[$0].id }) == ["b", "waiting", "online", "refund"])
        #expect(similar.yours == 1)
        let preview = try ledger.preview(Rows.fileSimilar(["a"], "dining"))
        #expect(preview.title == "File 5 transactions under Dining")
        #expect(preview.matchCount == 5 && preview.changeCount == 4) // "waiting" is already under Dining; it leaves review
        #expect(preview.detail?.contains("That includes 4 more like it, 1 of them a refund: the same merchant or bank description.") == true)
        #expect(preview.detail?.contains("The 1 you filed yourself keeps its category.") == true)
        // Without fileSimilar, only the row named.
        #expect(try ledger.preview(Rows.edit(["a"], categoryID: "dining")).matchCount == 1)
    }

    @Test("A row matched to an order reaches only that order's other charges; rows matched to other orders are never swept")
    func orderMatchedRows() throws {
        func amazon(_ id: String, _ day: Double, _ amount: Decimal, order: String?, items: [String]) -> LedgerTransaction {
            var row = Rows.row(id, "card", day, amount, "AMZN MKTP US*\(id)", "shopping")
            row.merchant = "Amazon"
            row.orderMatch = order.map { OrderMatch(store: "Amazon", orderID: $0, items: items) }
            return row
        }
        let rows = [amazon("a", 10, -24.99, order: "111", items: ["Multivitamin 200ct"]),
                    amazon("a2", 11, -6.50, order: "111", items: ["Multivitamin 200ct"]),
                    amazon("b", 8, -18.50, order: "222", items: ["Paperback novel"]),
                    amazon("c", 5, -42, order: nil, items: []),
                    amazon("d", 4, -12, order: nil, items: [])]
        var ledger = Rows.ledger(rows)
        func similar(_ ids: [String], _ category: String) -> Set<String> {
            let indices = ids.compactMap { id in ledger.transactions.firstIndex { $0.id == id } }
            return Set(ledger.similarRows(to: indices, under: category).rows.map { ledger.transactions[$0].id })
        }
        // The vitamins reach the same order's other shipment, not the novel or the unmatched charges.
        #expect(similar(["a"], "health") == ["a2"])
        // An unmatched charge reaches other unmatched ones from the merchant, never an order-matched one.
        #expect(similar(["c"], "groceries") == ["d"])
        _ = try ledger.perform(Rows.fileSimilar(["a"], "health"))
        let filed = Dictionary(uniqueKeysWithValues: ledger.transactions.map { ($0.id, $0.categorization?.categoryID) })
        #expect(filed["a"] == "health" && filed["a2"] == "health")
        #expect(filed["b"] == "shopping" && filed["c"] == "shopping" && filed["d"] == "shopping")
    }

    @Test("Applying files them as the person's answer, and one undo puts every row back")
    func applyAndUndo() throws {
        var ledger = Rows.ledger(Self.rows, suggestions: ["waiting": [CategorySuggestion(categoryID: "dining", confidence: 0.4)]])
        let before = ledger.transactions
        let result = try ledger.perform(Rows.fileSimilar(["a"], "dining"))
        #expect(result.message == "Filed 5 transactions under Dining.")
        #expect(result.affectedTransactions == 5)
        for id in ["a", "b", "waiting", "online", "refund"] {
            #expect(ledger.row(id)?.categorization == Categorization(categoryID: "dining", confidence: 1, tier: .user, needsReview: false))
        }
        #expect(ledger.row("mine")?.categorization?.categoryID == "groceries")
        #expect(ledger.row("other")?.categorization?.categoryID == "shopping")
        #expect(ledger.reviewItems.isEmpty)
        _ = try ledger.perform(try #require(result.undo))
        #expect(ledger.transactions == before)
        #expect(ledger.suggestions["waiting"] == [CategorySuggestion(categoryID: "dining", confidence: 0.4)])
    }

    @Test("A generic descriptor or a payment app reaches nothing; a matched transfer stays one unless filed as a transfer")
    func limits() throws {
        let rows = [
            Rows.row("w1", "sav", 1, -1200, "Withdrawal", "transfer", tier: .model, review: true),
            Rows.row("w2", "sav", 2, -450, "Withdrawal", "transfer", tier: .model, review: true),
            Rows.row("v1", "chk", 3, -45, "VENMO *J. PARK", "dining"),
            Rows.row("v2", "chk", 4, -20, "VENMO *A. LEE", "dining"),
            Rows.row("p1", "chk", 5, -500, "ONLINE TRANSFER TO SAV", "transfer", peer: "p2"),
            Rows.row("p2", "sav", 5, 500, "ONLINE TRANSFER FROM CHK", "transfer", peer: "p1"),
            Rows.row("p3", "chk", 35, -500, "ONLINE TRANSFER TO SAV", "transfer", peer: "p4"),
            Rows.row("p4", "sav", 35, 500, "ONLINE TRANSFER FROM CHK", "transfer", peer: "p3"),
            Rows.row("p5", "chk", 65, -500, "ONLINE TRANSFER TO SAV", "housing", tier: .model),
        ]
        let ledger = Rows.ledger(rows)
        #expect(try ledger.preview(Rows.fileSimilar(["w1"], "housing")).matchCount == 1)
        #expect(try ledger.preview(Rows.fileSimilar(["v1"], "shopping")).matchCount == 1)
        // Filing one side of a move as savings leaves the other matched moves alone; as a transfer, the unpaired one joins.
        #expect(ledger.similarRows(to: [4], under: "shopping").rows.map { ledger.transactions[$0].id } == ["p5"])
        #expect(ledger.similarRows(to: [4], under: "transfer").rows.map { ledger.transactions[$0].id } == ["p5"])
        #expect(throws: BudgetAPIError.rejected("Filing similar transactions needs a category.")) {
            try ledger.preview(.editTransactions(EditTransactions(transactionIDs: ["v1"], isHidden: true, fileSimilar: true)))
        }
    }

    @Test("Money in follows a purchase only as a refund under spending; nothing follows into a money-in category")
    func directions() throws {
        let rows = [
            Rows.row("buy", "card", 1, -40, "ACME STORE 0101", "shopping"),
            Rows.row("buy2", "card", 2, -25, "ACME STORE 0102", "shopping"),
            Rows.row("back", "card", 3, 15, "ACME STORE 0103", "shopping"),
            Rows.row("pay", "chk", 4, 2000, "ACME STORE 0104", "income"),
            Rows.row("odd", "card", 5, 5, "ACME STORE 0105", nil),
        ]
        let ledger = Rows.ledger(rows)
        func ids(_ s: (rows: [Int], yours: Int)) -> Set<String> { Set(s.rows.map { ledger.transactions[$0].id }) }
        // A purchase to Groceries: the other purchase and the refund under Shopping; not the paycheck, not the unfiled credit.
        #expect(ids(ledger.similarRows(to: [0], under: "groceries")) == ["buy2", "back"])
        // Filing money in under Income reaches other money in only, never the purchases.
        #expect(ids(ledger.similarRows(to: [3], under: "income")) == ["back", "odd"])
        // A purchase filed as a transfer (not spending) takes no refunds along.
        #expect(ids(ledger.similarRows(to: [0], under: "transfer")) == ["buy2"])
    }

    @Test("The demo has rows to file together: a Blue Bottle visit reaches the others")
    func demo() throws {
        let ledger = Fixture.ledger()
        let coffee = try #require(ledger.transactions.first { $0.merchant == "Blue Bottle Coffee" })
        let preview = try ledger.preview(Rows.fileSimilar([coffee.id], "groceries"))
        let all = ledger.transactions.filter { $0.merchant == "Blue Bottle Coffee" }.count
        #expect(preview.matchCount == all && preview.changeCount == all)
    }
}

@Suite("CSV export")
struct CSVExportTests {
    @Test("RFC 4180: a field is quoted only when it holds a comma, a quote or a line break, and quotes inside are doubled")
    func quoting() {
        #expect(CSV.field("Blue Bottle") == "Blue Bottle")
        #expect(CSV.field("Coffee, beans") == "\"Coffee, beans\"")
        #expect(CSV.field("The \"good\" one") == "\"The \"\"good\"\" one\"")
        #expect(CSV.field("Line one\nLine two") == "\"Line one\nLine two\"")
        #expect(CSV.field("Line one\r\nLine two") == "\"Line one\r\nLine two\"")
        #expect(CSV.field("") == "")
        #expect(CSV.document(header: ["A", "B"], rows: [["1", "x,y"]]) == "A,B\r\n1,\"x,y\"\r\n")
        #expect(CSV.text("=HYPERLINK(\"x\")") == "'=HYPERLINK(\"x\")" && CSV.text("-5 off") == "'-5 off" && CSV.text("Uber") == "Uber")
    }

    static var ledger: Ledger {
        var tricky = Rows.row("tricky", "card", 1, -1234.5, "HARVEST TABLE", "dining", note: "Dinner, \"the good one\"\nwith Sam")
        tricky.merchant = "Harvest Table, Downtown"
        tricky.tags = ["Austin trip", "Work"]
        var formula = Rows.row("formula", "card", 2, -9.99, "=HYPERLINK(\"http://x\")", "subscriptions")
        formula.merchant = "+Plus App"
        return Rows.ledger([
            tricky, formula,
            Rows.row("rent", "chk", 3, -2400, "MAPLE CT APTS ACH", "housing"),
            Rows.row("pay", "chk", 4, 3850, "ACME CORP PAYROLL PPD", "income"),
            Rows.row("move", "chk", 5, -500, "ONLINE TRANSFER TO SAV", "transfer"),
            Rows.row("hid", "card", 6, -40, "OLIVE GRILL", "dining", pending: true, hidden: true),
            Rows.row("unfiled", "card", 7, -3, "MYSTERY", nil),
        ])
    }

    @Test("The export has the header, one CRLF-ended record per row in the filter's order, and reads back field for field")
    func document() throws {
        let csv = Self.ledger.exportCSV(TransactionFilter(limit: 1, offset: 3))
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines.first == "Date,Merchant,Description,Amount,Category,Bucket,Account,Tags,Note,Status,Hidden")
        #expect(csv.hasSuffix("\r\n"))
        let table = CSV.rows(csv)
        #expect(table.count == 8) // paging is ignored: every match
        #expect(table.allSatisfy { $0.count == 11 })
        let day = Date.ISO8601FormatStyle(timeZone: Fixture.calendar.timeZone).year().month().day()
        #expect(table[1] == [EngineFixture.day(1).formatted(day), "Harvest Table, Downtown", "HARVEST TABLE", "-1234.50", "Dining", "Everyday",
                             "Gold Card", "Austin trip; Work", "Dinner, \"the good one\"\nwith Sam", "Posted", "No"])
        #expect(table[2][1] == "'+Plus App" && table[2][2] == "'=HYPERLINK(\"http://x\")" && table[2][3] == "-9.99" && table[2][5] == "Subscriptions")
        #expect(table[3][5] == "Bills" && table[3][6] == "Total Checking ••0909")
        #expect(table[4][3] == "3850.00" && table[4][4] == "Income" && table[4][5] == "Money in")
        #expect(table[5][5] == "Transfer")
        #expect(table[6][9] == "Pending" && table[6][10] == "Yes")
        #expect(table[7][4] == "Uncategorized" && table[7][5] == "")
    }

    @Test("The export honors the filter: categories, tags, search and sort")
    func filtered() throws {
        let ledger = Self.ledger
        #expect(CSV.rows(ledger.exportCSV(TransactionFilter(categoryIDs: ["dining"]))).dropFirst().map { $0[1] } == ["Harvest Table, Downtown", "Olive Grill"])
        #expect(CSV.rows(ledger.exportCSV(TransactionFilter(tags: ["work"]))).count == 2)
        #expect(CSV.rows(ledger.exportCSV(TransactionFilter(sort: .largest))).dropFirst().first?[3] == "3850.00")
        #expect(ledger.exportCSV(TransactionFilter(search: "nothing like this")) == Ledger.exportHeader.joined(separator: ",") + "\r\n")
    }

    @Test("The API refuses a period it can't read, and the demo exports every row")
    func api() async throws {
        let api = Fixture.api()
        await #expect(throws: BudgetAPIError.rejected("Unknown period “someday”.")) { try await api.exportCSV(TransactionFilter(period: "someday")) }
        let data = try await api.exportCSV(TransactionFilter())
        #expect(CSV.rows(String(decoding: data, as: UTF8.self)).count == Fixture.ledger().transactions.count + 1)
    }
}
