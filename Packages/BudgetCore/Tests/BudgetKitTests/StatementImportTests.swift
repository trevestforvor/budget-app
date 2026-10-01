import Foundation
import Testing
@testable import BudgetKit

/// Statement exports from the banks (column layouts copied from real Chase and Amex downloads; the
/// rows are made up) and how they land next to what Plaid already synced.
@Suite("Statement imports")
struct StatementImportTests {
    static let chaseCard = """
    Transaction Date,Post Date,Description,Category,Type,Amount,Memo
    09/22/2026,09/23/2026,AMZN Mktp US*2K4LM9,Shopping,Sale,-64.00,
    09/21/2026,09/22/2026,BLUE BOTTLE COFFEE,Food & Drink,Sale,-6.50,
    09/21/2026,09/22/2026,BLUE BOTTLE COFFEE,Food & Drink,Sale,-6.50,
    09/20/2026,09/20/2026,AUTOMATIC PAYMENT - THANK,,Payment,1250.00,
    09/19/2026,09/19/2026,ANNUAL MEMBERSHIP FEE,,Fee,-95.00,
    """

    static let amex = """
    Date,Description,Amount,Extended Details,Appears On Your Statement As,Address,City/State,Zip Code,Country,Reference,Category
    09/21/2026,PLAN FEE - EXAMPLE LEND* NO,12.34,PLAN FEE - EXAMPLE LEND* NO,PLAN FEE - EXAMPLE LEND* NO,,,,,'320000000000000003',Fees & Adjustments-Fees & Adjustments
    09/18/2026,MOBILE PAYMENT - THANK YOU,-2500.00,MOBILE PAYMENT,MOBILE PAYMENT - THANK YOU,,,,,'320262610000000001',
    09/12/2026,SWEETGREEN NOMAD,"11.11","SWEETGREEN
    100 EXAMPLE ST",SWEETGREEN NOMAD,100 EXAMPLE ST,NEW YORK NY,10001,UNITED STATES,'320262550000000002',Restaurant-Restaurant
    """

    @Test("Chase card export: posting date, negative charges, payments and fees named by their Type")
    func chaseCardExport() throws {
        let rows = try FileImport.parse(Self.chaseCard, options: .init(accountKind: .credit, institution: "Chase")).accounts[0].transactions
        #expect(rows.map(\.amount) == [Money(-64), Money(-6.50), Money(-6.50), Money(1250), Money(-95)])
        #expect(rows[0].posted == FileImport.day(2026, 9, 23))
        #expect(rows[3].providerCategory == "Payment")
        #expect(rows[4].providerCategory == "Fees & Adjustments")
        #expect(Set(rows.map(\.externalID)).count == 5) // the two identical coffees stay two rows
    }

    @Test("Amex export: charges flipped even on a statement that's mostly a payment, and its reference is the row id")
    func amexExport() throws {
        let rows = try FileImport.parse(Self.amex, options: .init(accountKind: .credit, institution: "American Express")).accounts[0].transactions
        #expect(rows.map(\.amount) == [Money(-12.34), Money(2500), Money(-11.11)])
        #expect(rows.map(\.externalID) == ["ref-320000000000000003", "ref-320262610000000001", "ref-320262550000000002"])
        #expect(rows[2].description == "SWEETGREEN NOMAD")
    }

    @Test("Chase and Amex categories become hints the pipeline understands")
    func bankCategories() {
        #expect(ProviderCategories.map("Food & Drink") == "dining")
        #expect(ProviderCategories.map("Bills & Utilities") == "utilities")
        #expect(ProviderCategories.map("Payment") == "transfer")
        #expect(ProviderCategories.map("Restaurant-Bar & Café") == "dining")
        #expect(ProviderCategories.map("Merchandise & Supplies-Groceries") == "groceries")
        #expect(ProviderCategories.map("Merchandise & Supplies-Computer Supplies") == "shopping")
        #expect(ProviderCategories.map("Fees & Adjustments-Fees & Adjustments") == "fees")
        #expect(ProviderCategories.map("Business Services-Other Services") == nil) // ambiguous: the model decides
        #expect(ProviderCategories.map("Personal") == nil)
    }

    /// A card with three Plaid rows: Amazon (Plaid's wording), one of the two coffees, the payment.
    static func plaidCard() -> SourceSnapshot {
        SourceSnapshot(source: .plaid, accounts: [
            SourceAccount(externalID: "chase-0909", institution: "Chase", institutionDomain: nil, name: "Freedom Unlimited", kind: .credit,
                          balance: Money(-2377.90), availableBalance: nil, balanceDate: EngineFixture.now, transactions: [
                              SourceTransaction(externalID: "p-amzn", posted: FileImport.day(2026, 9, 23)!, amount: Money(-64), description: "Amazon", payee: "Amazon"),
                              SourceTransaction(externalID: "p-coffee", posted: FileImport.day(2026, 9, 22)!, amount: Money(-6.50), description: "Blue Bottle Coffee", payee: "Blue Bottle"),
                              SourceTransaction(externalID: "p-pay", posted: FileImport.day(2026, 9, 20)!, amount: Money(1250), description: "Payment Thank You-Mobile"),
                          ], holdings: [], mask: "0909"),
        ], warnings: [])
    }

    @Test("Rows Plaid already has are skipped one for one — even worded differently — and the rest are added")
    func dedupeAgainstPlaid() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions([:])))
        _ = try await api.ingest(Self.plaidCard(), batchID: "sync-1")
        let account = try #require(try await api.overview().accounts.first)
        #expect(account.mask == "0909")
        let file = try FileImport.parse(Self.chaseCard, options: .init(accountKind: .credit, institution: "Chase"))
        let report = try await api.ingest(file, batchID: "file-1", into: account.id)
        // Amazon matches despite the wording, one coffee matches the one Plaid row, the payment matches.
        #expect(report.duplicatesSkipped == 3)
        #expect(report.rowsAdded == 2) // the second coffee and the fee
        #expect(report.duplicateSamples?.first?.matchedSource == .plaid)
        #expect(report.addedFrom == FileImport.day(2026, 9, 19) && report.addedThrough == FileImport.day(2026, 9, 22))
        #expect(try await api.overview().accounts.first?.balance == Money(-2377.90)) // Plaid's balance stays the anchor
    }

    @Test("A preview reports what an import would do and changes nothing")
    func preview() async throws {
        let persistence = RecordingPersistence()
        let api = EngineFixture.api(persistence: persistence, decisions: DecisionRouting(local: StubDecisions([:])))
        _ = try await api.ingest(Self.plaidCard(), batchID: "sync-1")
        let saves = await persistence.saves.count
        let account = try #require(try await api.overview().accounts.first)
        let file = try FileImport.parse(Self.chaseCard, options: .init(accountKind: .credit))
        let preview = try await api.previewIngest(file, into: account.id)
        #expect(preview.rowsAdded == 2 && preview.duplicatesSkipped == 3)
        #expect(await persistence.saves.count == saves)
        #expect(try await api.transactions(TransactionFilter()).count == 3)
        let real = try await api.ingest(file, batchID: "file-1", into: account.id)
        #expect(real.rowsAdded == preview.rowsAdded && real.duplicatesSkipped == preview.duplicatesSkipped)
    }

    @Test("A source's own identical rows are both kept; only other sources' rows count as duplicates")
    func sameSourceRepeats() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions([:])))
        var snapshot = Self.plaidCard()
        snapshot.accounts[0].transactions.append(SourceTransaction(externalID: "p-coffee-2", posted: FileImport.day(2026, 9, 22)!, amount: Money(-6.50),
                                                                   description: "Blue Bottle Coffee", payee: "Blue Bottle"))
        let report = try await api.ingest(snapshot, batchID: "sync-1")
        #expect(report.rowsAdded == 4 && report.duplicatesSkipped == 0)
    }

    @Test("The same file into two cards lands in both; overlapping exports of one card don't double up")
    func accountScopedIDs() async throws {
        var state = LedgerState.empty
        state.accounts = [Account(id: "a", name: "Freedom", institution: "Chase", kind: .credit, balance: .zero, source: .plaid),
                          Account(id: "b", name: "Sapphire", institution: "Chase", kind: .credit, balance: .zero, source: .plaid)]
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        let file = try FileImport.parse(Self.chaseCard, options: .init(accountKind: .credit))
        #expect(try await api.ingest(file, batchID: "f1", into: "a").rowsAdded == 5)
        #expect(try await api.ingest(file, batchID: "f2", into: "b").rowsAdded == 5)
        // A second export whose range overlaps the first: the shared rows are the same rows.
        let overlap = try FileImport.parse("""
        Transaction Date,Post Date,Description,Category,Type,Amount,Memo
        09/22/2026,09/23/2026,AMZN Mktp US*2K4LM9,Shopping,Sale,-64.00,
        09/24/2026,09/25/2026,SHAKE SHACK,Food & Drink,Sale,-14.20,
        """, options: .init(accountKind: .credit))
        let report = try await api.ingest(overlap, batchID: "f3", into: "a")
        #expect(report.rowsAdded == 1 && report.duplicatesSkipped == 0)
    }

    @Test("The same rows into two new named accounts land in both")
    func namedAccountsDontCollide() async throws {
        let api = LedgerBudgetAPI(state: .empty, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        for name in ["Freedom", "Sapphire"] {
            let file = try FileImport.parse(Self.chaseCard, options: .init(accountKind: .credit, institution: "Chase", accountName: name))
            #expect(try await api.ingest(file, batchID: name, into: nil).rowsAdded == 5)
        }
        #expect(try await api.transactions(TransactionFilter()).count == 10)
    }

    @Test("Rows imported before ids were scoped to an account are recognized on re-import")
    func legacyIDs() async throws {
        let file = try FileImport.parse(Self.chaseCard, options: .init(accountKind: .credit))
        let first = file.accounts[0].transactions[0]
        var state = LedgerState.empty
        state.accounts = [Account(id: "a", name: "Freedom", institution: "Chase", kind: .credit, balance: .zero, source: .plaid)]
        state.transactions = [LedgerTransaction(id: "fileImport:\(first.externalID)", accountID: "a", postedAt: first.posted, merchant: "Amazon",
                                                rawDescription: first.description, amount: first.amount, categorization: nil, isPending: false, source: .fileImport)]
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        let report = try await api.ingest(file, batchID: "f1", into: "a")
        #expect(report.rowsAdded == 4)
    }

    /// An Amex card whose statements were imported before Plaid's history arrived (the order it happened in).
    static func importedFirst() async throws -> LedgerBudgetAPI {
        var state = LedgerState.empty
        state.accounts = [Account(id: "plaid:gold", name: "Gold Card", institution: "American Express", kind: .credit, balance: .zero, source: .plaid, mask: "22222")]
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        let csv = """
        Date,Description,Amount,Extended Details,Appears On Your Statement As,Address,City/State,Zip Code,Country,Reference,Category
        06/06/2026,AplPay AMC 0001 EXAMPLE TOWN,23.45,,,,,,,'1',Entertainment-Theatrical Events
        07/01/2026,Platinum Lululemon Credit,-75.00,,,,,,,'2',
        07/02/2026,BLUE BOTTLE COFFEE,6.50,,,,,,,'3',Restaurant-Bar & Café
        """
        _ = try await api.ingest(try FileImport.parse(csv, options: .init(accountKind: .credit)), batchID: "file-1", into: "plaid:gold")
        return api
    }

    static let plaidLater = SourceSnapshot(source: .plaid, accounts: [
        SourceAccount(externalID: "gold", institution: "American Express", institutionDomain: nil, name: "Gold Card", kind: .credit,
                      balance: .zero, availableBalance: nil, balanceDate: EngineFixture.now, transactions: [
                          // Plaid's short name differs, its descriptor doesn't; two days later.
                          SourceTransaction(externalID: "amc", posted: FileImport.day(2026, 6, 8)!, amount: Money(-23.45), description: "AplPay AMC 0001 EXAMPLE TOWN", payee: "AMC Theatres"),
                          // A statement credit Plaid dates four days after the statement.
                          SourceTransaction(externalID: "lulu", posted: FileImport.day(2026, 7, 5)!, amount: Money(75), description: "Platinum Lululemon Credit"),
                          // Same amount two days later, different place: a different purchase.
                          SourceTransaction(externalID: "coffee", posted: FileImport.day(2026, 7, 4)!, amount: Money(-6.50), description: "BLUEBIRD COFFEE", payee: "Bluebird Coffee"),
                      ], holdings: [], mask: "22222"),
    ], warnings: [])

    @Test("A later sync recognizes imported rows by any wording, and a credit posted four days late")
    func laterSyncMatchesImports() async throws {
        let api = try await Self.importedFirst()
        let report = try await api.ingest(Self.plaidLater, batchID: "sync-1")
        #expect(report.duplicatesSkipped == 2)
        #expect(report.rowsAdded == 1) // Bluebird is its own purchase
    }

    @Test("Duplicates already in the ledger are listed, then only the imported copies removed")
    func duplicateSweep() async throws {
        // What an older, stricter matcher left behind: both copies of the AMC charge and the credit.
        let api = try await Self.importedFirst()
        var state = await api.state
        state.transactions += Self.plaidLater.accounts[0].transactions.map {
            LedgerTransaction(id: "plaid:\($0.externalID)", accountID: "plaid:gold", postedAt: $0.posted, merchant: $0.payee ?? $0.description,
                              rawDescription: $0.description, amount: $0.amount, categorization: nil, isPending: false, source: .plaid)
        }
        if let i = state.transactions.firstIndex(where: { $0.rawDescription.hasPrefix("AplPay AMC") && $0.source == .fileImport }) {
            state.transactions[i].categorization = Categorization(categoryID: "entertainment", confidence: 1, tier: .user, needsReview: false)
        }
        await api.replaceStateWithoutPersisting(state)
        // A second DoorDash order the day before Plaid's history starts: same amount, a day from Plaid's
        // McDonald's row, but that row is the next day's order. The sweep leaves it alone.
        state = await api.state
        state.transactions.append(LedgerTransaction(id: "fileImport:plaid:gold:dd", accountID: "plaid:gold", postedAt: FileImport.day(2026, 7, 3)!,
                                                    merchant: "Dd *Doordash Mcdonalds", rawDescription: "DD *DOORDASH MCDONALDS", amount: Money(-6.50),
                                                    categorization: nil, isPending: false, source: .fileImport))
        await api.replaceStateWithoutPersisting(state)
        let preview = try await api.importDuplicates(apply: false)
        #expect(preview.pairs.count == 2 && !preview.applied)
        #expect(try await api.transactions(TransactionFilter()).count == 7)
        let applied = try await api.importDuplicates(apply: true)
        #expect(applied.removed == 2)
        let rows = try await api.transactions(TransactionFilter())
        #expect(rows.count == 5)
        #expect(rows.filter { $0.source == .plaid }.count == 3) // the synced copies stay
        #expect(rows.first { $0.rawDescription.hasPrefix("AplPay AMC") }?.categorization?.categoryID == "entertainment") // the person's category moves over
        #expect(try await api.importDuplicates(apply: false).pairs.isEmpty)
    }

    @Test("After a sync, re-importing the same statement adds nothing, and syncing again adds nothing")
    func noDuplicatesComeBack() async throws {
        let api = try await Self.importedFirst()
        _ = try await api.ingest(Self.plaidLater, batchID: "sync-1")
        let count = try await api.transactions(TransactionFilter()).count
        let csv = """
        Date,Description,Amount,Extended Details,Appears On Your Statement As,Address,City/State,Zip Code,Country,Reference,Category
        06/06/2026,AplPay AMC 0001 EXAMPLE TOWN,23.45,,,,,,,'1',Entertainment-Theatrical Events
        07/01/2026,Platinum Lululemon Credit,-75.00,,,,,,,'2',
        """
        #expect(try await api.ingest(try FileImport.parse(csv, options: .init(accountKind: .credit)), batchID: "file-2", into: "plaid:gold").rowsAdded == 0)
        #expect(try await api.ingest(Self.plaidLater, batchID: "sync-2").rowsAdded == 0)
        #expect(try await api.transactions(TransactionFilter()).count == count)
        #expect(try await api.importDuplicates(apply: false).pairs.isEmpty)
    }

    @Test("A Quicken (QFX) export can go into the account Plaid already made, not a second one")
    func qfxIntoExistingAccount() async throws {
        var state = LedgerState.empty
        state.accounts = [Account(id: "plaid:cash", name: "Individual Cash Account", institution: "Meadow", kind: .savings, balance: Money(12345.67), source: .plaid, mask: "1111")]
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        let qfx = """
        OFXHEADER:100
        <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>USD<BANKACCTFROM><ACCTID>1X0001111</BANKACCTFROM>
        <BANKTRANLIST><STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260831<TRNAMT>12.30<FITID>int-0831<NAME>Interest
        <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260815<TRNAMT>-1250.00<FITID>xfer-0815<NAME>Transfer to Harbor
        </BANKTRANLIST><LEDGERBAL><BALAMT>12345.67<DTASOF>20260831</LEDGERBAL></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
        """
        let report = try await api.ingest(try FileImport.parse(qfx), batchID: "qfx", into: "plaid:cash")
        #expect(report.rowsAdded == 2 && report.accountsAdded == 0)
        #expect(try await api.overview().accounts.count == 1)
        #expect(try await api.ingest(try FileImport.parse(qfx), batchID: "qfx-again", into: "plaid:cash").rowsAdded == 0)
    }
}
