import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

/// A store that fails the saves `failing` picks, counting every attempt; everything else goes to a `MemoryStore`.
actor FlakyStore: ServerStore {
    let inner: MemoryStore
    private let failing: @Sendable (LedgerState) -> Bool
    private(set) var saveAttempts = 0

    init(ledger: LedgerState?, failing: @escaping @Sendable (LedgerState) -> Bool) {
        inner = MemoryStore(ledger: ledger)
        self.failing = failing
    }

    struct Refused: Error {}

    func save(from old: LedgerState, to new: LedgerState) async throws {
        saveAttempts += 1
        if failing(new) { throw Refused() }
        try await inner.save(from: old, to: new)
    }
    func migrate() async throws { try await inner.migrate() }
    func loadLedger() async throws -> LedgerState? { try await inner.loadLedger() }
    func replaceLedger(_ state: LedgerState) async throws { try await inner.replaceLedger(state) }
    func links() async throws -> [StoredLink] { try await inner.links() }
    func upsertLink(_ link: StoredLink) async throws { try await inner.upsertLink(link) }
    func deleteLink(_ id: String) async throws { try await inner.deleteLink(id) }
    func imports() async throws -> [ImportRecord] { try await inner.imports() }
    func upsertImport(_ record: ImportRecord) async throws { try await inner.upsertImport(record) }
    func clearImports() async throws { try await inner.clearImports() }
    func setting(_ key: String) async throws -> Data? { try await inner.setting(key) }
    func saveSetting(_ key: String, _ document: Data) async throws { try await inner.saveSetting(key, document) }
}

/// P0.6 on the server: the statement-id upgrade at start (once, safely, never stopping the server), the chats and
/// labels it scrubs, the dry run, and what OFX imports get before and after.
@Suite("Statement id migration on the server")
struct StatementIDMigrationTests {
    static let number = "9876543210123"
    /// The demo's checking account.
    static let checking = "chk"
    static let legacyAccount = "fileImport:\(number)"
    static func legacyRow(_ i: Int) -> String { "fileImport:\(legacyAccount):ofx-\(number)-F\(i)" }

    /// The demo ledger plus an account an untargeted 0.5.x OFX import named after the number, with four rows.
    static func legacy() -> LedgerState {
        var state = LedgerBudgetAPI.demoState(now: Date(), calendar: TestServer.config().calendar)
        state.accounts.append(Account(id: legacyAccount, name: "Account ••0123", institution: "Meadow", kind: .checking, balance: Money(900), source: .fileImport))
        for i in 1...4 {
            let posted: Date = Date().addingTimeInterval(-86_400 * Double(i))
            let amount = Money(minorUnits: Int64(-1000 * i))
            state.transactions.append(LedgerTransaction(id: legacyRow(i), accountID: legacyAccount, postedAt: posted, merchant: "Meadow \(i)",
                                                        rawDescription: "MEADOW \(i)", amount: amount, categorization: nil, isPending: false,
                                                        source: .fileImport, batchID: "file-legacy", providerCategory: nil))
        }
        state.openingBalances[legacyAccount] = Money(1000)
        return state
    }

    /// A conversation whose tool output named a legacy row and account.
    static func chat() -> ChatSessionRecord {
        let output = #"{"transactions":[{"id":"\#(legacyRow(1))","accountID":"\#(legacyAccount)"}],"file":"ofx-\#(number)-F9"}"#
        let session = ChatSession(id: "chat-1", title: "Meadow", createdAt: Date(), updatedAt: Date())
        return ChatSessionRecord(session: session, transcripts: ["turn-1": [StoredChatMessage(.user("What did Meadow cost?")), StoredChatMessage(.tool("call-1", output))]])
    }

    static func importRecord() -> ImportRecord {
        var report = IngestReport(batchID: "file-legacy", source: .fileImport)
        report.warnings = ["Set aside Account \(number): it's in CAD"]
        report.notes = ["From \(number).qfx"]
        return ImportRecord(batchID: "file-legacy", kind: .file, linkID: nil, label: "Checking_\(number).qfx", report: report, createdAt: Date(), rolledBack: false)
    }

    static func service(_ store: any ServerStore, chats: InMemoryChatSessionStore? = nil, config: ServerConfig = TestServer.config()) async throws -> BudgetService {
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: store, logger: Logger(label: "test"))
        if let chats { await service.api.setChatSessionStore(chats) }
        return service
    }

    static func json(_ value: some Encodable) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }

    static func ofxBody(into account: String?, name: String? = nil) -> ByteBuffer {
        let ofx = "OFXHEADER:100\n<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>USD<BANKACCTFROM><ACCTID>\(number)</BANKACCTFROM><BANKTRANLIST>\n"
            + "<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260910<TRNAMT>-10.00<FITID>F1<NAME>MEADOW 1\n</BANKTRANLIST><LEDGERBAL><BALAMT>900.00</LEDGERBAL></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>"
        var body: [String: Any] = ["content": ofx, "label": "Checking_\(number).qfx"]
        if let account { body["accountID"] = account }
        if let name { body["options"] = ["format": "auto", "sign": "auto", "accountName": name, "institution": "Meadow"] }
        return ByteBuffer(bytes: try! JSONSerialization.data(withJSONObject: body))
    }

    static func csvBody(name: String) -> ByteBuffer {
        TestServer.body(#"{"content": "Date,Description,Amount\n09/10/2026,CORNER MARKET,-4.00\n", "options": {"format": "csv", "sign": "auto", "accountName": "\#(name)", "institution": "Harbor"}}"#)
    }

    static func post(_ body: ByteBuffer, _ client: some TestClientProtocol) async throws -> HTTPResponse.Status {
        try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth, body: body) { $0.status }
    }

    @Test("On start, a ledger with account numbers in ids is migrated once; chats and labels are scrubbed")
    func migratesOnce() async throws {
        let store = MemoryStore(ledger: Self.legacy())
        try await store.upsertImport(Self.importRecord())
        let chats = InMemoryChatSessionStore(records: [Self.chat()])
        let service = try await Self.service(store, chats: chats)
        try await BudgetServerApp.prepare(service)

        let ledger = try #require(try await store.loadLedger())
        #expect(!(try Self.json(ledger)).contains("9876543210"))
        #expect(ledger.transactions.count == Self.legacy().transactions.count)
        #expect(ledger.upgrades.contains(Ledger.statementIDsUpgrade))
        let chat = try #require(await chats.chatRecord(id: "chat-1"))
        #expect(!(try Self.json(chat)).contains("9876543210"))
        // The row id in the chat is the row's new id, so the conversation still points at it.
        let newRow = try #require(ledger.transactions.first { $0.accountID != Self.checking && $0.source == .fileImport && $0.merchant == "Meadow 1" })
        #expect(try Self.json(chat).contains(newRow.id))
        let record = try #require(try await store.imports().first)
        #expect(record.label == "Checking_••0123.qfx")
        #expect(!(try Self.json(record)).contains("9876543210"))
        #expect(service.statementIDs?.gate.isOpen == true)
        #expect(try await store.setting(LedgerMigrations.chatsScrubbed) != nil)

        // The next start finds nothing to do and saves nothing.
        let saves = await store.saveCount
        let again = try await Self.service(store, chats: chats)
        try await BudgetServerApp.prepare(again)
        #expect(await store.saveCount == saves)
        #expect(await again.api.statementIDAudit().isClean)
        #expect(again.statementIDs?.gate.isOpen == true)
    }

    @Test("POST /v1/imports with OFX and no account is 422; with an account or a name it imports, and the label is masked")
    func ofxNeedsAnAccount() async throws {
        let (app, service) = try await TestServer.app(seedDemo: true)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth, body: Self.ofxBody(into: nil)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("Statement files need an account"))
            }
            #expect(try await Self.post(Self.ofxBody(into: Self.checking), client) == .created)
            #expect(try await Self.post(Self.ofxBody(into: nil, name: "Meadow Checking"), client) == .created)
        }
        let state = await service.api.state
        #expect(!(try Self.json(state)).contains("9876543210"))
        #expect(state.accounts.contains { $0.name == "Meadow Checking" && $0.mask == "0123" && $0.id.hasPrefix("fileImport:csv-") })
        #expect(try await service.store.imports().allSatisfy { !$0.label.contains("9876543210") })
    }

    @Test("A Postgres server without BUDGET_TOKEN_KEY refuses OFX and still takes CSV")
    func noKeyRefusesOFX() async throws {
        var config = TestServer.config()
        config.tokenKey = nil
        config.database = .init(host: "127.0.0.1", port: 1, username: "nobody", password: nil, database: "none") // never connected: the store is in memory
        let service = try await Self.service(MemoryStore(ledger: LedgerBudgetAPI.demoState(now: Date(), calendar: config.calendar)), config: config)
        try await BudgetServerApp.prepare(service)
        #expect(service.statementIDs == nil)
        try await Application(router: buildRouter(service)).test(.router) { client in
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth, body: Self.ofxBody(into: Self.checking)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("BUDGET_TOKEN_KEY"))
            }
            #expect(try await Self.post(Self.csvBody(name: "Everyday"), client) == .created)
        }
    }

    @Test("A save that fails during the migration: prepare still returns, nothing changes, OFX gets 503 and CSV works")
    func failedSaveKeepsServerUp() async throws {
        let store = FlakyStore(ledger: Self.legacy()) { $0.upgrades.contains(Ledger.statementIDsUpgrade) }
        let service = try await Self.service(store)
        try await BudgetServerApp.prepare(service)
        #expect(await service.api.statementIDAudit() == StatementIDAudit(accounts: 1, rows: 4, rules: 0))
        #expect(try await store.loadLedger()?.accounts.contains { $0.id == Self.legacyAccount } == true)
        #expect(service.statementIDs?.gate.isOpen == false)
        try await Application(router: buildRouter(service)).test(.router) { client in
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth, body: Self.ofxBody(into: Self.checking)) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(String(buffer: response.body).contains("try again after a restart"))
            }
            #expect(try await Self.post(Self.csvBody(name: "Everyday"), client) == .created)
        }
        // A restart that can save gets through.
        let healthy = try await Self.service(store.inner)
        try await BudgetServerApp.prepare(healthy)
        #expect(await healthy.api.statementIDAudit().isClean && healthy.statementIDs?.gate.isOpen == true)
    }

    @Test("A legacy account written back after the upgrade (an old pod's save) is migrated again at the next start")
    func stalePodRevertMigratesAgain() async throws {
        let store = MemoryStore(ledger: Self.legacy())
        try await BudgetServerApp.prepare(try await Self.service(store))
        var reverted = try #require(try await store.loadLedger())
        #expect(reverted.upgrades.contains(Ledger.statementIDsUpgrade))
        let newID = try #require(reverted.accounts.first { $0.id.hasPrefix("fileImport:stmt-h1-") }?.id)
        reverted.accounts.removeAll { $0.id == newID }
        reverted.accounts.append(Self.legacy().accounts.first { $0.id == Self.legacyAccount }!)
        try await store.replaceLedger(reverted)

        let service = try await Self.service(store)
        try await BudgetServerApp.prepare(service)
        #expect(await service.api.statementIDAudit().isClean)
        let ledger = try #require(try await store.loadLedger())
        let text = try Self.json(ledger)
        #expect(ledger.accounts.filter { $0.id == newID }.count == 1 && !text.contains("9876543210"))
        try await Application(router: buildRouter(service, surface: .dashboard)).test(.router) { client in
            try await client.execute(uri: "/dash/maintenance/statement-ids", method: .get) { response in
                let counts = try JSONDecoder().decode(LedgerMigrations.StatementIDCounts.self, from: Data(response.body.readableBytesView))
                #expect(counts.accounts == 0 && counts.rows == 0 && counts.rules == 0 && counts.chats == 0 && counts.labels == 0 && counts.importsOpen)
            }
        }
    }

    @Test("When saving the loaded ledger fails, the migration is skipped and OFX imports stay off")
    func outOfSyncSkips() async throws {
        var legacy = Self.legacy()
        legacy.upgrades = [] // loading applies the one-time upgrades, so prepare has something to save
        let store = FlakyStore(ledger: legacy) { _ in true }
        let service = try await Self.service(store)
        try await BudgetServerApp.prepare(service)
        #expect(await store.saveAttempts == 1) // persistUpgrades only: the migration never tried
        #expect(await service.api.statementIDAudit().accounts == 1)
        #expect(service.statementIDs?.gate.isOpen == false)
    }

    @Test("BUDGET_STATEMENT_ID_MIGRATION=audit counts, serves the dry run and blocks OFX, but changes nothing")
    func auditMode() async throws {
        let store = MemoryStore(ledger: Self.legacy())
        try await store.upsertImport(Self.importRecord())
        let chats = InMemoryChatSessionStore(records: [Self.chat()])
        let service = try await Self.service(store, chats: chats)
        try await LedgerMigrations.$statementIDModeOverride.withValue(.audit) { try await BudgetServerApp.prepare(service) }
        let ledger = try #require(try await store.loadLedger())
        #expect(ledger.accounts.contains { $0.id == Self.legacyAccount } && !ledger.upgrades.contains(Ledger.statementIDsUpgrade))
        #expect(try await store.imports().first?.label == "Checking_\(Self.number).qfx")
        #expect(try await store.setting(StatementIDKeys.checkSetting) == nil)
        #expect(service.statementIDs?.gate.isOpen == false)
        try await Application(router: buildRouter(service, surface: .dashboard)).test(.router) { client in
            try await client.execute(uri: "/dash/maintenance/statement-ids", method: .get) { response in
                #expect(response.status == .ok)
                let counts = try JSONDecoder().decode(LedgerMigrations.StatementIDCounts.self, from: Data(response.body.readableBytesView))
                #expect(counts.accounts == 1 && counts.rows == 4 && counts.chats == 1 && counts.labels == 1 && !counts.importsOpen)
            }
        }
        try await Application(router: buildRouter(service)).test(.router) { client in
            #expect(try await Self.post(Self.ofxBody(into: Self.checking), client) == .serviceUnavailable)
            // The dry run is the dashboard's alone.
            try await client.execute(uri: "/dash/maintenance/statement-ids", method: .get, headers: TestServer.auth) { #expect($0.status == .notFound) }
        }
        // A normal restart migrates; the dry run reads 0.
        let normal = try await Self.service(store, chats: chats)
        try await BudgetServerApp.prepare(normal)
        let counts = await LedgerMigrations.statementIDCounts(normal)
        #expect(counts.accounts == 0 && counts.rows == 0 && counts.chats == 0 && counts.labels == 0 && counts.importsOpen)
    }

    @Test("The key check is saved once; a different key is noticed and older statement rows are matched by date and amount")
    func keyChangeNoticed() async throws {
        let store = MemoryStore(ledger: LedgerBudgetAPI.demoState(now: Date(), calendar: TestServer.config().calendar))
        let first = try await Self.service(store)
        try await BudgetServerApp.prepare(first)
        #expect(try await store.setting(StatementIDKeys.checkSetting) != nil)
        try await Application(router: buildRouter(first)).test(.router) { client in
            let status = try await Self.post(Self.ofxBody(into: Self.checking), client)
            #expect(status == .created)
        }
        var config = TestServer.config()
        config.tokenKey = Data((0..<32).map { UInt8(255 - $0) }).base64EncodedString()
        let second = try await Self.service(store, config: config)
        try await BudgetServerApp.prepare(second)
        #expect(second.statementIDs?.gate.keyChanged == true)
        let rows = await second.api.state.transactions.count
        try await Application(router: buildRouter(second)).test(.router) { client in
            let status = try await Self.post(Self.ofxBody(into: Self.checking), client)
            #expect(status == .created)
        }
        #expect(await second.api.state.transactions.count == rows)
    }

    @Test("Chat scrubbing swaps old ids for new and masks what's left of a legacy id, leaving new ids alone")
    func chatScrub() {
        let account = "fileImport:stmt-h1-0123456789abcdef"
        let row = "fileImport:\(account):ofxh1-12345678901234567890"
        let text = #"{"a":"\#(Self.legacyRow(1))","b":"\#(Self.legacyRow(2))","c":"\#(Self.legacyAccount)","d":"ofx-\#(Self.number)-F9","e":"\#(row)"}"#
        let scrubbed = StatementIDKeys.scrubChat(text, accounts: [Self.legacyAccount: account], rows: [Self.legacyRow(1): row])
        #expect(!scrubbed.contains("9876543210"))
        #expect(scrubbed.contains(#""a":"\#(row)""#) && scrubbed.contains(#""c":"\#(account)""#))
        #expect(scrubbed.contains(#""b":"fileImport:\#(account):ofx-••0123-F2""#) && scrubbed.contains(#""d":"ofx-••0123-F9""#))
        #expect(scrubbed.contains(#""e":"\#(row)""#))
        #expect(StatementIDKeys.scrubChat(scrubbed) == scrubbed)
    }
}
