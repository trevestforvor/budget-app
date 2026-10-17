import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import Testing

/// Log lines kept in memory, to check what a failure logs.
final class CapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    func append(_ line: String) { lock.withLock { stored.append(line) } }

    var logger: Logger { Logger(label: "captured") { _ in Handler(log: self) } }

    struct Handler: LogHandler {
        let log: CapturedLog
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? { get { metadata[key] } set { metadata[key] = newValue } }
        func log(event: LogEvent) { log.append("\(event.level) \(event.message)") }
    }
}

/// A store whose ledger saves fail when a save would drop rows: `removeSourceRows` fails after the ingest went in.
actor DroppingRowsFailStore: ServerStore {
    let inner = MemoryStore()
    struct Refused: Error {}

    func migrate() async throws {}
    func loadLedger() async throws -> LedgerState? { try await inner.loadLedger() }
    func replaceLedger(_ state: LedgerState) async throws { try await inner.replaceLedger(state) }
    func save(from old: LedgerState, to new: LedgerState) async throws {
        if new.transactions.count < old.transactions.count { throw Refused() }
        try await inner.save(from: old, to: new)
    }
    func links() async throws -> [StoredLink] { try await inner.links() }
    func upsertLink(_ link: StoredLink) async throws { try await inner.upsertLink(link) }
    func deleteLink(_ id: String) async throws { try await inner.deleteLink(id) }
    func imports() async throws -> [ImportRecord] { try await inner.imports() }
    func upsertImport(_ record: ImportRecord) async throws { try await inner.upsertImport(record) }
    func clearImports() async throws { try await inner.clearImports() }
    func setting(_ key: String) async throws -> Data? { try await inner.setting(key) }
    func saveSetting(_ key: String, _ document: Data) async throws { try await inner.saveSetting(key, document) }
}

@Suite("Plaid error kinds, backoff and stop rules (P1.1)")
struct PlaidErrorKindTests {
    static let id = "plaid-item-1"

    static func plaidError(_ code: String, type: String = "ITEM_ERROR", status: Int = 400, requestID: String = "req-42") -> (Int, String) {
        (status, #"{"error_type": "\#(type)", "error_code": "\#(code)", "error_message": "message for \#(code)", "display_message": null, "request_id": "\#(requestID)"}"#)
    }

    static func service(_ plaid: ScriptedProvider, store: (any ServerStore)? = nil, logger: Logger = Logger(label: "test"),
                        surface: Surface = .api) async throws -> (some ApplicationProtocol, BudgetService) {
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: store ?? MemoryStore(), logger: logger,
                                                                 plaidTransport: plaid)
        try await BudgetServerApp.prepare(service)
        let sealed = try #require(try service.sealer?.seal("access-sandbox-9"))
        try await service.store.upsertLink(StoredLink(id: id, provider: .plaid, institution: "Harbor", externalID: "item-1", sealedToken: sealed,
                                                      cursor: "c0", status: .connected, lastSync: nil, lastError: nil, createdAt: Date()))
        return (Application(router: buildRouter(service, surface: surface)), service)
    }

    static func link(_ service: BudgetService) async throws -> StoredLink {
        try #require(try await service.store.links().first { $0.id == id })
    }

    static func cursors(_ plaid: ScriptedProvider) -> [String?] {
        plaid.requests.filter { $0.path == "/transactions/sync" }.map { request in
            guard case let .object(o)? = try? JSONValue.parse(Data(request.body.utf8)), case let .string(c)? = o["cursor"] else { return nil }
            return c
        }
    }

    // MARK: The mapping

    @Test("Each Plaid code maps to its kind", arguments: [
        ("ITEM_LOGIN_REQUIRED", LinkErrorKind.needsSignIn), ("INVALID_CREDENTIALS", .needsSignIn), ("INSUFFICIENT_CREDENTIALS", .needsSignIn),
        ("ITEM_LOCKED", .needsSignIn), ("USER_SETUP_REQUIRED", .needsSignIn), ("ACCESS_NOT_GRANTED", .needsSignIn), ("NO_ACCOUNTS", .needsSignIn),
        ("ITEM_NOT_FOUND", .revoked), ("USER_PERMISSION_REVOKED", .revoked),
        ("RATE_LIMIT_EXCEEDED", .rateLimited), ("INSTITUTION_RATE_LIMIT", .rateLimited),
        ("INSTITUTION_DOWN", .transient), ("INSTITUTION_NOT_RESPONDING", .transient), ("PRODUCT_NOT_READY", .transient),
        ("INTERNAL_SERVER_ERROR", .transient), ("TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION", .transient),
        ("INVALID_API_KEYS", .providerSetup), ("INVALID_SECRET", .providerSetup), ("INVALID_CLIENT_ID", .providerSetup),
        ("UNAUTHORIZED_ENVIRONMENT", .providerSetup), ("INVALID_ACCESS_TOKEN", .providerSetup),
        ("SOMETHING_PLAID_ADDS_NEXT_YEAR", .transient),
    ])
    func mapping(code: String, kind: LinkErrorKind) throws {
        let (status, body) = Self.plaidError(code)
        let failure = try #require(PlaidErrors.classify(SourceHTTPError(status: status, body: body)))
        #expect(failure.kind == kind && failure.code == code && failure.requestID == "req-42")
        // The typed error reads the same as the raw one.
        let typed = try #require(PlaidAPIError(SourceHTTPError(status: status, body: body)))
        #expect(PlaidErrors.classify(typed)?.kind == kind)
    }

    @Test("Branches on the type and code, never the HTTP status; what isn't Plaid's is left to the next classifier")
    func notByStatus() {
        // Any error of type RATE_LIMIT_EXCEEDED is a rate limit, whatever its code (Balance has its own).
        #expect(PlaidErrors.classify(PlaidAPIError(status: 429, errorType: "RATE_LIMIT_EXCEEDED", errorCode: "ACCOUNTS_BALANCE_GET_LIMIT"))?.kind == .rateLimited)
        // INSTITUTION_DOWN comes back as a 400 and is transient; an unknown code on a 401 is transient too.
        #expect(PlaidErrors.classify(SourceHTTPError(status: 400, body: Self.plaidError("INSTITUTION_DOWN", type: "INSTITUTION_ERROR").1))?.kind == .transient)
        #expect(PlaidErrors.classify(SourceHTTPError(status: 401, body: Self.plaidError("UNAUTHORIZED", type: "INVALID_REQUEST").1))?.kind == .transient)
        // Not Plaid's: a proxy's page, an empty body, a network error.
        #expect(PlaidErrors.classify(SourceHTTPError(status: 502, body: "<html>Bad gateway</html>")) == nil)
        #expect(PlaidErrors.classify(SourceHTTPError(status: 403, body: "")) == nil)
        #expect(PlaidErrors.classify(URLError(.timedOut)) == nil)
        // Plaid's classifier is asked only for Plaid links.
        let plaidShaped = SourceHTTPError(status: 400, body: Self.plaidError("ITEM_NOT_FOUND").1)
        #expect(LinkFailureClassifier.classify(plaidShaped, provider: .plaid).kind == .revoked)
        #expect(LinkFailureClassifier.classify(plaidShaped, provider: .simplefin).kind == .transient)
    }

    // MARK: Syncs

    @Test("ITEM_LOCKED parks the link for a sign-in, with the code and request_id stored and logged; no token or body is logged")
    func itemLocked() async throws {
        let log = CapturedLog()
        let plaid = ScriptedProvider(["/transactions/sync": [Self.plaidError("ITEM_LOCKED", requestID: "req-locked")]])
        let (_, service) = try await Self.service(plaid, logger: log.logger)
        let result = try await service.sync.sync(linkID: Self.id)
        #expect(!result.ok && result.errorKind == .needsSignIn)
        let link = try await Self.link(service)
        #expect(link.status == .needsReauth && link.errorKind == .needsSignIn && link.errorCode == "ITEM_LOCKED")
        #expect(link.errorRequestID == "req-locked" && link.failureCount == 1 && link.firstFailedAt != nil && link.nextAttemptAt == nil)
        let line = try #require(log.lines.first { $0.contains("sync failed for Harbor") })
        #expect(line.contains("needsSignIn") && line.contains("ITEM_LOCKED") && line.contains("req-locked"))
        #expect(!log.lines.contains { $0.contains("access-sandbox-9") || $0.contains("error_type") })
        let note = try #require(try await service.api.serverStatus().institutions.first { $0.id == Self.id }).note
        #expect(note.contains("sign in again"))
    }

    @Test("ITEM_NOT_FOUND, confirmed by /item/get: the token is dropped, the link, accounts and rows stay, and nothing calls /item/remove")
    func itemNotFound() async throws {
        let plaid = ScriptedProvider([
            "/transactions/sync": [PlaidScript.page("c1", PlaidScript.row), Self.plaidError("ITEM_NOT_FOUND", type: "INVALID_INPUT")],
            "/accounts/balance/get": [PlaidScript.balances],
            "/item/get": [Self.plaidError("ITEM_NOT_FOUND", type: "INVALID_INPUT")],
            "/link/token/create": [(200, #"{"link_token": "link-should-not-happen"}"#)],
        ])
        let (dash, service) = try await Self.service(plaid, surface: .dashboard)
        #expect(try await service.sync.sync(linkID: Self.id).ok)
        let rows = try await service.api.overview().accounts.count

        let failed = try await service.sync.sync(linkID: Self.id)
        #expect(!failed.ok && failed.errorKind == .revoked)
        let link = try await Self.link(service)
        #expect(link.sealedToken.isEmpty && link.errorKind == .revoked && link.status == .needsReauth && link.cursor == "c1")
        #expect(plaid.count("/item/get") == 1)
        #expect(try await service.api.overview().accounts.count == rows)

        // Never retried on a schedule or a webhook; a person's sync answers at once without asking Plaid.
        let asked = plaid.requests.count
        #expect(await service.sync.syncAll().isEmpty)
        #expect(try await service.sync.sync(linkID: Self.id, trigger: .webhook("SYNC_UPDATES_AVAILABLE")).skipped != nil)
        let again = try await service.sync.sync(linkID: Self.id)
        #expect(!again.ok && again.errorKind == .revoked && again.error?.contains("Link the bank again") == true)
        #expect(plaid.requests.count == asked)

        try await dash.test(.router) { client in
            // Update mode can't repair it, and nothing tries.
            try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: SyncRouteTests.write,
                                     body: TestServer.body(#"{"linkID":"\#(Self.id)"}"#)) { #expect($0.status == .unprocessableContent) }
            // Removing it doesn't call /item/remove: the Item is already gone.
            try await client.execute(uri: "/v1/links/\(Self.id)", method: .delete, headers: SyncRouteTests.write) { #expect($0.status == .noContent) }
        }
        #expect(plaid.count("/item/remove") == 0 && plaid.count("/link/token/create") == 0)
        #expect(try await service.store.links().isEmpty)
    }

    @Test("ITEM_NOT_FOUND that /item/get doesn't confirm keeps the token")
    func itemNotFoundUnconfirmed() async throws {
        let plaid = ScriptedProvider([
            "/transactions/sync": [Self.plaidError("ITEM_NOT_FOUND", type: "INVALID_INPUT")],
            "/item/get": [(200, #"{"item": {"item_id": "item-1", "error": null, "billed_products": ["transactions"]}, "request_id": "r"}"#)],
        ])
        let (_, service) = try await Self.service(plaid)
        _ = try await service.sync.sync(linkID: Self.id)
        let link = try await Self.link(service)
        #expect(!link.sealedToken.isEmpty && link.errorKind == .revoked)
    }

    @Test("An unknown code is transient and backs off: the schedule waits, the person doesn't")
    func unknownBacksOff() async throws {
        let plaid = ScriptedProvider([
            "/transactions/sync": [Self.plaidError("BRAND_NEW_CODE", type: "API_ERROR", status: 500), PlaidScript.page("c1")],
            "/accounts/balance/get": [PlaidScript.balances],
        ])
        let (_, service) = try await Self.service(plaid)
        let before = Date()
        #expect(await service.sync.syncAll().map(\.errorKind) == [.transient])
        let link = try await Self.link(service)
        #expect(link.status == .connected && link.errorKind == .transient && link.errorCode == "BRAND_NEW_CODE")
        let wait = try #require(link.nextAttemptAt).timeIntervalSince(before)
        #expect(wait >= 0.8 * 300 - 1 && wait <= 1.2 * 300 + 1)
        // The schedule and the morning catch-up wait; a webhook (Plaid has data) and the person don't.
        #expect(await service.sync.syncAll().isEmpty)
        #expect(await service.sync.syncAll(trigger: .morningCatchUp).isEmpty)
        #expect(plaid.count("/transactions/sync") == 1)
        #expect(await service.sync.syncAll(trigger: .person).map(\.ok) == [true])
        let healed = try await Self.link(service)
        #expect(healed.errorKind == nil && healed.nextAttemptAt == nil && healed.failureCount == nil && healed.cursor == "c1")
    }

    @Test("Backoff doubles from 5 minutes, is capped at 6 hours, and is jittered by up to 20 %")
    func backoff() {
        #expect((1...8).map { LinkHealthBook.backoff(failures: $0) / 60 } == [5, 10, 20, 40, 80, 160, 320, 360])
        #expect(LinkHealthBook.backoff(failures: 500) == 6 * 3600)
        let now = Date(timeIntervalSince1970: 1_000_000)
        var link = StoredLink(id: "l", provider: .plaid, institution: "Harbor", externalID: nil, sealedToken: "x", cursor: nil, status: .connected,
                              lastSync: nil, lastError: nil, createdAt: now)
        let failure = LinkFailure(kind: .rateLimited, code: "RATE_LIMIT_EXCEEDED", message: "slow down")
        LinkHealthBook.recordFailure(&link, failure, now: now, jitter: 0.8)
        #expect(link.nextAttemptAt == now.addingTimeInterval(240))
        LinkHealthBook.recordFailure(&link, failure, now: now, jitter: 1.2)
        #expect(link.nextAttemptAt == now.addingTimeInterval(720) && link.failureCount == 2 && link.status == .connected)
        // A refused sign-in waits for the person, not a clock.
        LinkHealthBook.recordFailure(&link, LinkFailure(kind: .needsSignIn, message: "sign in"), now: now)
        #expect(link.nextAttemptAt == nil && link.status == .needsReauth)
        // Many random jitters stay in the band.
        for _ in 0..<50 {
            var l = StoredLink(id: "l", provider: .plaid, institution: "H", externalID: nil, sealedToken: "x", cursor: nil, status: .connected,
                               lastSync: nil, lastError: nil, createdAt: now)
            LinkHealthBook.recordFailure(&l, failure, now: now)
            let wait = l.nextAttemptAt!.timeIntervalSince(now)
            #expect(wait >= 240 && wait <= 360)
        }
    }

    @Test("Which runs ask the provider (the stop rules)")
    func stopRules() {
        let now = Date()
        func link(_ kind: LinkErrorKind?, failures: Int, next: Date? = nil, status: ConnectionStatus? = nil) -> StoredLink {
            var l = StoredLink(id: "l", provider: .plaid, institution: "H", externalID: nil, sealedToken: "x", cursor: nil,
                               status: status ?? (kind == .needsSignIn || kind == .revoked ? .needsReauth : .connected),
                               lastSync: nil, lastError: nil, createdAt: now)
            l.errorKind = kind; l.failureCount = failures; l.nextAttemptAt = next
            return l
        }
        let webhook = SyncTrigger.webhook("SYNC_UPDATES_AVAILABLE")
        let later = now.addingTimeInterval(600)
        // Healthy: everything.
        for t in [SyncTrigger.schedule, .morningCatchUp, .person, .personLink, .reconnect, .afterLink, webhook] {
            #expect(LinkHealthBook.isDue(link(nil, failures: 0), trigger: t, now: now))
        }
        // Backing off: the schedule waits; the person and a webhook go.
        #expect(!LinkHealthBook.isDue(link(.transient, failures: 2, next: later), trigger: .schedule, now: now))
        #expect(!LinkHealthBook.isDue(link(.rateLimited, failures: 2, next: later), trigger: .morningCatchUp, now: now))
        #expect(LinkHealthBook.isDue(link(.transient, failures: 2, next: now.addingTimeInterval(-1)), trigger: .schedule, now: now))
        #expect(LinkHealthBook.isDue(link(.transient, failures: 2, next: later), trigger: .person, now: now))
        #expect(LinkHealthBook.isDue(link(.transient, failures: 2, next: later), trigger: webhook, now: now))
        // Needs a sign-in: never the schedule; a webhook until the third failure; one link's sync always.
        #expect(!LinkHealthBook.isDue(link(.needsSignIn, failures: 1), trigger: .schedule, now: now))
        #expect(!LinkHealthBook.isDue(link(.needsSignIn, failures: 1), trigger: .person, now: now))
        #expect(LinkHealthBook.isDue(link(.needsSignIn, failures: 2), trigger: webhook, now: now))
        #expect(!LinkHealthBook.isDue(link(.needsSignIn, failures: 3), trigger: webhook, now: now))
        #expect(LinkHealthBook.isDue(link(.needsSignIn, failures: 9), trigger: .personLink, now: now))
        // Withdrawn: only the person's own sync of that link, a reconnect or a new link.
        #expect(!LinkHealthBook.isDue(link(.revoked, failures: 1), trigger: webhook, now: now))
        #expect(!LinkHealthBook.isDue(link(.revoked, failures: 1), trigger: .person, now: now))
        #expect(LinkHealthBook.isDue(link(.revoked, failures: 1), trigger: .reconnect, now: now))
        // A link parked before 0.6.0 (no kind) waits for a sign-in.
        #expect(!LinkHealthBook.isDue(link(nil, failures: 0, status: .needsReauth), trigger: .schedule, now: now))
    }

    @Test("After three refused sign-ins neither the schedule nor a webhook asks Plaid; the person's sync does")
    func threeSignInFailures() async throws {
        let plaid = ScriptedProvider(["/transactions/sync": [PlaidScript.loginRequired]])
        let (_, service) = try await Self.service(plaid)
        let webhook = SyncTrigger.webhook("SYNC_UPDATES_AVAILABLE")
        _ = try await service.sync.sync(linkID: Self.id)                    // 1, the person
        _ = try await service.sync.sync(linkID: Self.id, trigger: webhook)  // 2, a webhook still tries
        _ = try await service.sync.sync(linkID: Self.id, trigger: webhook)  // 3
        #expect(try await Self.link(service).failureCount == 3)
        let asked = plaid.count("/transactions/sync")
        #expect(asked == 3)
        #expect(await service.sync.syncAll().isEmpty)
        let skipped = try await service.sync.sync(linkID: Self.id, trigger: webhook)
        #expect(skipped.skipped != nil && !skipped.ok)
        #expect(plaid.count("/transactions/sync") == asked)
        _ = try await service.sync.sync(linkID: Self.id)
        #expect(plaid.count("/transactions/sync") == asked + 1)
    }

    @Test("A failed sync is in GET /v1/imports and in the link's recent syncs; a clean sync with nothing new isn't")
    func failedSyncHistory() async throws {
        let plaid = ScriptedProvider([
            "/transactions/sync": [PlaidScript.page("c1", PlaidScript.row), PlaidScript.page("c2"), Self.plaidError("INSTITUTION_DOWN", type: "INSTITUTION_ERROR")],
            "/accounts/balance/get": [PlaidScript.balances],
        ])
        let (app, service) = try await Self.service(plaid)
        #expect(try await service.sync.sync(linkID: Self.id).ok)   // rows: recorded
        #expect(try await service.sync.sync(linkID: Self.id).ok)   // nothing new: not recorded
        #expect(try await service.sync.sync(linkID: Self.id).ok == false)  // failed: recorded
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let records = try RemoteBudgetAPI.decoder.decode([ImportRecord].self, from: Data(response.body.readableBytesView))
                #expect(records.count == 2)
                let failed = try #require(records.first { $0.outcome == .failed })
                #expect(failed.errorKind == .transient && failed.error?.contains("INSTITUTION_DOWN") == true && failed.linkID == Self.id)
                #expect(failed.report.rowsAdded == 0 && failed.undo?.mode == .refused)
                #expect(records.first { $0.outcome != .failed }?.report.rowsAdded == 1)
            }
        }
        let institution = try #require(try await service.api.serverStatus().institutions.first { $0.id == Self.id })
        let recent = try #require(institution.recentSyncs)
        #expect(recent.map(\.ok) == [false, true] && recent[0].kind == .transient && recent[1].rowsAdded == 1)
        #expect(institution.errorKind == .transient && institution.nextRetryAt != nil && institution.failingSince != nil)
        #expect(institution.note.contains("tries again"))
    }

    @Test("Recent syncs: newest five per link, warnings as the message")
    func recentSyncsShape() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var records = (0..<7).map { i in
            ImportRecord(batchID: "b\(i)", kind: .sync, linkID: "a", label: "A sync", report: IngestReport(batchID: "b\(i)", source: .plaid),
                         createdAt: base.addingTimeInterval(Double(i)), rolledBack: false)
        }
        records.append(ImportRecord(batchID: "w", kind: .sync, linkID: "b", label: "B", report: IngestReport(batchID: "w", source: .plaid, warnings: ["Odd row."]),
                                    createdAt: base, rolledBack: false, outcome: .warning))
        records.append(ImportRecord(batchID: "f", kind: .file, linkID: nil, label: "file", report: IngestReport(batchID: "f", source: .fileImport),
                                    createdAt: base, rolledBack: false))
        let recent = SyncService.recentSyncs(records)
        #expect(recent["a"]?.map(\.at) == (2..<7).reversed().map { base.addingTimeInterval(Double($0)) })
        #expect(recent["b"]?.first?.message == "Odd row." && recent["b"]?.first?.ok == true)
        #expect(recent.count == 2)
    }

    @Test("What goes in the history: changed rows, warnings, failures; not a clean empty sync")
    func recordRule() {
        var report = IngestReport(batchID: "b", source: .plaid)
        #expect(!LinkHealthBook.shouldRecordImport(report, failure: nil))
        #expect(!LinkHealthBook.shouldRecordImport(nil, failure: nil))
        #expect(LinkHealthBook.shouldRecordImport(nil, failure: LinkFailure(kind: .transient, message: "x")))
        report.warnings = ["Skipped a row."]
        #expect(LinkHealthBook.shouldRecordImport(report, failure: nil))
        report.warnings = []
        report.rowsUpdated = 1
        #expect(LinkHealthBook.shouldRecordImport(report, failure: nil))
    }

    // MARK: Cursor

    @Test("A pagination Plaid changes mid-way starts over from the original cursor; the stored cursor is the last page's")
    func mutationRestart() async throws {
        let mutation = Self.plaidError("TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION", type: "TRANSACTIONS_ERROR")
        let plaid = ScriptedProvider([
            "/transactions/sync": [
                (200, #"{"added": [\#(PlaidScript.row)], "modified": [], "removed": [], "next_cursor": "p1", "has_more": true}"#),
                mutation,
                (200, #"{"added": [\#(PlaidScript.row)], "modified": [], "removed": [], "next_cursor": "p1b", "has_more": true}"#),
                PlaidScript.page("final"),
            ],
            "/accounts/balance/get": [PlaidScript.balances],
        ])
        let (_, service) = try await Self.service(plaid)
        let result = try await service.sync.sync(linkID: Self.id)
        #expect(result.ok && result.report?.rowsAdded == 1)  // the first attempt's page was thrown away, not added twice
        #expect(Self.cursors(plaid) == ["c0", "p1", "c0", "p1b"])
        #expect(try await Self.link(service).cursor == "final")
    }

    @Test("A pagination that keeps changing gives up after three restarts, as transient, with the cursor unchanged")
    func mutationGivesUp() async throws {
        let mutation = Self.plaidError("TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION", type: "TRANSACTIONS_ERROR")
        let plaid = ScriptedProvider(["/transactions/sync": [mutation]])
        let (_, service) = try await Self.service(plaid)
        let result = try await service.sync.sync(linkID: Self.id)
        #expect(!result.ok && result.errorKind == .transient)
        #expect(plaid.count("/transactions/sync") == 1 + PlaidSource.paginationRestarts)
        #expect(Set(Self.cursors(plaid)) == ["c0"])
        #expect(try await Self.link(service).cursor == "c0")
    }

    @Test("When dropping the removed rows fails, the cursor isn't stored, so the next sync replays them")
    func cursorAfterRowsOnly() async throws {
        let removedRow = #"{"added": [], "modified": [], "removed": [{"transaction_id": "t1"}], "next_cursor": "c2", "has_more": false}"#
        let plaid = ScriptedProvider([
            "/transactions/sync": [PlaidScript.page("c1", PlaidScript.row), (200, removedRow)],
            "/accounts/balance/get": [PlaidScript.balances],
        ])
        let (_, service) = try await Self.service(plaid, store: DroppingRowsFailStore())
        #expect(try await service.sync.sync(linkID: Self.id).ok)
        #expect(try await Self.link(service).cursor == "c1")
        let failed = try await service.sync.sync(linkID: Self.id)
        #expect(!failed.ok)
        #expect(try await Self.link(service).cursor == "c1")
    }

    @Test("Without Plaid's keys a sync fails as a setup problem and backs off")
    func notConfigured() async throws {
        let plaid = ScriptedProvider([:])
        var config = TestServer.config()
        config.plaid = nil
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: MemoryStore(), logger: Logger(label: "test"), plaidTransport: plaid)
        try await BudgetServerApp.prepare(service)
        try await service.store.upsertLink(StoredLink(id: Self.id, provider: .plaid, institution: "Harbor", externalID: "item-1",
                                                      sealedToken: try #require(try service.sealer?.seal("t")), cursor: nil, status: .connected,
                                                      lastSync: nil, lastError: nil, createdAt: Date()))
        let result = try await service.sync.sync(linkID: Self.id)
        #expect(!result.ok && result.errorKind == .providerSetup && result.error == "Plaid isn't set up on the server.")
        let link = try await Self.link(service)
        #expect(link.status == .connected && link.nextAttemptAt != nil && link.errorCode == "plaid-not-configured")
        #expect(plaid.requests.isEmpty)
    }

    @Test("A token that won't open is a setup problem, not a sign-in")
    func unsealable() async throws {
        let plaid = ScriptedProvider([:])
        let (_, service) = try await Self.service(plaid)
        try await service.sync.updateLink(Self.id) { $0.sealedToken = "bm90IGEgc2VhbGVkIHRva2Vu" }
        let result = try await service.sync.sync(linkID: Self.id)
        #expect(!result.ok && result.errorKind == .providerSetup && result.error?.contains("BUDGET_TOKEN_KEY") == true)
        #expect(try await Self.link(service).status == .connected && plaid.requests.isEmpty)
    }
}
