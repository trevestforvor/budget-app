import Foundation
import Testing
@testable import BudgetKit

/// Fixed clock and calendar so every number is reproducible.
enum Fixture {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    static let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 10))!
    static func ledger() -> DemoLedger { DemoLedger(now: now, calendar: calendar, seed: 7) }
    static func api() -> DemoBudgetAPI { DemoBudgetAPI(now: now, calendar: calendar, seed: 7, latency: .zero) }
}

@Suite("Demo ledger does the math")
struct LedgerTests {
    @Test("Fixtures are deterministic for a seed")
    func deterministic() {
        #expect(Fixture.ledger().transactions == Fixture.ledger().transactions)
    }

    @Test("Category totals add up to the range total, for every range", arguments: SpendingRange.allCases)
    func totalsReconcile(range: SpendingRange) {
        let summary = Fixture.ledger().spendingSummary(range)
        #expect(summary.categories.map(\.spent).sum() == summary.total)
        #expect(summary.categories.allSatisfy { $0.category.countsAsSpending })
    }

    @Test("Transfers and income never count as spending")
    func transfersExcluded() {
        let ledger = Fixture.ledger()
        let window = ledger.interval(for: .last90Days)
        let manual = ledger.transactions(from: window.start, to: window.end)
            .filter { $0.amount.isNegative && !["transfer", "income"].contains($0.categorization!.categoryID) }
            .map(\.amount.magnitude).sum()
        #expect(ledger.spent(from: window.start, to: window.end) == manual)
    }

    @Test("Account balances reconcile with the cash figure")
    func balancesReconcile() {
        let ledger = Fixture.ledger()
        let overview = ledger.overview()
        let cash = ledger.accounts.filter { [.checking, .savings].contains($0.kind) }.map(\.balance).sum()
        #expect(ledger.accounts.contains { $0.kind == .investment && $0.balance == Money(48_210.10) })
        #expect(overview.cashOnHand == cash)
        #expect(overview.cashTrend.last?.balance == cash)
        #expect(ledger.accounts.first { $0.kind == .credit }!.balance.isNegative)
    }

    @Test("Card is paid monthly, so debt stays bounded")
    func cardBounded() {
        let card = Fixture.ledger().accounts.first { $0.kind == .credit }!
        #expect(card.balance.magnitude < Money(5000))
    }

    @Test("Summer dining really is higher than spring, so the Q3 question has an answer")
    func quartersDiffer() {
        let ledger = Fixture.ledger()
        let q3 = ledger.quarter(3, year: 2026), q2 = ledger.quarter(2, year: 2026)
        #expect(ledger.spent(from: q3.start, to: q3.end, categoryID: "dining") > ledger.spent(from: q2.start, to: q2.end, categoryID: "dining"))
    }

    @Test("Nothing is future-dated")
    func noFutureRows() {
        #expect(Fixture.ledger().transactions.allSatisfy { $0.postedAt <= Fixture.now })
    }
}

@Suite("Review loop")
struct ReviewTests {
    @Test("Only flagged items come to review, each with ranked suggestions")
    func queue() {
        let items = Fixture.ledger().reviewItems
        // Seven unsure merchants plus the demo's four Meadow withdrawals.
        #expect(items.count == 11)
        for item in items {
            #expect(item.transaction.categorization?.needsReview == true)
            #expect(item.suggestions == item.suggestions.sorted { $0.confidence > $1.confidence })
        }
    }

    @Test("A correction clears the item and relabels same-descriptor rows")
    func correction() async throws {
        let api = Fixture.api()
        let item = try #require(try await api.reviewQueue().first { $0.transaction.merchant == "Casa Taco" })
        _ = try await api.confirmCategory(transactionID: item.id, categoryID: "dining")
        let remaining = try await api.reviewQueue()
        #expect(remaining.count == 10)
        #expect(!remaining.contains { $0.id == item.id })
        let updated = try await api.transactions(TransactionFilter(search: "Casa Taco"))
        #expect(updated.allSatisfy { $0.categorization == Categorization(categoryID: "dining", confidence: 1, tier: .user, needsReview: false) })
    }

    @Test("Unknown IDs and categories are rejected")
    func rejects() async {
        let api = Fixture.api()
        await #expect(throws: BudgetAPIError.notFound) { try await api.confirmCategory(transactionID: "nope", categoryID: "dining") }
    }

    @Test("Descriptor normalization strips processors and store numbers")
    func normalize() {
        #expect(DemoLedger.normalizedDescriptor("SQ *CASA TACO 0423") == "CASA TACO")
        #expect(DemoLedger.normalizedDescriptor("TRADER JOE S #236") == "TRADER JOE S")
    }
}

@Suite("Ask routes to ledger tools")
struct AskTests {
    @Test("The success-criteria question returns figures equal to the ledger's own sums")
    func diningQuarters() async throws {
        let reply = try await Fixture.api().ask("What did we spend on dining in Q3 vs Q2?", conversationID: nil)
        let ledger = Fixture.ledger()
        let q3 = ledger.quarter(3, year: 2026), q2 = ledger.quarter(2, year: 2026)
        let expectedQ3 = ledger.spent(from: q3.start, to: q3.end, categoryID: "dining")
        let expectedQ2 = ledger.spent(from: q2.start, to: q2.end, categoryID: "dining")
        #expect(reply.figures.first { $0.id == "q3" }?.value == expectedQ3)
        #expect(reply.figures.first { $0.id == "q2" }?.value == expectedQ2)
        #expect(reply.toolCalls.map(\.name) == ["sumByCategory"])
        #expect(reply.text.contains(expectedQ3.formatted()))
    }

    @Test("Goal questions go through projectBalance with the parsed amount")
    func goal() async throws {
        let reply = try await Fixture.api().ask("Can I set aside $5,000 by March?", conversationID: nil)
        #expect(reply.toolCalls.first?.name == "projectBalance")
        #expect(reply.figures.first { $0.id == "goal" }?.value == Money(5000))
    }

    @Test("Amount parsing", arguments: [("$5,000", Money(5000)), ("2.5k", Money(2500)), ("1200.50", Money(1200.5))])
    func amounts(input: String, expected: Money) {
        #expect(DemoAskEngine.parseAmount(input) == expected)
    }
}

@Suite("Projection")
struct ProjectionTests {
    @Test("Projection starts at cash after cards, charts the same, and the band widens")
    func shape() throws {
        let ledger = Fixture.ledger()
        let p = ledger.projection(horizonMonths: 6, goal: nil)
        #expect(p.projected.count == 7)
        let owed = try #require(p.cardsOwed)
        #expect(owed.minorUnits > 0)
        #expect(p.projected.first?.expected == ledger.cash(through: Fixture.now) - owed)
        #expect(p.history.last?.balance == p.projected.first?.expected)
        let widths = p.projected.map { $0.high.minorUnits - $0.low.minorUnits }
        #expect(widths == widths.sorted())
    }

    @Test("The pace is income less spending as the budget counts it, not what cash did: a card payoff isn't spending, a yearly charge is a twelfth")
    func paceIsSpending() {
        var ledger = Fixture.ledger()
        let before = ledger.projection(horizonMonths: 6, goal: nil)
        let nets = ledger.spendingNets(count: 3)
        #expect(before.monthlyNet == Money(minorUnits: Int64((Double(nets.map(\.minorUnits).reduce(0, +)) / 3).rounded())))

        // Paying $5,000 of card bill from checking last month: cash drops, cash after cards and the pace don't.
        let lastMonth = Fixture.calendar.date(byAdding: .month, value: -1, to: ledger.startOfMonth)!.addingTimeInterval(86_400 * 10)
        let checking = ledger.accounts.first { $0.kind == .checking }!.id, card = ledger.accounts.first { $0.kind == .credit }!.id
        let cashBefore = ledger.cash(through: Fixture.now), afterCardsBefore = ledger.cashAfterCards(through: Fixture.now)
        let transfer = Categorization(categoryID: BudgetCategory.transferID, confidence: 1, tier: .rule, needsReview: false)
        ledger.transactions.append(LedgerTransaction(id: "pay-out", accountID: checking, postedAt: lastMonth, merchant: "Card payment",
                                                     rawDescription: "PAYMENT TO CARD", amount: Money(-5_000), categorization: transfer,
                                                     isPending: false, source: .fileImport, transferPeerID: "pay-in"))
        ledger.transactions.append(LedgerTransaction(id: "pay-in", accountID: card, postedAt: lastMonth, merchant: "Payment, thank you",
                                                     rawDescription: "PAYMENT RECEIVED", amount: Money(5_000), categorization: transfer,
                                                     isPending: false, source: .fileImport, transferPeerID: "pay-out"))
        #expect(ledger.cash(through: Fixture.now) == cashBefore - Money(5_000))
        #expect(ledger.cashAfterCards(through: Fixture.now) == afterCardsBefore)
        let after = ledger.projection(horizonMonths: 6, goal: nil)
        #expect(after.monthlyNet == before.monthlyNet)
        #expect(after.endBalance == before.endBalance)
        #expect(ledger.averageCashChange != after.monthlyNet) // what cash did still shows on the Cash flow card
    }

    @Test("Goal check is consistent")
    func goalCheck() throws {
        let ledger = Fixture.ledger()
        let target = Fixture.calendar.date(byAdding: .month, value: 6, to: Fixture.now)!
        let check = try #require(ledger.projection(horizonMonths: 12, goal: GoalQuery(amount: Money(1_000_000), targetDate: target)).goal)
        #expect(!check.isOnTrack)
        #expect(check.shortfall == Money(1_000_000) - check.projectedSavings)
    }
}

@Suite("Wire format")
struct WireTests {
    @Test("Overview round-trips through the API's JSON coding")
    func roundTrip() throws {
        let overview = Fixture.ledger().overview()
        let data = try RemoteBudgetAPI.encoder.encode(overview)
        let decoded = try RemoteBudgetAPI.decoder.decode(Overview.self, from: data)
        #expect(decoded.cashOnHand == overview.cashOnHand)
        #expect(decoded.recent.map(\.id) == overview.recent.map(\.id))
    }

    @Test("Money encodes as integer minor units")
    func moneyShape() throws {
        let json = String(decoding: try JSONEncoder().encode(Money(12.34)), as: UTF8.self)
        #expect(json.contains("\"minor\":1234"))
    }
}

@Suite("Offline cache")
struct CacheTests {
    struct Down: BudgetAPI {
        func overview() async throws -> Overview { throw BudgetAPIError.unreachable }
        func budget(month: String?) async throws -> BudgetMonth { throw BudgetAPIError.unreachable }
        func categoryHistory(id: String, months: Int) async throws -> CategoryHistory { throw BudgetAPIError.unreachable }
        func categories() async throws -> [BudgetCategory] { throw BudgetAPIError.unreachable }
        func rules() async throws -> [RuleSummary] { throw BudgetAPIError.unreachable }
        func rememberedMerchants() async throws -> [RememberedMerchant] { throw BudgetAPIError.unreachable }
        func spending(_ range: SpendingRange) async throws -> SpendingSummary { throw BudgetAPIError.unreachable }
        func transactions(_ filter: TransactionFilter) async throws -> [LedgerTransaction] { throw BudgetAPIError.unreachable }
        func transaction(id: String) async throws -> LedgerTransaction { throw BudgetAPIError.unreachable }
        func transactionSummary(_ filter: TransactionFilter) async throws -> TransactionSummary { throw BudgetAPIError.unreachable }
        func reviewQueue() async throws -> [ReviewItem] { throw BudgetAPIError.unreachable }
        func confirmCategory(transactionID: String, categoryID: String) async throws -> ActionResult { throw BudgetAPIError.unreachable }
        func ask(_ question: String, conversationID: String?) async throws -> AskReply { throw BudgetAPIError.unreachable }
        func projection(horizonMonths: Int, goal: GoalQuery?) async throws -> Projection { throw BudgetAPIError.unreachable }
        func serverStatus() async throws -> ServerStatus { throw BudgetAPIError.unreachable }
        func syncNow() async throws -> [LinkSyncResult] { throw BudgetAPIError.unreachable }
        func perform(_ action: AppAction) async throws -> ActionResult { throw BudgetAPIError.unreachable }
        func preview(_ action: AppAction) async throws -> ActionPreview { throw BudgetAPIError.unreachable }
        func assistantConfig() async throws -> AssistantConfig { throw BudgetAPIError.unreachable }
        func savingsPlan() async throws -> SavingsPlan { throw BudgetAPIError.unreachable }
        func checkup() async throws -> Checkup { throw BudgetAPIError.unreachable }
        func subscriptions() async throws -> SubscriptionSummary { throw BudgetAPIError.unreachable }
    }

    /// Fails every request the way the phone's network would: by host.
    final class Failing: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let code: URLError.Code = switch request.url?.host() {
            case "slow.test": .timedOut
            case "offline.test": .notConnectedToInternet
            default: .cannotConnectToHost
            }
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
        override func stopLoading() {}
    }

    @Test("A slow server is a timeout, no connection is offline, a dead host is unreachable — and the saved copy stands in for each")
    func noAnswerKinds() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Failing.self]
        let session = URLSession(configuration: config)
        func api(_ host: String) -> RemoteBudgetAPI { RemoteBudgetAPI(baseURL: URL(string: "https://\(host)")!, session: session) }
        await #expect(throws: BudgetAPIError.timedOut) { try await api("slow.test").ask("How's my month?", conversationID: nil) }
        await #expect(throws: BudgetAPIError.offline) { try await api("offline.test").overview() }
        await #expect(throws: BudgetAPIError.unreachable) { try await api("dead.test").overview() }
        #expect(BudgetAPIError.timedOut.errorDescription?.contains("VPN") == false)

        let dir = FileManager.default.temporaryDirectory.appending(path: "budget-cache-\(UUID().uuidString)")
        let cache = ResponseCache(directory: dir)
        let live = try await CachingBudgetAPI(upstream: Fixture.api(), cache: cache).overview()
        let slow = try await CachingBudgetAPI(upstream: api("slow.test"), cache: cache).overview()
        #expect(slow.cashOnHand == live.cashOnHand)
        await #expect(throws: BudgetAPIError.offline) { try await CachingBudgetAPI(upstream: api("offline.test"), cache: cache).reviewQueue() }
    }

    @Test("The saved copy is there to show at once, under the same names reads save it by; each server keeps its own")
    func savedCopies() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "budget-cache-\(UUID().uuidString)")
        let api = CachingBudgetAPI(upstream: Fixture.api(), cache: ResponseCache(directory: dir))
        #expect(await api.saved(.overview, as: Overview.self) == nil)
        let live = try await api.overview()
        let month = try await api.budget(month: "2026-09")
        #expect(await api.saved(.overview, as: Overview.self)?.cashOnHand == live.cashOnHand)
        #expect(await api.saved(.budget(month: "2026-09"), as: BudgetMonth.self) == month)
        #expect(await api.saved(.budget(month: "2026-08"), as: BudgetMonth.self) == nil)
        // The names copies were saved under before, so an existing copy still reads.
        #expect(SavedRead.budget(month: nil).key == "budget-current" && SavedRead.projection(horizonMonths: 6).key == "projection-6")
        #expect(SavedRead.categoryHistory(id: "dining", months: 12).key == "category-history-dining-12")

        let home = ResponseCache.appDefault(for: URL(string: "https://abc1230.example.olares.com")!)
        let other = ResponseCache.appDefault(for: URL(string: "http://127.0.0.1:8090")!)
        #expect(home.directory != other.directory)
        #expect(other.directory.lastPathComponent == "127.0.0.1-8090")
        #expect(home.directory.deletingLastPathComponent().lastPathComponent == "BudgetResponses") // under the one Disconnect clears
    }

    @Test("Serves the last good response when the server is unreachable")
    func fallback() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "budget-cache-\(UUID().uuidString)")
        let cache = ResponseCache(directory: dir)
        let live = try await CachingBudgetAPI(upstream: Fixture.api(), cache: cache).overview()
        let offline = try await CachingBudgetAPI(upstream: Down(), cache: cache).overview()
        #expect(offline.cashOnHand == live.cashOnHand)
        await #expect(throws: BudgetAPIError.unreachable) { try await CachingBudgetAPI(upstream: Down(), cache: cache).reviewQueue() }
    }
}
