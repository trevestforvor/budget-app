import BudgetKit
@testable import BudgetServerCore
import Foundation
import Testing

/// Pins what a sync writes on its link and in the import history, written against 0.5.5 before the 0.6.0 foundation
/// moved the provider branches and the bookkeeping. It must keep passing unchanged: it is the evidence that the move
/// changed no behaviour.
@Suite("Link bookkeeping, as 0.5.5 did it")
struct LinkBookkeepingCharacterizationTests {
    struct Seen: Equatable, CustomStringConvertible {
        var status: ConnectionStatus
        var lastError: String?
        var lastSync: Date?
        var imports: Int
        var description: String { "\(status) error=\(lastError ?? "nil") lastSync=\(lastSync.map { "\($0.timeIntervalSince1970)" } ?? "nil") imports=\(imports)" }
    }

    struct TextError: Error, CustomStringConvertible { var description: String }

    static func seen(_ service: BudgetService, _ id: String) async throws -> Seen {
        let link = try #require(try await service.store.links().first { $0.id == id })
        return Seen(status: link.status, lastError: link.lastError, lastSync: link.lastSync, imports: try await service.store.imports().count)
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
                (401, #"{"error_code": "UNAUTHORIZED", "error_message": "who are you"}"#),        // 3
                (403, ""),                                                                       // 5
                PlaidScript.loginRequired,                                                       // 6
                (400, #"{"error": {"code": "enrollment.disconnected", "message": "gone"}}"#),    // 7
                (500, #"{"error_code": "INTERNAL_SERVER_ERROR", "error_message": "try again"}"#), // 8
                (500, #"{"error_code": "INTERNAL_SERVER_ERROR", "error_message": "still down"}"#),// 9
                PlaidScript.page("c3"),                                                          // 10
            ],
            "/accounts/balance/get": [PlaidScript.balances],
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

        // 3. A 401 from the provider: needs a sign-in, says why, keeps the last good sync, no import.
        let r3 = try await service.sync.sync(linkID: id)
        #expect(!r3.ok && r3.error == "Plaid: who are you (UNAUTHORIZED)" && r3.report == nil)
        #expect(try await Self.seen(service, id) == Seen(status: .needsReauth, lastError: "Plaid: who are you (UNAUTHORIZED)", lastSync: s2.lastSync, imports: 1))

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

        // 7. Teller's enrollment.disconnected text, on a status that isn't 401/403.
        let r7 = try await service.sync.sync(linkID: id)
        #expect(!r7.ok)
        #expect(try await Self.seen(service, id) == Seen(status: .needsReauth, lastError: r7.error, lastSync: s2.lastSync, imports: 1))

        // 8. A per-link retry of a link waiting for a sign-in that fails for another reason: back to connected, with
        //    the error, for the schedule to try again.
        let r8 = try await service.sync.sync(linkID: id)
        #expect(!r8.ok && r8.error?.contains("try again") == true)
        #expect(try await Self.seen(service, id) == Seen(status: .connected, lastError: r8.error, lastSync: s2.lastSync, imports: 1))

        // 9. A generic failure on the schedule: stays connected, error recorded, nothing else changes.
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
    }

    @Test("Which failures need the person to sign in again")
    func signInRule() {
        #expect(SyncService.needsSignIn(SourceHTTPError(status: 401, body: "")))
        #expect(SyncService.needsSignIn(SourceHTTPError(status: 403, body: "")))
        #expect(SyncService.needsSignIn(SourceHTTPError(status: 400, body: "ITEM_LOGIN_REQUIRED")))
        #expect(SyncService.needsSignIn(SourceHTTPError(status: 500, body: "enrollment.disconnected")))
        #expect(SyncService.needsSignIn(TextError(description: "provider said ITEM_LOGIN_REQUIRED")))
        #expect(SyncService.needsSignIn(TextError(description: "enrollment.disconnected")))
        #expect(!SyncService.needsSignIn(TextError(description: "something else")))
        #expect(!SyncService.needsSignIn(SourceHTTPError(status: 429, body: "RATE_LIMIT_EXCEEDED")))
    }

    // Teller's case changed on purpose in 0.6.0 (SPEC §10: Teller removed): its sync is gone, and a stored link says so.
    @Test("Teller: a stored link fails every sync with the shut-down note, stays connected and writes nothing")
    func teller() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        try await Self.link(service, id: "teller-enr_1", provider: .teller, token: "tok-1")

        let r1 = await service.sync.syncAll()
        #expect(r1.map(\.ok) == [false] && r1[0].error?.contains("Teller has shut down") == true)
        #expect(try await Self.seen(service, "teller-enr_1") == Seen(status: .connected, lastError: r1[0].error, lastSync: nil, imports: 0))
        let r2 = try await service.sync.sync(linkID: "teller-enr_1")
        #expect(!r2.ok && r2.error == r1[0].error)
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
