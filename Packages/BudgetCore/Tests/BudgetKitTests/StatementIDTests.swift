import Foundation
import Testing
@testable import BudgetKit

/// P0.6 in the parser and ingest: an OFX file's account number never reaches an id, an account or a mask beyond its
/// last four digits.
@Suite("Statement ids")
struct StatementIDTests {
    static let number = "9876543210123"

    /// A checking statement whose FITIDs embed the account number, as some banks' do.
    static let statement = """
    OFXHEADER:100
    <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>USD<BANKACCTFROM><ACCTID>\(number)</BANKACCTFROM>
    <BANKTRANLIST>
    <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260910<TRNAMT>-42.00<FITID>\(number)-0001<NAME>CORNER MARKET
    <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260912<TRNAMT>-6.50<FITID>\(number)-0002<NAME>BLUE BOTTLE
    <STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260915<TRNAMT>2100.00<FITID>\(number)-0003<NAME>PAYROLL
    </BANKTRANLIST><LEDGERBAL><BALAMT>3120.55</LEDGERBAL></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
    """

    static func api(_ accounts: [Account] = []) -> LedgerBudgetAPI {
        var state = LedgerState.empty
        state.accounts = accounts
        return LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { Fixture.now }, chatModel: nil, decisions: DecisionRouting(),
                               persistence: nil, deployment: DeploymentInfo(endpoint: "t", version: "t", sources: [.fileImport], institutions: []))
    }

    /// Every run of six digits of the number.
    static let fragments = (0...(number.count - 6)).map { String(Array(number)[$0..<($0 + 6)]) }

    @Test("OFX ids never contain the account number, even when FITID embeds it")
    func noNumberInIDs() throws {
        let account = try #require(try FileImport.parse(Self.statement, ids: .test).accounts.first)
        let texts = [account.externalID, account.name, account.mask ?? ""] + account.transactions.map(\.externalID)
        #expect(!texts.contains { text in Self.fragments.contains { text.contains($0) } })
        #expect(account.mask == "0123" && account.name == "Account ••0123")
        #expect(account.transactions.allSatisfy { $0.externalID.hasPrefix("ofxh1-") && $0.externalID.count == "ofxh1-".count + 20 })
        // The key matters: another key gives other ids.
        let other = try FileImport.parse(Self.statement, ids: .keyed("another key")).accounts[0]
        #expect(Set(other.transactions.map(\.externalID)).isDisjoint(with: account.transactions.map(\.externalID)))
    }

    @Test("Without ids an OFX file is refused; a CSV doesn't need them")
    func needsIDs() throws {
        #expect(throws: FileImport.ParseError.self) { try FileImport.parse(Self.statement) }
        #expect(throws: Never.self) { try FileImport.parse("Date,Description,Amount\n09/10/2026,COFFEE,-4.00\n") }
        #expect(FileImport.format(of: Self.statement) == .ofx && FileImport.format(of: "Date,Amount\n") == .csv)
    }

    @Test("OFX without an account or a name comes back as 'file' and ingest refuses it")
    func untargetedRefused() async throws {
        let snapshot = try FileImport.parse(Self.statement, ids: .test)
        #expect(snapshot.accounts.first?.externalID == "file")
        let api = Self.api()
        await #expect(throws: BudgetAPIError.self) { try await api.ingest(snapshot, batchID: "f1") }
        let state = await api.state
        #expect(state.accounts.isEmpty && state.transactions.isEmpty)
        // A hand-built snapshot named after a number is refused the same way.
        var numbered = snapshot
        numbered.accounts[0].externalID = Self.number
        await #expect(throws: BudgetAPIError.self) { try await api.ingest(numbered, batchID: "f2") }
    }

    @Test("OFX into a new named account: the same name as a CSV account lands in that account")
    func namedAccountShared() async throws {
        let api = Self.api()
        let options = FileImport.Options(accountKind: .checking, institution: "Harbor", accountName: "Everyday Checking")
        let csv = try FileImport.parse("Date,Description,Amount\n09/01/2026,RENT,-1800.00\n", options: options)
        _ = try await api.ingest(csv, batchID: "csv")
        let ofx = try FileImport.parse(Self.statement, options: options, ids: .test)
        #expect(ofx.accounts[0].externalID == csv.accounts[0].externalID && ofx.accounts[0].name == "Everyday Checking")
        let report = try await api.ingest(ofx, batchID: "ofx")
        #expect(report.accountsAdded == 0 && report.rowsAdded == 3)
        let state = await api.state
        #expect(state.accounts.count == 1 && state.accounts[0].mask == "0123")
        #expect(state.transactions.count == 4 && Set(state.transactions.map(\.accountID)).count == 1)
    }

    @Test("Re-importing the same OFX adds nothing; the same OFX into two accounts lands in both")
    func reimportAndTwoAccounts() async throws {
        let accounts = ["a", "b"].map { Account(id: $0, name: "Account \($0)", institution: "Harbor", kind: .checking, balance: .zero, source: .plaid) }
        let api = Self.api(accounts)
        let snapshot = try FileImport.parse(Self.statement, ids: .test)
        #expect(try await api.ingest(snapshot, batchID: "1", into: "a").rowsAdded == 3)
        #expect(try await api.ingest(snapshot, batchID: "2", into: "a").rowsAdded == 0)
        #expect(try await api.ingest(snapshot, batchID: "3", into: "b").rowsAdded == 3)
        #expect(await api.state.transactions.count == 6)
    }

    @Test("After the key changes, an older statement's rows are matched by date and amount instead of doubling")
    func keyChangedFallsBackToMatching() async throws {
        let accounts = [Account(id: "a", name: "Checking", institution: "Harbor", kind: .checking, balance: .zero, source: .plaid)]
        let api = Self.api(accounts)
        _ = try await api.ingest(try FileImport.parse(Self.statement, ids: .test), batchID: "old-key", into: "a")
        // Same file, new key: no id matches. Without knowing the key changed, every row would double.
        let unaware = try FileImport.parse(Self.statement, ids: .keyed("new key"))
        #expect(!unaware.statementKeyChanged)
        let copy = LedgerBudgetAPI(state: await api.state, calendar: Fixture.calendar, clock: { Fixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                   persistence: nil, deployment: DeploymentInfo(endpoint: "t", version: "t", sources: [.fileImport], institutions: []))
        #expect(try await copy.ingest(unaware, batchID: "x", into: "a").rowsAdded == 3)
        let rekeyed = StatementIDs(digest: { StableHash.hex128("new key|" + $0) }, gate: StatementIDs.Gate(isOpen: false))
        rekeyed.gate.open(keyChanged: true)
        let aware = try FileImport.parse(Self.statement, ids: rekeyed)
        #expect(aware.statementKeyChanged)
        let report = try await api.ingest(aware, batchID: "new-key", into: "a")
        #expect(report.rowsAdded == 0 && report.duplicatesSkipped == 3)
    }

    @Test("Long numbers in free text keep only their last four digits")
    func masking() {
        #expect(StatementIDs.maskNumbers("Checking_9876543210123.qfx") == "Checking_••0123.qfx")
        #expect(StatementIDs.maskNumbers("Chase1234_Activity_2026.csv") == "Chase1234_Activity_2026.csv")
        #expect(StatementIDs.maskNumbers("ref 123456 and 7654321") == "ref ••3456 and ••4321")
        #expect(StatementIDs.mask("1X0001111") == "1111" && StatementIDs.mask("ofx") == nil)
    }
}
