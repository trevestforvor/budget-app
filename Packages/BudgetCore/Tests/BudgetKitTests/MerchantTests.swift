import Foundation
import Testing
@testable import BudgetKit

/// A coffee shop seen this month, last month and last year, with a refund, a hidden row and one charge filed elsewhere;
/// a grocer and a ride service this month; and a transfer that's no merchant's spending.
private enum Shops {
    static let rows = [
        Rows.row("a", "card", 1, -6.50, "BLUE BOTTLE", "dining"),
        Rows.row("b", "card", 3, -5.00, "BLUE BOTTLE", "dining"),
        Rows.row("h", "card", 10, -4.00, "BLUE BOTTLE", "shopping"),
        Rows.row("c", "card", 40, -7.25, "BLUE BOTTLE", "dining"),
        Rows.row("d", "card", 41, 5.00, "BLUE BOTTLE", "dining"),
        Rows.row("e", "card", 70, -8.00, "BLUE BOTTLE", "dining", hidden: true),
        Rows.row("f", "card", 400, -9.00, "BLUE BOTTLE", "dining"),
        Rows.row("t1", "chk", 2, -30, "TRADER JOE S", "groceries"),
        Rows.row("t2", "chk", 4, -40, "TRADER JOE S", "groceries"),
        Rows.row("t3", "chk", 6, -50, "TRADER JOE S", "groceries"),
        Rows.row("u1", "card", 2, -25, "UBER", "transport"),
        Rows.row("u2", "card", 5, -25, "UBER", "transport"),
        Rows.row("x1", "chk", 2, -500, "TRANSFER TO SAV", "transfer"),
        Rows.row("x2", "chk", 3, -400, "TRANSFER TO SAV", "transfer"),
        Rows.row("x3", "chk", 4, -300, "TRANSFER TO SAV", "transfer"),
        Rows.row("x4", "chk", 5, -200, "TRANSFER TO SAV", "transfer"),
    ]
    static func ledger() -> Ledger { Rows.ledger(rows) }
}

@Suite("Merchant pages")
struct MerchantSummaryTests {
    @Test("This month, the last 12 months and all time follow the Spending tab's rule: refunds net, hidden rows out")
    func totals() throws {
        let m = try Shops.ledger().merchantSummary("blue bottle")
        #expect(m.merchant == "Blue Bottle")
        #expect(m.thisMonth == Money(15.50))          // 6.50 + 5.00 dining, 4.00 shopping
        #expect(m.lastTwelveMonths == Money(17.75))   // dining 6.50 + 5.00 + 7.25 − 5.00 refund, shopping 4.00; hidden 8.00 left out
        #expect(m.lifetime == Money(26.75))           // and last year's 9.00
        #expect(m.charges == 5 && m.chargesLastTwelveMonths == 4)
        #expect(m.averageCharge == Money(6.35))       // (6.50 + 5.00 + 4.00 + 7.25 + 9.00) / 5
        #expect(m.categoryID == "dining")
        #expect(m.categoryIDs == ["dining", "shopping"])
        #expect(m.frequency == "About once every 3 months")
        #expect(m.transactionCount == 7 && m.transactions.first?.id == "a" && m.transactions.count == 7)
        #expect(m.lastCharge == m.transactions.first?.postedAt)
        #expect(m.recurring == nil && m.cap == nil)
    }

    @Test("The months run oldest first to this one, add up to the year, and carry the cap as their target")
    func months() throws {
        var ledger = Shops.ledger()
        _ = try ledger.perform(.setMerchantTarget(SetMerchantTarget(merchant: "Blue Bottle", monthlyAmount: DecimalAmount(string: "40")!)))
        let m = try ledger.merchantSummary("Blue Bottle")
        #expect(m.months.count == 12)
        #expect(m.months.last?.month == "2026-09" && m.months.last?.spent == m.thisMonth)
        #expect(m.months.map(\.spent).sum() == m.lastTwelveMonths)
        #expect(m.months.allSatisfy { $0.target == Money(40) })
        #expect(m.cap == MerchantCap(merchant: "Blue Bottle", spent: Money(15.50), target: Money(40)))
    }

    @Test("An unknown merchant is not found")
    func unknown() {
        #expect(throws: BudgetAPIError.notFound) { try Shops.ledger().merchantSummary("Nowhere Diner") }
    }

    @Test("A recurring merchant carries its series, the same one Recurring lists")
    func recurring() throws {
        let ledger = Fixture.ledger()
        let netflix = try ledger.merchantSummary("Netflix")
        #expect(netflix.recurring?.cadence == .monthly)
        #expect(netflix.recurring == ledger.subscriptions().items.first { $0.merchant == "Netflix" })
        #expect(netflix.frequency == "About once a month")
        #expect(netflix.averageCharge == Money(15.49))
    }

    @Test("Frequency in words", arguments: [
        (0, nil, "No charges in the last 12 months"), (1, 0.08, "One charge in the last 12 months"), (12, 1.0, "About once a month"),
        (20, 6.0, "About 6 times a month"), (40, 8.0, "About twice a week"), (90, 13.0, "About 3 times a week"),
        (3, 0.25, "About once every 4 months"), (8, 0.7, "About once a month"),
    ] as [(Int, Double?, String)])
    func frequency(visits: Int, rate: Double?, phrase: String) {
        #expect(Ledger.frequencyPhrase(visits: visits, perMonth: rate) == phrase)
    }
}

@Suite("Most frequent merchants")
struct TopMerchantsTests {
    @Test("Most charges first, ties to the bigger spend; transfers aren't a merchant's spending")
    func byVisits() throws {
        let top = try Shops.ledger().topMerchants(period: "this_month", limit: 5)
        #expect(top.merchants.map(\.merchant) == ["Trader Joe S", "Blue Bottle", "Uber"])
        #expect(top.merchants.map(\.visits) == [3, 3, 2])
        #expect(top.merchants.map(\.spent) == [Money(120), Money(15.50), Money(50)])
        #expect(top.merchantCount == 3 && top.label == "September 2026")
        #expect(top.merchants[1].categoryID == "dining")
    }

    @Test("Most spent first, a limit, and an unknown period refused")
    func bySpent() throws {
        let ledger = Shops.ledger()
        let top = try ledger.topMerchants(period: "this_month", limit: 2, sort: .spent)
        #expect(top.merchants.map(\.merchant) == ["Trader Joe S", "Uber"])
        #expect(top.merchantCount == 3)
        #expect(throws: BudgetAPIError.self) { try ledger.topMerchants(period: "someday") }
    }

    @Test("Each merchant's spend agrees with the Activity summary for the same rows")
    func agreesWithSummary() throws {
        let ledger = Fixture.ledger()
        let top = try ledger.topMerchants(period: "last_90_days", limit: 8)
        #expect(!top.merchants.isEmpty)
        for merchant in top.merchants {
            let rows = ledger.matching(TransactionFilter(period: "last_90_days")).filter { Ledger.isMerchant($0, merchant.merchant) }
            #expect(merchant.spent == ledger.netSpend(rows), "\(merchant.merchant)")
        }
    }
}

// MARK: - Amazon orders

/// An Amazon order history file: a two-item order, an order charged a shipment at a time, an order for a charge the
/// person filed, one charged too long after it was placed, one from before the ledger, a cancelled line and a bad one.
private enum Orders {
    static func day(_ daysAgo: Int) -> String {
        Fixture.calendar.date(byAdding: .day, value: -daysAgo, to: EngineFixture.now)!.formatted(.iso8601)
    }

    static var csv: String {
        """
        Website,Order ID,Order Date,Currency,Unit Price,Total Owed,Quantity,Order Status,Ship Date,Product Name
        Amazon.com,111-0000001-0000001,\(day(7)),USD,15.00,"$30.00",2,Closed,\(day(6)),"Organic whole bean coffee, 2 lb"
        Amazon.com,111-0000001-0000001,\(day(7)),USD,12.17,12.17,1,Closed,\(day(6)),Coffee grinder brush
        Amazon.com,111-0000002-0000002,\(day(14)),USD,18.99,18.99,1,Closed,\(day(13)),Paperback novel
        Amazon.com,111-0000002-0000002,\(day(14)),USD,25.00,25.00,1,Closed,\(day(12)),Desk organizer
        Amazon.com,111-0000003-0000003,\(day(30)),USD,60.00,60.00,1,Closed,\(day(29)),Instant oatmeal variety pack
        Amazon.com,111-0000004-0000004,\(day(35)),USD,15.00,15.00,1,Closed,Not Available,Phone case
        Amazon.com,111-0000005-0000005,\(day(9)),USD,99.00,99.00,1,Cancelled,Not Available,Blender
        Amazon.com,111-0000006-0000006,\(day(500)),USD,10.00,10.00,1,Closed,\(day(499)),Old thing
        Amazon.com,111-0000007-0000007,someday,USD,10.00,10.00,1,Closed,,Mystery
        """
    }

    static let rows = [
        Rows.row("o1", "card", 5, -42.17, "AMAZON MKTPLACE PMTS", "shopping"),
        Rows.row("o2a", "card", 12, -18.99, "AMAZON MKTPLACE PMTS", "shopping"),
        Rows.row("o2b", "card", 13, -25.00, "AMAZON MKTPLACE PMTS", "shopping"),
        Rows.row("o3", "card", 30, -60.00, "AMAZON.COM", "shopping", tier: .user),
        Rows.row("old", "card", 20, -15.00, "AMAZON.COM", "shopping"),
        Rows.row("tgt", "card", 5, -42.17, "TARGET", "shopping"),
    ]

    static func ledger() -> Ledger { Rows.ledger(rows) }
}

@Suite("Amazon order matching")
struct OrderMatchingTests {
    @Test("The file reads: items per order, quoted names, quantities, dollar signs; cancelled and unreadable lines skipped")
    func parse() throws {
        let parsed = try OrderHistory.parseAmazon(Orders.csv)
        #expect(parsed.orders.count == 5)
        #expect(parsed.skippedLines == 2)
        let first = try #require(parsed.orders.first)
        #expect(first.id == "111-0000001-0000001" && first.total == Money(42.17))
        #expect(first.items.map(\.name) == ["Organic whole bean coffee, 2 lb ×2", "Coffee grinder brush"])
        #expect(first.shipments(in: Fixture.calendar) == nil)
        #expect(parsed.orders[1].shipments(in: Fixture.calendar)?.map { $0.items.map(\.name) } == [["Paperback novel"], ["Desk organizer"]])
        #expect(parsed.orders[3].items[0].shippedAt == nil)
        #expect(throws: FileImport.ParseError.self) { try OrderHistory.parseAmazon("Date,Description,Amount\n2026-09-01,Coffee,-4.50") }
    }

    @Test("Orders match Amazon charges to the cent within a week, a shipment at a time when charged that way; items attach")
    func match() throws {
        var ledger = Orders.ledger()
        let parsed = try OrderHistory.parseAmazon(Orders.csv)
        let report = ledger.matchOrders(parsed.orders, skippedLines: parsed.skippedLines, apply: true)
        #expect(report.applied && report.orders == 5 && report.skippedLines == 2)
        #expect(report.matched == 4)
        #expect(report.unmatched == 1 && report.unmatchedOrders.map(\.orderID) == ["111-0000004-0000004"])
        #expect(report.beforeLedger == 1 && report.alreadyMatched == 0)
        #expect(Set(report.matches.map(\.transactionID)) == ["o1", "o2a", "o2b", "o3"])
        #expect(ledger.row("o1")?.orderMatch?.items == ["Organic whole bean coffee, 2 lb ×2", "Coffee grinder brush"])
        #expect(ledger.row("o1")?.orderMatch?.shipment == nil)
        #expect(ledger.row("o2a")?.orderMatch?.items == ["Paperback novel"])
        #expect(ledger.row("o2a")?.orderMatch?.shipment != nil)
        #expect(ledger.row("o2b")?.orderMatch?.orderID == "111-0000002-0000002")
        // Not Amazon, or a week too late: never matched.
        #expect(ledger.row("tgt")?.orderMatch == nil)
        #expect(ledger.row("old")?.orderMatch == nil)
        // Search finds a charge by what it bought.
        #expect(ledger.matching(TransactionFilter(search: "grinder")).map(\.id) == ["o1"])
    }

    @Test("Items that read as another category send the charge to review with that suggestion; nothing is re-filed")
    func suggestions() throws {
        var ledger = Orders.ledger()
        let report = ledger.matchOrders(try OrderHistory.parseAmazon(Orders.csv).orders, apply: true)
        #expect(report.suggested == 2)
        #expect(report.matches.first { $0.transactionID == "o1" }?.suggestedCategoryID == "groceries")
        #expect(report.matches.first { $0.transactionID == "o2a" }?.suggestedCategoryID == "entertainment")
        // Still filed where it was, waiting for the person, the items' category first.
        let o1 = try #require(ledger.row("o1"))
        #expect(o1.categorization?.categoryID == "shopping" && o1.categorization?.needsReview == true)
        #expect(ledger.suggestions["o1"]?.map(\.categoryID) == ["groceries", "shopping"])
        #expect(ledger.reviewReasons["o1"]?.contains("Amazon order 111-0000001-0000001") == true)
        #expect(ledger.reviewReasons["o1"]?.contains("Groceries") == true)
        // A desk organizer reads as shopping, where it's filed; the person's own answer is never questioned.
        #expect(ledger.row("o2b")?.categorization?.needsReview == false)
        #expect(ledger.row("o3")?.categorization?.needsReview == false && ledger.row("o3")?.orderMatch != nil)
        #expect(Set(ledger.reviewItems.map(\.id)) == ["o1", "o2a"])
    }

    @Test("Each order is its own review answer: one doesn't file another with the same descriptor")
    func ownAnswers() throws {
        var ledger = Orders.ledger()
        _ = ledger.matchOrders(try OrderHistory.parseAmazon(Orders.csv).orders, apply: true)
        #expect(ReviewGroup.groups(ledger.reviewItems).count == 2)
        let result = try ledger.confirm(transactionID: "o1", categoryID: "groceries")
        #expect(result.affectedTransactions == 1)
        #expect(ledger.row("o1")?.categorization?.categoryID == "groceries")
        #expect(ledger.row("o2a")?.categorization?.needsReview == true)
    }

    @Test("The order sets the group apart without changing its descriptor, so rules and memory still read the bank's text")
    func groupKey() throws {
        var ledger = Orders.ledger()
        _ = ledger.matchOrders(try OrderHistory.parseAmazon(Orders.csv).orders, apply: true)
        let group = try #require(ReviewGroup.groups(ledger.reviewItems).first { $0.contains("o1") })
        #expect(group.key.orderID == "111-0000001-0000001")
        #expect(group.key.descriptor == Descriptor.normalize("AMAZON MKTPLACE PMTS"))
        #expect(group.scopedRule.descriptorContains == Descriptor.normalize("AMAZON MKTPLACE PMTS"))
    }

    @Test("Answering one order doesn't teach merchant memory that the store is that category")
    func memory() throws {
        var ledger = Orders.ledger()
        _ = ledger.matchOrders(try OrderHistory.parseAmazon(Orders.csv).orders, apply: true)
        _ = try ledger.confirm(transactionID: "o1", categoryID: "groceries")
        // The coffee order was groceries; the next Amazon charge is still filed the way the store's other charges are.
        #expect(ledger.merchantMemory(excluding: [])[Descriptor.normalize("AMAZON MKTPLACE PMTS")] == "shopping")
    }

    @Test("Older reports: two-digit years, Item Total and Title; a free item stays with its order, an order owing nothing is left out")
    func olderReport() throws {
        let csv = """
        Order ID,Order Date,Title,Item Total,Shipment Date
        D01-1,09/10/26,Wool socks,$20.00,09/11/26
        D01-1,09/10/26,Free sample,$0.00,09/11/26
        D01-2,09/12/26,Free ebook,$0.00,
        """
        let parsed = try OrderHistory.parseAmazon(csv)
        #expect(parsed.orders.count == 1 && parsed.skippedLines == 1)
        let order = try #require(parsed.orders.first)
        #expect(order.items.map(\.name) == ["Wool socks", "Free sample"] && order.total == Money(20))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(utc.dateComponents([.year, .month, .day], from: order.orderedAt) == DateComponents(year: 2026, month: 9, day: 10))
    }

    @Test("Importing the same file again changes nothing, and a preview never does")
    func idempotent() throws {
        var ledger = Orders.ledger()
        let orders = try OrderHistory.parseAmazon(Orders.csv).orders
        let preview = ledger.matchOrders(orders, apply: false)
        #expect(!preview.applied && preview.matched == 4 && preview.suggested == 2)
        #expect(ledger.state == Orders.ledger().state)
        _ = ledger.matchOrders(orders, apply: true)
        let after = ledger.state
        let again = ledger.matchOrders(orders, apply: true)
        #expect(again.matched == 0 && again.suggested == 0)
        #expect(again.alreadyMatched == 3 && again.unmatched == 1 && again.beforeLedger == 1)
        #expect(ledger.state == after)
    }

    @Test("Over the API: a preview saves nothing, an import does, and a file that isn't an order history is refused")
    func api() async throws {
        let api = Rows.api(Orders.rows)
        let before = await api.state
        let preview = try await api.importAmazonOrders(Orders.csv, preview: true)
        #expect(preview.matched == 4 && !preview.applied)
        let unchanged = await api.state
        #expect(unchanged == before)
        let report = try await api.importAmazonOrders(Orders.csv, preview: false)
        #expect(report.applied && report.matched == 4)
        #expect(try await api.transaction(id: "o1").orderMatch?.orderID == "111-0000001-0000001")
        #expect(try await api.reviewQueue().count == 2)
        await #expect(throws: FileImport.ParseError.self) { try await api.importAmazonOrders("a,b\n1,2", preview: true) }
    }

    @Test("A row keeps its order when a synced copy replaces it, and old rows decode without one")
    func wire() throws {
        var matched = Rows.row("p", "card", 1, -9.99, "AMAZON.COM", "shopping")
        matched.orderMatch = OrderMatch(store: "Amazon", orderID: "111-1", items: ["Cable"])
        var copy = Rows.row("q", "card", 1, -9.99, "AMAZON.COM", "shopping")
        Ledger.carryUserFields(from: matched, to: &copy)
        #expect(copy.orderMatch == matched.orderMatch)
        let data = try JSONEncoder().encode(matched)
        #expect(try JSONDecoder().decode(LedgerTransaction.self, from: data) == matched)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["orderMatch"] = nil
        let old = try JSONDecoder().decode(LedgerTransaction.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.orderMatch == nil && old.id == "p")
    }

    @Test("Item names read as a category; unknown items are shopping; only the ledger's spending categories count")
    func itemCategories() {
        func item(_ name: String, _ total: Decimal) -> OrderHistory.Order.Item { .init(name: name, quantity: 1, total: Money(total), shippedAt: nil) }
        let categories = Ledger.categoryList
        #expect(OrderItemCategories.suggest([item("Multivitamin gummies", 20), item("Desk lamp", 5)], among: categories)?.categoryID == "health")
        #expect(OrderItemCategories.suggest([item("Hardcover cookbook", 30)], among: categories)?.categoryID == "entertainment")
        #expect(OrderItemCategories.suggest([item("HDMI cable", 9)], among: categories) == CategorySuggestion(categoryID: "shopping", confidence: 0.9))
        #expect(OrderItemCategories.suggest([item("Green tea", 9)], among: categories.filter { $0.id != "groceries" })?.categoryID == "shopping")
    }

    @Test("The demo shows what its latest Amazon charges bought, without moving a total or the review queue")
    func demo() {
        let ledger = Fixture.ledger()
        let matched = ledger.transactions.filter { $0.orderMatch != nil }
        #expect(matched.count == 3 && matched.allSatisfy { $0.merchant == "Amazon" && $0.categorization?.needsReview == false })
        #expect(ledger.reviewItems.count == 11)
    }
}

@Suite("Ask about merchants")
struct MerchantAskTests {
    @Test("Merchant questions answer from the ledger's tools, grounded, with calls the catalog accepts", arguments: [
        ("Where do I go most often?", "topMerchants"), ("How often do I go to Blue Bottle Coffee?", "merchantSummary"),
        ("Tell me about Netflix", "merchantSummary"),
    ])
    func answers(question: String, tool: String) async throws {
        let reply = try await Fixture.api().ask(question, conversationID: nil)
        #expect(reply.toolCalls.first?.name == tool, "\(reply.text)")
        for call in reply.toolCalls {
            #expect(throws: Never.self) { try ToolCatalog.validateArguments(tool: call.name, json: Data(call.arguments.utf8)) }
        }
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty, "\(reply.text)")
    }

    @Test("The read tools return the ledger's figures")
    func tools() async throws {
        let ledger = Fixture.ledger()
        let toolbox = DemoToolbox(ledger: ledger, decisions: nil)
        let (summary, figures) = try await toolbox.run(read: "merchantSummary", arguments: .object(["merchant": .string("netflix")]))
        guard case let .object(o) = summary else { Issue.record("not an object"); return }
        #expect(o["merchant"] == .string("Netflix"))
        #expect(o["averageCharge"] == .string(Money(15.49).display))
        #expect(figures.contains { $0.id == "merchant-recurring" && $0.value == Money(15.49) })
        let (top, _) = try await toolbox.run(read: "topMerchants", arguments: .object(["period": .string("last_90_days"), "sort": .string("spent"), "limit": .number(3)]))
        guard case let .object(t) = top, case let .array(list)? = t["merchants"] else { Issue.record("no merchants"); return }
        #expect(list.count == 3)
        let first = try ledger.topMerchants(period: "last_90_days", limit: 1, sort: .spent).merchants[0]
        #expect(list.first == .object(["merchant": .string(first.merchant), "charges": .number(Double(first.visits)), "spent": .string(first.spent.display),
                                       "categoryID": .string(first.categoryID ?? "")]))
    }
}
