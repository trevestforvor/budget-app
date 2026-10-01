import Foundation
import Testing
@testable import BudgetKit

/// Records saves; can be told to fail.
actor RecordingPersistence: LedgerPersistence {
    private(set) var saves: [(old: LedgerState, new: LedgerState)] = []
    var failNext = false
    func save(from old: LedgerState, to new: LedgerState) async throws {
        if failNext { failNext = false; throw BudgetAPIError.server(status: 500, message: "disk full") }
        saves.append((old, new))
    }
    func setFailNext() { failNext = true }
}

/// Answers from a fixed table and counts calls.
actor StubDecisions: DecisionModel {
    nonisolated let label = "stub"
    nonisolated var runsLocally: Bool { true }
    let table: [String: (String, Double)]
    private(set) var calls = 0
    init(_ table: [String: (String, Double)]) { self.table = table }
    func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse] {
        calls += requests.count
        return requests.map { r in
            let hit = table.first { r.state.uppercased().contains($0.key) }?.value ?? ("shopping", 0.3)
            return DecisionResponse(answers: [CategoryDecisions.questionID: DecisionAnswer(value: hit.0, confidence: hit.1, distribution: [hit.0: hit.1])], model: label)
        }
    }
}

enum EngineFixture {
    static let now = Fixture.now
    static func day(_ d: Int) -> Date { Fixture.calendar.date(byAdding: .day, value: -d, to: now)! }

    static func plaidSnapshot(pending: Bool = false) -> SourceSnapshot {
        SourceSnapshot(source: .plaid, accounts: [
            SourceAccount(externalID: "summit-1", institution: "Summit Card", institutionDomain: nil, name: "Gold Card", kind: .credit,
                          balance: Money(-412.50), availableBalance: nil, balanceDate: now, transactions: [
                              SourceTransaction(externalID: "p1", posted: day(1), amount: Money(-23.50), description: "SQ *CASA TACO 0423", payee: "Casa Taco", isPending: pending, providerCategory: "FOOD_AND_DRINK_RESTAURANT"),
                              SourceTransaction(externalID: "p2", posted: day(2), amount: Money(-12.00), description: "SQ *CASA TACO 0423", payee: "Casa Taco"),
                              SourceTransaction(externalID: "p3", posted: day(3), amount: Money(-64.00), description: "PAYPAL *XJ29QK", providerCategory: "GENERAL_MERCHANDISE"),
                              SourceTransaction(externalID: "p4", posted: day(4), amount: Money(-15.49), description: "NETFLIX.COM", payee: "Netflix"),
                              SourceTransaction(externalID: "p5", posted: day(5), amount: Money(-40.00), description: "VENMO *J. PARK"),
                          ], holdings: []),
        ], warnings: [])
    }

    static func api(persistence: (any LedgerPersistence)? = nil, decisions: DecisionRouting = DecisionRouting()) -> LedgerBudgetAPI {
        var state = LedgerState.empty
        state.decisionPolicy = DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category])
        state.rules = [BudgetRule(id: "rule-1", match: RuleMatch(merchantContains: "venmo"), categoryID: "transfer")]
        return LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: decisions,
                               persistence: persistence, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
    }
}

@Suite("Ledger engine")
struct EngineTests {
    @Test("State round-trips and reproduces the same numbers")
    func roundTrip() throws {
        let demo = Fixture.ledger()
        let reloaded = Ledger(state: demo.state, now: Fixture.now, calendar: Fixture.calendar)
        #expect(reloaded.overview().cashOnHand == demo.overview().cashOnHand)
        #expect(reloaded.spendingSummary(.thisMonth) == demo.spendingSummary(.thisMonth))
        let data = try JSONEncoder().encode(demo.state)
        #expect(try JSONDecoder().decode(LedgerState.self, from: data) == demo.state)
    }

    @Test("An empty ledger answers every read without crashing")
    func empty() async throws {
        let api = EngineFixture.api()
        let overview = try await api.overview()
        #expect(overview.cashOnHand == .zero)
        _ = try await api.spending(.thisMonth)
        _ = try await api.projection(horizonMonths: 6, goal: GoalQuery(amount: Money(1000), targetDate: EngineFixture.day(-90)))
        _ = try await api.savingsPlan()
        #expect(try await api.reviewQueue().isEmpty)
    }
}

@Suite("Ingest and categorization")
struct IngestTests {
    @Test("Ingest anchors the provider balance, tags the batch, and runs every tier once per descriptor")
    func ingest() async throws {
        let persistence = RecordingPersistence()
        let model = StubDecisions(["CASA TACO": ("dining", 0.95), "NETFLIX": ("subscriptions", 0.97), "PAYPAL": ("shopping", 0.45)])
        let api = EngineFixture.api(persistence: persistence, decisions: DecisionRouting(local: model))
        let report = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        #expect(report.accountsAdded == 1)
        #expect(report.rowsAdded == 5)
        #expect(report.byRule == 1)       // Venmo rule
        #expect(report.byModel == 3)      // two Casa Taco rows + Netflix
        #expect(report.needsReview == 1)  // PayPal at 45%
        #expect(report.modelCalls == 3)   // Casa Taco decided once for both rows
        #expect(await model.calls == 3)

        let overview = try await api.overview()
        #expect(overview.accounts.first?.balance == Money(-412.50))
        let rows = try await api.transactions(TransactionFilter())
        #expect(rows.allSatisfy { $0.batchID == "sync-1" })
        #expect(rows.first { $0.merchant == "Venmo" }?.categorization?.tier == .rule)
        let review = try #require(try await api.reviewQueue().first)
        #expect(review.transaction.rawDescription == "PAYPAL *XJ29QK")
        #expect(review.suggestions.map(\.categoryID) == ["shopping"]) // model's pick; the Plaid hint agrees
        #expect(await persistence.saves.count == 1)
    }

    @Test("Re-syncing is idempotent; pending rows post in place; merchant memory takes over")
    func resync() async throws {
        let model = StubDecisions(["CASA TACO": ("dining", 0.95), "NETFLIX": ("subscriptions", 0.97)])
        let api = EngineFixture.api(decisions: DecisionRouting(local: model))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(pending: true), batchID: "sync-1")
        let again = try await api.ingest(EngineFixture.plaidSnapshot(pending: false), batchID: "sync-2")
        #expect(again.rowsAdded == 0)
        #expect(again.rowsUpdated == 1)
        #expect(try await api.transactions(TransactionFilter(search: "Mission")).allSatisfy { !$0.isPending })

        // A new row from a known merchant is filed by memory — no model call.
        let before = await model.calls
        var next = EngineFixture.plaidSnapshot()
        next.accounts[0].transactions = [SourceTransaction(externalID: "p9", posted: EngineFixture.day(0), amount: Money(-18), description: "SQ *CASA TACO 0501", payee: "Casa Taco")]
        let report = try await api.ingest(next, batchID: "sync-3")
        #expect(report.byMemory == 1)
        #expect(await model.calls == before)
    }

    @Test("A file import of rows already synced is deduplicated fuzzily; rollback removes only its batch")
    func fileDedupeAndRollback() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions([:])))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        let accountID = try #require(try await api.overview().accounts.first?.id)
        let csv = """
        Date,Description,Amount
        09/24/2026,CASA TACO,23.50
        09/10/2026,UNITED AIRLINES,486.20
        """
        let snapshot = try FileImport.parse(csv, options: .init(accountKind: .credit, institution: "Summit Card"))
        let report = try await api.ingest(snapshot, batchID: "file-1", into: accountID)
        #expect(report.duplicatesSkipped == 1)   // Casa Taco already came from Plaid
        #expect(report.rowsAdded == 1)
        #expect(try await api.overview().accounts.first?.balance == Money(-412.50)) // anchored balance unchanged
        #expect(try await api.rollback(batchID: "file-1") == 1)
        #expect(try await api.transactions(TransactionFilter()).count == 5)
    }

    @Test("A failed save leaves the in-memory ledger unchanged")
    func persistenceFailure() async throws {
        let persistence = RecordingPersistence()
        let api = EngineFixture.api(persistence: persistence, decisions: DecisionRouting(local: StubDecisions([:])))
        await persistence.setFailNext()
        await #expect(throws: BudgetAPIError.self) { try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1") }
        #expect(try await api.transactions(TransactionFilter()).isEmpty)
    }

    @Test("An unconfigured decision provider sends rows to review with a warning — never a silent demo fallback, never a failed sync")
    func unconfigured() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting())
        let report = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        #expect(report.byModel == 0 && report.modelCalls == 0)
        #expect(report.needsReview == report.rowsAdded - report.byRule - report.byMemory)
        #expect(report.warnings.contains { $0.contains("isn't set up on the server") })
    }

    @Test("Re-check moves what the model filed, never what the person confirmed")
    func recheckModelFiled() async throws {
        var state = LedgerState.empty
        state.accounts = [Account(id: "card", name: "Gold", institution: "Summit", kind: .credit, balance: Money(-100), source: .plaid)]
        state.decisionPolicy = DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category])
        func row(_ id: String, _ raw: String, _ cat: String, _ tier: CategorizationTier) -> LedgerTransaction {
            LedgerTransaction(id: id, accountID: "card", postedAt: .now, merchant: raw.capitalized, rawDescription: raw, amount: Money(-25),
                              categorization: Categorization(categoryID: cat, confidence: 0.9, tier: tier, needsReview: false), isPending: false, source: .plaid)
        }
        state.transactions = [row("1", "AMC 1234", "dining", .decisionModel), row("2", "AMC 1234", "dining", .merchantMemory),
                              row("3", "NETFLIX", "shopping", .user)]
        let model = StubDecisions(["AMC": ("entertainment", 0.96), "NETFLIX": ("subscriptions", 0.99)])
        let api = LedgerBudgetAPI(state: state, chatModel: nil, decisions: DecisionRouting(local: model), persistence: nil,
                                  deployment: DeploymentInfo(endpoint: "t", version: "t", sources: [], institutions: []))
        let preview = try await api.recheckModelFiled(apply: false)
        #expect(!preview.applied && preview.moves.map(\.to) == ["entertainment"])
        #expect(try await api.transactions(TransactionFilter()).first { $0.id == "1" }?.categorization?.categoryID == "dining") // preview changed nothing
        let result = try await api.recheckModelFiled()
        #expect(result.movedMerchants == 1 && result.movedTransactions == 2)
        let rows = try await api.transactions(TransactionFilter())
        #expect(rows.filter { $0.merchant.hasPrefix("Amc") }.allSatisfy { $0.categorization?.categoryID == "entertainment" })
        #expect(rows.first { $0.id == "3" }?.categorization?.categoryID == "shopping") // the person's choice stands
        let ids = try await api.categories().map(\.id)
        #expect(ids.contains("entertainment") && ids.contains("fees"))
    }

    @Test("A refund or statement credit reduces its category instead of counting as income")
    func refundsNet() async throws {
        var state = LedgerState.empty
        state.accounts = [Account(id: "card", name: "Plat", institution: "Summit", kind: .credit, balance: .zero, source: .plaid)]
        let now = Date()
        state.transactions = [
            LedgerTransaction(id: "a", accountID: "card", postedAt: now, merchant: "Harvest Table", rawDescription: "HARVEST TABLE", amount: Money(-80),
                              categorization: Categorization(categoryID: "dining", confidence: 1, tier: .user, needsReview: false), isPending: false, source: .plaid),
            LedgerTransaction(id: "b", accountID: "card", postedAt: now, merchant: "Tablesy", rawDescription: "TABLESY CREDIT", amount: Money(50),
                              categorization: Categorization(categoryID: "dining", confidence: 1, tier: .user, needsReview: false), isPending: false, source: .plaid),
        ]
        let ledger = Ledger(state: state, now: now.addingTimeInterval(60), calendar: .current)
        let month = ledger.interval(for: .thisMonth)
        #expect(ledger.spent(from: month.start, to: month.end, categoryID: "dining") == Money(30))
        #expect(ledger.income(from: month.start, to: month.end) == .zero)
        let request = CategoryDecisions.request(for: state.transactions[1], categories: Ledger.categoryList, accountKind: .credit)
        #expect(request.state.contains("credit card") && request.state.contains("money in"))
    }

    @Test("A policy the server can't run is refused up front")
    func refusesUnavailablePolicy() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions([:])))
        await #expect(throws: BudgetAPIError.self) {
            try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .localDecide, escalateToJev: true, rerunPending: false)))
        }
        await #expect(throws: BudgetAPIError.self) {
            try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .jev, rerunPending: false)))
        }
        #expect(try await api.serverStatus().availableDecisionProviders == [.off, .localDecide])
    }

    @Test("The bank's category reaches the model, and agreement files a merchant below the bar")
    func bankCategoryAgreement() async throws {
        // The model is unsure (0.6 < the 80% bar) but picks what Plaid's category maps to.
        let row = LedgerTransaction(id: "p:1", accountID: "a", postedAt: .now, merchant: "Touchstone Climbing", rawDescription: "TOUCHSTONE CLIMBING",
                                    amount: Money(-78.5), categorization: nil, isPending: false, source: .plaid,
                                    providerCategory: "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS")
        let request = CategoryDecisions.request(for: row, categories: Ledger.categoryList)
        #expect(request.state.contains("personal care: gyms and fitness centers"))
        let agreed = Categorizer.agreement(DecisionAnswer(value: "health", confidence: 0.6), bankCategory: row.providerCategory, known: ["health"])
        #expect(agreed == "health")
        #expect(Categorizer.agreement(DecisionAnswer(value: "shopping", confidence: 0.9), bankCategory: row.providerCategory, known: ["health", "shopping"]) == nil)
        #expect(Categorizer.agreement(DecisionAnswer(value: "health", confidence: 0.3), bankCategory: row.providerCategory, known: ["health"]) == nil)
    }
}

@Suite("File import")
struct FileImportTests {
    @Test("Harbor checking CSV: signed amounts, quoted commas")
    func chase() throws {
        let csv = """
        Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #
        DEBIT,09/18/2026,"COMCAST XFINITY, INTERNET",-79.99,ACH_DEBIT,18572.63,,
        CREDIT,09/15/2026,ACME CORP PAYROLL PPD,3850.00,ACH_CREDIT,18652.62,,
        """
        let rows = try FileImport.parse(csv).accounts[0].transactions
        #expect(rows.map(\.amount) == [Money(-79.99), Money(3850)])
        #expect(rows[0].description == "COMCAST XFINITY, INTERNET")
        #expect(rows[0].posted == FileImport.day(2026, 9, 18))
    }

    @Test("Summit CSV exports charges as positive; they're flipped for a card")
    func summit() throws {
        let csv = """
        Date,Description,Amount,Extended Details,Category
        09/24/2026,SQ *CASA TACO,23.50,,Restaurant-Restaurant
        09/20/2026,UBER *TRIP,24.18,,Transportation-Taxis
        09/21/2026,MOBILE PAYMENT - THANK YOU,-500.00,,
        """
        let snapshot = try FileImport.parse(csv, options: .init(accountKind: .credit))
        #expect(snapshot.accounts[0].transactions.map(\.amount) == [Money(-23.50), Money(-24.18), Money(500)])
        #expect(snapshot.accounts[0].transactions[0].providerCategory == "Restaurant-Restaurant")
        #expect(!snapshot.warnings.isEmpty)
    }

    @Test("Debit/credit columns, and re-importing the same file yields the same ids")
    func debitCredit() throws {
        let csv = "Date,Description,Debit,Credit\n2026-09-01,RENT,2400.00,\n2026-09-01,RENT,2400.00,\n2026-09-15,PAYROLL,,3850.00\n"
        let a = try FileImport.parse(csv).accounts[0].transactions
        let b = try FileImport.parse(csv).accounts[0].transactions
        #expect(a.map(\.amount) == [Money(-2400), Money(-2400), Money(3850)])
        #expect(a.map(\.externalID) == b.map(\.externalID))
        #expect(Set(a.map(\.externalID)).count == 3) // identical rows stay distinct
    }

    @Test("OFX 1.x SGML: transactions, FITIDs, card account and ledger balance")
    func ofx() throws {
        let ofx = """
        OFXHEADER:100
        DATA:OFXSGML
        <OFX><CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CURDEF>USD
        <CCACCTFROM><ACCTID>379700001234</CCACCTFROM>
        <BANKTRANLIST><DTSTART>20260901<DTEND>20260925
        <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260924120000[-7:PDT]<TRNAMT>-23.50<FITID>320260924001<NAME>SQ *CASA TACO
        <STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260921<TRNAMT>500.00<FITID>320260921002<NAME>PAYMENT - THANK YOU
        </BANKTRANLIST><LEDGERBAL><BALAMT>-412.50<DTASOF>20260925</LEDGERBAL>
        </CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>
        """
        let snapshot = try FileImport.parse(ofx)
        let account = try #require(snapshot.accounts.first)
        #expect(account.kind == .credit)
        #expect(account.name == "Card ••1234")
        #expect(account.balance == Money(-412.50))
        #expect(account.transactions.map(\.amount) == [Money(-23.50), Money(500)])
        #expect(account.transactions[0].externalID == "ofx-379700001234-320260924001")
    }

    @Test("Useful errors for unreadable files")
    func errors() {
        #expect(throws: FileImport.ParseError.self) { try FileImport.parse("Foo,Bar\n1,2\n") }
        #expect(throws: FileImport.ParseError.self) { try FileImport.parse("<OFX><BANKMSGSRSV1></OFX>") }
    }
}
