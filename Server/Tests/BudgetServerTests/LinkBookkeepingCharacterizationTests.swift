import BudgetKit
@testable import BudgetServerCore
import Foundation
import Testing

/// Pins what a sync writes on its link and in the import history, written against 0.5.5 before the 0.6.0 foundation
/// moved the provider branches and the bookkeeping. The move changed nothing here. Three deliberate 0.6.0 changes (P1.1)
/// are marked "0.6.0": Plaid's errors are judged by their code, not the HTTP status, so step 3 uses a real sign-in code;
/// failed syncs are recorded too, so `imports` counts only the batches that changed rows; and a transient failure backs
/// off, so step 9 waits it out first.
@Suite("Link bookkeeping, as 0.5.5 did it")
struct LinkBookkeepingCharacterizationTests {
    struct Seen: Equatable, CustomStringConvertible {
        var status: ConnectionStatus
        var lastError: String?
        var lastSync: Date?
        /// Batches that changed rows; 0.6.0 also records failed syncs, counted apart.
        var imports: Int
        var description: String { "\(status) error=\(lastError ?? "nil") lastSync=\(lastSync.map { "\($0.timeIntervalSince1970)" } ?? "nil") imports=\(imports)" }
    }

    struct TextError: Error, CustomStringConvertible { var description: String }

    static func seen(_ service: BudgetService, _ id: String) async throws -> Seen {
        let link = try #require(try await service.store.links().first { $0.id == id })
        return Seen(status: link.status, lastError: link.lastError, lastSync: link.lastSync,
                    imports: try await service.store.imports().filter { $0.outcome != .failed }.count)
    }

    static func link(_ service: BudgetService, id: String, provider: SourceKind, token: String) async throws {
        let sealed = try #require(try service.sealer?.seal(token))
        try await service.store.upsertLink(StoredLink(id: id, provider: provider, institution: "Harbor", externalID: "item-1", sealedToken: sealed,
                                                      cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Date()))
    }

    @Test("Plaid: success with rows and without, 401, 403, the two sign-in codes, a generic failure and a retry")
    func plaid() async throws {
        let plaid = ScriptedProvider([
            "/transactions/sync": [
                PlaidScript.page("c1", PlaidScript.row),                                         // 1 rows
                PlaidScript.page("c2"),                                                          // 2 none
                (400, #"{"error_type": "ITEM_ERROR", "error_code": "INVALID_CREDENTIALS", "error_message": "who are you"}"#), // 3 (0.6.0)
                (403, ""),                                                                       // 5
                PlaidScript.loginRequired,                                                       // 6
                (500, #"{"error_code": "INTERNAL_SERVER_ERROR", "error_message": "try again"}"#), // 8
                (500, #"{"error_code": "INTERNAL_SERVER_ERROR", "error_message": "still down"}"#),// 9
                PlaidScript.page("c3"),                                                          // 10
            ],
            "/accounts/get": [PlaidScript.balances], "/accounts/balance/get": [PlaidScript.balances],
        ])
        let (_, service) = try await TestServer.app(seedDemo: false, plaid: plaid)
        try await Self.link(service, id: "plaid-item-1", provider: .plaid, token: "access-sandbox-9")
        let id = "plaid-item-1"

        // 1. A scheduled sync with rows: connected, stamped, one import.
        let r1 = await service.sync.syncAll()
        #expect(r1.map(\.ok) == [true] && r1[0].report?.rowsAdded == 1)
        let s1 = try await Self.seen(service, id)
        #expect(s1.status == .connected && s1.lastError == nil && s1.lastSync != nil && s1.imports == 1)

        // 2. A sync with nothing new: stamped again, no import written.
        let r2 = await service.sync.syncAll()
        #expect(r2.map(\.ok) == [true] && r2[0].report?.rowsAdded == 0)
        let s2 = try await Self.seen(service, id)
        #expect(s2.status == .connected && s2.lastError == nil && s2.imports == 1)
        #expect(try #require(s2.lastSync) >= #require(s1.lastSync))

        // 3. Plaid refuses the sign-in: needs a sign-in, says why, keeps the last good sync, no import.
        let r3 = try await service.sync.sync(linkID: id)
        #expect(!r3.ok && r3.error == "Plaid: who are you (INVALID_CREDENTIALS)" && r3.report == nil)
        #expect(try await Self.seen(service, id) == Seen(status: .needsReauth, lastError: "Plaid: who are you (INVALID_CREDENTIALS)", lastSync: s2.lastSync, imports: 1))

        // 4. Sync-all leaves a link waiting for a sign-in alone, and asks the provider nothing.
        let before = plaid.count("/transactions/sync")
        #expect(await service.sync.syncAll().isEmpty)
        #expect(plaid.count("/transactions/sync") == before)
        #expect(try await Self.seen(service, id).status == .needsReauth)

        // 5. A per-link retry that gets a 403: still waiting for a sign-in.
        let r5 = try await service.sync.sync(linkID: id)
        #expect(!r5.ok)
        let s5 = try await Self.seen(service, id)
        #expect(s5.status == .needsReauth && s5.lastError == r5.error && s5.lastSync == s2.lastSync && s5.imports == 1)

        // 6. Plaid's ITEM_LOGIN_REQUIRED.
        let r6 = try await service.sync.sync(linkID: id)
        #expect(r6.error == "Plaid: the login details of this item have changed (ITEM_LOGIN_REQUIRED)")
        #expect(try await Self.seen(service, id) == Seen(status: .needsReauth, lastError: r6.error, lastSync: s2.lastSync, imports: 1))

        // 7. (0.6.0) Teller's enrollment.disconnected text went with Teller (SPEC §10); nothing reads it any more.

        // 8. A per-link retry of a link waiting for a sign-in that fails for another reason: back to connected, with
        //    the error, for the schedule to try again.
        let r8 = try await service.sync.sync(linkID: id)
        #expect(!r8.ok && r8.error?.contains("try again") == true)
        #expect(try await Self.seen(service, id) == Seen(status: .connected, lastError: r8.error, lastSync: s2.lastSync, imports: 1))

        // 9. (0.6.0) The schedule waits out the backoff the failure set, asking nothing.
        let asked = plaid.count("/transactions/sync")
        #expect(await service.sync.syncAll().isEmpty)
        #expect(plaid.count("/transactions/sync") == asked)
        try await service.sync.updateLink(id) { $0.nextAttemptAt = Date().addingTimeInterval(-1) }
        //    Then a generic failure on the schedule: stays connected, error recorded, nothing else changes.
        let r9 = await service.sync.syncAll()
        #expect(r9.map(\.ok) == [false] && r9[0].error?.contains("still down") == true)
        #expect(try await Self.seen(service, id) == Seen(status: .connected, lastError: r9[0].error, lastSync: s2.lastSync, imports: 1))

        // 10. The next good sync clears the error and stamps the time.
        let r10 = try await service.sync.sync(linkID: id)
        #expect(r10.ok && r10.error == nil)
        let s10 = try await Self.seen(service, id)
        #expect(s10.status == .connected && s10.lastError == nil && s10.imports == 1)
        #expect(try #require(s10.lastSync) >= #require(s2.lastSync))
        let link = try #require(try await service.store.links().first { $0.id == id })
        #expect(link.cursor == "c3")
        // (0.6.0) Each failure, 3, 5, 6, 8 and 9, is in the history.
        #expect(try await service.store.imports().filter { $0.outcome == .failed }.count == 5)
    }

    @Test("Which failures need the person to sign in again")
    func signInRule() {
        #expect(SyncService.needsSignIn(SourceHTTPError(status: 401, body: "")))
        #expect(SyncService.needsSignIn(SourceHTTPError(status: 403, body: "")))
        #expect(SyncService.needsSignIn(SourceHTTPError(status: 400, body: "ITEM_LOGIN_REQUIRED")))
        #expect(!SyncService.needsSignIn(SourceHTTPError(status: 500, body: "enrollment.disconnected")))  // Teller's, gone in 0.6.0
        #expect(SyncService.needsSignIn(TextError(description: "provider said ITEM_LOGIN_REQUIRED")))
        #expect(!SyncService.needsSignIn(TextError(description: "something else")))
        #expect(!SyncService.needsSignIn(SourceHTTPError(status: 429, body: "RATE_LIMIT_EXCEEDED")))
    }

    // Teller's case changed on purpose in 0.6.0 (SPEC §10: Teller removed): its sync is gone, and a stored link says so.
    @Test("Teller: a stored link is left out of every run; syncing it alone files the shut-down note as terminal")
    func teller() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        try await Self.link(service, id: "teller-enr_1", provider: .teller, token: "tok-1")

        #expect(await service.sync.syncAll().isEmpty)
        #expect(await service.sync.syncAll(trigger: .person).isEmpty)
        #expect(try await Self.seen(service, "teller-enr_1") == Seen(status: .connected, lastError: nil, lastSync: nil, imports: 0))

        let r = try await service.sync.sync(linkID: "teller-enr_1")
        #expect(!r.ok && r.error == SyncService.tellerGone && r.errorKind == .providerSetup)
        #expect(try await Self.seen(service, "teller-enr_1") == Seen(status: .connected, lastError: SyncService.tellerGone, lastSync: nil, imports: 0))
        let link = try #require(try await service.store.links().first)
        #expect(link.errorCode == "teller.shutdown" && link.failureCount == 1)
        #expect(await service.sync.syncAll().isEmpty)
    }

    @Test("SimpleFIN: a stored access URL that won't parse fails the sync without asking for a sign-in")
    func simplefin() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        try await Self.link(service, id: "simplefin-1", provider: .simplefin, token: "")

        let r1 = await service.sync.syncAll()
        #expect(r1.map(\.ok) == [false] && r1[0].error == "Stored SimpleFIN access URL is invalid.")
        #expect(try await Self.seen(service, "simplefin-1") == Seen(status: .connected, lastError: "Stored SimpleFIN access URL is invalid.", lastSync: nil, imports: 0))
        let r2 = try await service.sync.sync(linkID: "simplefin-1")
        #expect(!r2.ok)
        #expect(try await Self.seen(service, "simplefin-1").status == .connected)
    }
}
