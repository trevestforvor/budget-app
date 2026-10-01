import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

/// The dashboard's own reads: statement coverage, the review queue in groups (and filing one by its exact ids, with
/// undo), and categories with the colors they wear.
@Suite("Dashboard data")
struct DashboardDataTests {
    static let dash: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]

    static func app(_ state: LedgerState) async throws -> (some ApplicationProtocol, BudgetService) {
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: MemoryStore(ledger: state), logger: Logger(label: "test"))
        try await BudgetServerApp.prepare(service)
        return (Application(router: buildRouter(service, surface: .dashboard)), service)
    }

    static func json(_ buffer: ByteBuffer) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any])
    }

    static func row(_ id: String, _ account: String, _ description: String, _ merchant: String, cents: Int64, daysAgo: Double,
                    review: Bool = true, guess: String = "shopping", hidden: Bool = false) -> LedgerTransaction {
        LedgerTransaction(id: id, accountID: account, postedAt: Date().addingTimeInterval(-daysAgo * 86400), merchant: merchant, rawDescription: description,
                          amount: Money(minorUnits: cents), categorization: Categorization(categoryID: guess, confidence: 0.4, tier: review ? .decisionModel : .user, needsReview: review),
                          isPending: false, source: .fileImport, isHidden: hidden)
    }

    @Test("Coverage: rows per account and month in the ledger's time zone, gaps only after an account's first row, never this month")
    func coverage() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))! }
        var state = LedgerState.empty
        state.accounts = [
            Account(id: "chk", name: "Checking", institution: "Harbor", kind: .checking, balance: Money(minorUnits: 0), source: .plaid),
            Account(id: "keystone", name: "Keystone Mastercard", institution: "Keystone", kind: .credit, balance: Money(minorUnits: 0), source: .fileImport, mask: "4410"),
            Account(id: "inv", name: "Brokerage", institution: "Northwind", kind: .investment, balance: Money(minorUnits: 0), source: .plaid),
            Account(id: "new", name: "New card", institution: "Summit", kind: .credit, balance: Money(minorUnits: 0), source: .fileImport),
        ]
        func tx(_ id: String, _ account: String, _ date: Date, hidden: Bool = false) -> LedgerTransaction {
            LedgerTransaction(id: id, accountID: account, postedAt: date, merchant: "M", rawDescription: "M", amount: Money(minorUnits: -100),
                              categorization: nil, isPending: false, source: .fileImport, isHidden: hidden)
        }
        state.transactions = [
            tx("c1", "chk", day(2026, 9, 2)), tx("c2", "chk", day(2026, 8, 30)), tx("c3", "chk", day(2026, 8, 3), hidden: true),
            // 11 pm on June 30 in Los Angeles is July 1 in UTC: it's June's row.
            tx("b1", "keystone", day(2026, 6, 30, hour: 23)), tx("b2", "keystone", day(2026, 4, 10)), tx("b3", "keystone", day(2023, 1, 5)),
        ]
        let coverage = DashboardCoverage.build(state: state, now: now, calendar: calendar)
        #expect(coverage.months.count == 24 && coverage.months.first == "2024-10" && coverage.months.last == "2026-09")
        // Accounts by institution then name; a balance-only account with no rows is left out, a statement account isn't.
        #expect(coverage.accounts.map(\.id) == ["chk", "keystone", "new"])
        let index = { (month: String) in coverage.months.firstIndex(of: month)! }
        let chk = coverage.accounts.first { $0.id == "chk" }!
        #expect(chk.counts[index("2026-09")] == 1 && chk.counts[index("2026-08")] == 2)  // hidden rows came in with the data too
        #expect(chk.gaps.isEmpty && chk.firstMonth == "2026-08")
        let keystone = coverage.accounts.first { $0.id == "keystone" }!
        #expect(keystone.counts[index("2026-06")] == 1 && keystone.counts[index("2026-07")] == 0 && keystone.counts.reduce(0, +) == 2)  // 2023 is before the window
        #expect(keystone.firstMonth == "2023-01" && keystone.mask == "4410")
        // Every empty month in the window since its first row, through August; September is still under way.
        #expect(keystone.gaps.count == 21 && keystone.gaps.first == "2024-10" && keystone.gaps.last == "2026-08" && !keystone.gaps.contains("2026-06") && !keystone.gaps.contains("2026-04"))
        let fresh = coverage.accounts.first { $0.id == "new" }!
        #expect(fresh.counts.allSatisfy { $0 == 0 } && fresh.gaps.isEmpty && fresh.firstMonth == nil)
    }

    @Test("Review groups: one account, one direction, one descriptor; big amounts alone; filing sends exactly a group's ids, and undo puts them back")
    func reviewGroups() async throws {
        var state = LedgerState.empty
        state.decisionPolicy.reviewAbove = DecimalAmount(minorUnits: 30000)
        state.accounts = [
            Account(id: "card", name: "Gold Card", institution: "Summit", kind: .credit, balance: Money(minorUnits: 0), source: .fileImport),
            Account(id: "card2", name: "Sapphire", institution: "Harbor", kind: .credit, balance: Money(minorUnits: 0), source: .fileImport),
            Account(id: "sav", name: "Cash", institution: "Meadow", kind: .savings, balance: Money(minorUnits: 0), source: .fileImport),
        ]
        state.transactions = [
            Self.row("b1", "card", "SQ *BLUE BOTTLE 1234", "Blue Bottle", cents: -675, daysAgo: 1),
            Self.row("b2", "card", "SQ *BLUE BOTTLE 1234", "Blue Bottle", cents: -700, daysAgo: 8),
            Self.row("b3", "card", "SQ *BLUE BOTTLE 0017", "Blue Bottle", cents: -525, daysAgo: 15),
            Self.row("b4", "card2", "SQ *BLUE BOTTLE 1234", "Blue Bottle", cents: -600, daysAgo: 3),   // another account
            Self.row("br", "card", "SQ *BLUE BOTTLE 1234", "Blue Bottle", cents: 675, daysAgo: 2),     // a refund: money in
            Self.row("w1", "sav", "WITHDRAWAL", "Withdrawal", cents: -25000, daysAgo: 4),
            Self.row("w2", "sav", "WITHDRAWAL", "Withdrawal", cents: -20000, daysAgo: 20),
            Self.row("p1", "card", "PAYPAL *XJ29QK", "PayPal", cents: -6400, daysAgo: 5),
            Self.row("s1", "card", "SQ *4455", "Square", cents: -1000, daysAgo: 6),
            Self.row("x1", "card", "DELTA AIR 0062", "Delta", cents: -64200, daysAgo: 9),
            Self.row("x2", "card", "DELTA AIR 0063", "Delta", cents: -70000, daysAgo: 10),
            Self.row("done", "card", "SQ *BLUE BOTTLE 1234", "Blue Bottle", cents: -675, daysAgo: 30, review: false, guess: "dining"),
        ]
        state.suggestions = [
            "b1": [CategorySuggestionFixture.make("dining", 0.8), CategorySuggestionFixture.make("groceries", 0.1)],
            "b2": [CategorySuggestionFixture.make("dining", 0.8)],
            "b3": [CategorySuggestionFixture.make("dining", 0.5), CategorySuggestionFixture.make("groceries", 0.2)],
            "w1": [CategorySuggestionFixture.make("income", 0.7), CategorySuggestionFixture.make("transfer", 0.2)],
        ]
        state.reviewReasons = ["b1": "New merchant.", "b2": "New merchant.", "b3": "Unsure."]
        let (app, service) = try await Self.app(state)
        try await app.test(.router) { client in
            var groups: [[String: Any]] = []
            @Sendable func ids(_ g: [String: Any]) -> [String] { g["transactionIDs"] as! [String] }
            try await client.execute(uri: "/dash/review/groups", method: .get) { response in
                #expect(response.status == .ok)
                let body = try Self.json(response.body)
                groups = body["groups"] as! [[String: Any]]
                #expect(body["transactions"] as? Int == 11)
            }
            // Most rows first, then the most money, then the most recent.
            #expect(groups.map(ids) == [["b1", "b2", "b3"], ["w1", "w2"], ["x2"], ["x1"], ["p1"], ["s1"], ["br"], ["b4"]])
            let blue = try #require(groups.first)
            #expect(ids(blue) == ["b1", "b2", "b3"])  // biggest group first, newest row first
            #expect(blue["merchant"] as? String == "Blue Bottle" && blue["descriptor"] as? String == "BLUE BOTTLE" && blue["direction"] as? String == "out")
            #expect(blue["reason"] as? String == "New merchant.")
            #expect((blue["total"] as? [String: Any])?["minor"] as? Int == -1900)
            let suggestions = blue["suggestions"] as! [[String: Any]]
            #expect(suggestions.map { $0["categoryID"] as! String } == ["dining", "groceries"])
            #expect(abs((suggestions[0]["confidence"] as! Double) - 0.7) < 0.0001)  // averaged over the three rows
            let withdrawals = try #require(groups.first { ids($0) == ["w1", "w2"] })
            #expect(withdrawals["isGeneric"] as? Bool == true)
            #expect((withdrawals["suggestions"] as! [[String: Any]]).map { $0["categoryID"] as! String } == ["transfer"])  // money out is never offered Income
            // Descriptors that name no merchant are told apart by the merchant; amounts over $300 come one by one.
            #expect(groups.contains { ids($0) == ["p1"] } && groups.contains { ids($0) == ["s1"] })
            #expect(groups.filter { $0["isLarge"] as? Bool == true }.map(ids) == [["x2"], ["x1"]])
            #expect(groups.contains { ids($0) == ["b4"] } && groups.contains { ids($0) == ["br"] })
            // "Make a rule" starts from the phone's rule: a code-only descriptor keeps its text and its account, never an
            // empty condition; a merchant's reads as memory does.
            let paypal = try #require(groups.first { ids($0) == ["p1"] }?["rule"] as? [String: Any])
            #expect(paypal["descriptorContains"] as? String == "PAYPAL *XJ29QK" && paypal["accountID"] as? String == "card" && paypal["direction"] as? String == "out")
            let blueRule = try #require(blue["rule"] as? [String: Any])
            #expect(blueRule["descriptorContains"] as? String == "BLUE BOTTLE" && blueRule["accountID"] == nil)
            // The phone counts the same decisions.
            let overview = try await service.api.overview()
            #expect(overview.reviewDecisions == groups.count && overview.reviewCount == 11)
            #expect(overview.reviewHeadline == "\(groups.count) quick answers file 11 transactions.")

            // File the group by its ids: the same descriptor on the other card, and the refund, stay waiting.
            var undo: AppAction?
            let file = #"{"type":"editTransactions","transactionIDs":["b1","b2","b3"],"categoryID":"dining"}"#
            try await client.execute(uri: "/v1/actions", method: .post, headers: Self.dash, body: TestServer.body(file)) { response in
                #expect(response.status == .ok)
                let result = try RemoteBudgetAPI.decoder.decode(ActionResult.self, from: Data(response.body.readableBytesView))
                #expect(result.affectedTransactions == 3)
                undo = result.undo
            }
            try await client.execute(uri: "/dash/review/groups", method: .get) { response in
                let after = (try Self.json(response.body))["groups"] as! [[String: Any]]
                #expect(!after.contains { ids($0).contains("b1") })
                #expect(after.contains { ids($0) == ["b4"] } && after.contains { ids($0) == ["br"] })
            }
            #expect(try await service.api.transaction(id: "b4").categorization?.needsReview == true)
            let undoBody = String(decoding: try RemoteBudgetAPI.encoder.encode(try #require(undo)), as: UTF8.self)
            try await client.execute(uri: "/v1/actions", method: .post, headers: Self.dash, body: TestServer.body(undoBody)) { #expect($0.status == .ok) }
            try await client.execute(uri: "/dash/review/groups", method: .get) { response in
                let back = (try Self.json(response.body))["groups"] as! [[String: Any]]
                #expect(back.first.map(ids) == ["b1", "b2", "b3"])
                #expect((back.first?["suggestions"] as? [[String: Any]])?.first?["categoryID"] as? String == "dining")  // suggestions come back too
            }
        }
    }

    @Test("The summary names every category with the color it wears; coverage and groups are only on the dashboard's listener")
    func categoriesAndListeners() async throws {
        let (app, service) = try await Self.app(LedgerBudgetAPI.demoState(now: Date(), calendar: TestServer.config().calendar))
        _ = try await service.api.perform(.updateCategory(UpdateCategory(categoryID: "groceries", color: "coral")))
        _ = try await service.api.perform(.mergeCategory(MergeCategory(from: "entertainment", into: "shopping")))
        try await app.test(.router) { client in
            try await client.execute(uri: "/dash/summary", method: .get) { response in
                let categories = (try Self.json(response.body))["categories"] as! [[String: Any]]
                let color = { (id: String) in categories.first { $0["id"] as? String == id }?["color"] as? String }
                #expect(color("health") == "rose" && color("subscriptions") == "irisDeep" && color("groceries") == "coral")
                #expect(categories.first { $0["id"] as? String == "entertainment" }?["isArchived"] as? Bool == true)
                #expect(categories.allSatisfy { CategoryColor(rawValue: $0["color"] as? String ?? "") != nil })
                // Each says its kind: Income and the demo's Card rewards are money in; Transfer is spending that doesn't count.
                let kind = { (id: String) in categories.first { $0["id"] as? String == id }?["kind"] as? String }
                #expect(kind("income") == "moneyIn" && kind("card-rewards") == "moneyIn" && kind("groceries") == "spending" && kind("transfer") == "spending")
            }
            try await client.execute(uri: "/dash/coverage", method: .get) { response in
                #expect(response.status == .ok)
                let body = try Self.json(response.body)
                #expect((body["months"] as? [String])?.count == 24 && !((body["accounts"] as? [Any]) ?? []).isEmpty)
            }
        }
        let (api, _) = try await TestServer.app()
        try await api.test(.router) { client in
            try await client.execute(uri: "/dash/coverage", method: .get, headers: TestServer.auth) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/dash/review/groups", method: .get, headers: TestServer.auth) { #expect($0.status == .notFound) }
        }
    }
}

extension DashboardDataTests {
    @Test("A review group going out is never offered a money-in category; one coming in may be")
    func moneyInSuggestions() throws {
        var categories = LedgerState.empty.categories
        categories.insert(BudgetCategory(id: "card-rewards", name: "Card rewards", symbol: "gift", kind: .moneyIn), at: categories.count - 1)
        // `ReviewItem` has no public memberwise init either; it decodes like the wire sends it.
        func item(_ id: String, cents: Int64, _ suggestions: [(String, Double)]) throws -> ReviewItem {
            let row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.row(id, "card", "SUMMIT DINING CREDIT", "Dining credit", cents: cents, daysAgo: 1)))
            let body: [String: Any] = ["transaction": row, "reason": "Unsure.",
                                       "suggestions": suggestions.map { ["categoryID": $0.0, "confidence": $0.1] as [String: Any] }]
            return try JSONDecoder().decode(ReviewItem.self, from: JSONSerialization.data(withJSONObject: body))
        }
        let groups = DashboardReviewGroups.build(queue: [try item("out", cents: -1000, [("card-rewards", 0.6), ("income", 0.2), ("dining", 0.1)]),
                                                         try item("in", cents: 1000, [("card-rewards", 0.6), ("dining", 0.1)])], categories: categories).groups
        let offered = { (direction: TransactionFilter.Direction) in groups.first { $0.direction == direction }?.suggestions.map(\.categoryID) }
        #expect(offered(.moneyOut) == ["dining"])
        #expect(offered(.moneyIn) == ["card-rewards", "dining"])
    }
}

/// `CategorySuggestion` has no public memberwise init; it decodes like the wire sends it.
enum CategorySuggestionFixture {
    static func make(_ id: String, _ confidence: Double) -> CategorySuggestion {
        try! JSONDecoder().decode(CategorySuggestion.self, from: Data(#"{"categoryID":"\#(id)","confidence":\#(confidence)}"#.utf8))
    }
}
