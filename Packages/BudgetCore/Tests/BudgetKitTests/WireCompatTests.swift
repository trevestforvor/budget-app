import Foundation
import Testing
@testable import BudgetKit

/// Server 0.6.0 only adds optional fields and tolerant enums: what a 0.5.5 server sent and stored still decodes, and a
/// value a newer server sends that this build doesn't know falls back instead of failing the whole response.
@Suite("Wire compatibility with 0.5.5")
struct WireCompatTests {
    /// Keys 0.6.0 added anywhere on the wire or in the stored ledger.
    static let newKeys: Set<String> = [
        "accountHealth", "reason", "linkID", "dueBy", "errorKind", "failingSince", "nextRetryAt", "consentExpiresAt", "reconnect",
        "reconnectURL", "syncLinkID", "recentSyncs", "skipped", "balanceAsOf", "lastSyncedAt", "nickname", "kindSetByPerson",
        "maskSetByPerson", "holdings", "possibleDuplicates", "mergeLog", "pendingMisses", "connectionAlerts", "basis", "matchCount", "sample",
    ]

    /// `value` as JSON with every 0.6.0 key taken out, at any depth: what a 0.5.5 server would have sent.
    static func asOldServer<T: Encodable>(_ value: T, keep: Set<String> = []) throws -> Data {
        func strip(_ any: Any) -> Any {
            if let object = any as? [String: Any] {
                return object.filter { !newKeys.subtracting(keep).contains($0.key) }.mapValues(strip)
            }
            if let array = any as? [Any] { return array.map(strip) }
            return any
        }
        let json = try JSONSerialization.jsonObject(with: RemoteBudgetAPI.encoder.encode(value))
        return try JSONSerialization.data(withJSONObject: strip(json))
    }

    @Test("A 0.5.5 overview, status and institution decode, with nil for everything new")
    func oldPayloads() async throws {
        let api = LedgerBudgetAPI(latency: .zero)
        let overview = try await api.overview()
        let old = try RemoteBudgetAPI.decoder.decode(Overview.self, from: Self.asOldServer(overview))
        #expect(old.accountHealth == nil && old.accounts.count == overview.accounts.count)
        #expect(old.accounts.allSatisfy { $0.nickname == nil && $0.balanceAsOf == nil && $0.lastSyncedAt == nil })
        #expect(old.attention?.allSatisfy { $0.reason == nil && $0.linkID == nil } != false)

        let status = try await api.serverStatus()
        let oldStatus = try RemoteBudgetAPI.decoder.decode(ServerStatus.self, from: Self.asOldServer(status))
        #expect(oldStatus.institutions.count == status.institutions.count)

        let link = #"""
        {"id": "plaid-item-1", "institution": "Harbor", "priority": "core", "primary": "plaid", "accountKinds": ["checking"],
         "status": "needsReauth", "note": "Harbor needs you to sign in again.", "lastSync": "2026-10-01T12:00:00Z",
         "lastError": "Plaid: login required (ITEM_LOGIN_REQUIRED)", "accountIDs": ["plaid:chk"]}
        """#
        let decoded = try RemoteBudgetAPI.decoder.decode(InstitutionLink.self, from: Data(link.utf8))
        #expect(decoded.status == .needsReauth && decoded.errorKind == nil && decoded.reconnect == nil && decoded.recentSyncs == nil)

        let result = try RemoteBudgetAPI.decoder.decode(LinkSyncResult.self, from: Data(#"{"linkID":"a","institution":"b","ok":false,"removed":0,"error":"x"}"#.utf8))
        #expect(result.errorKind == nil && result.skipped == nil)
    }

    @Test("Values this build doesn't know fall back to a safe case")
    func tolerantEnums() throws {
        let decoder = RemoteBudgetAPI.decoder
        let attention = try decoder.decode(DataAttention.self, from: Data(#"{"id":"x","kind":"somethingNew","title":"t","detail":"d","reason":"alsoNew"}"#.utf8))
        #expect(attention.kind == .stale && attention.reason == .quiet)
        #expect(try decoder.decode([LinkErrorKind].self, from: Data(#"["needsSignIn","fromTheFuture"]"#.utf8)) == [.needsSignIn, .transient])
        #expect(try decoder.decode(ReconnectMethod.self, from: Data(#""teleport""#.utf8)) == .dashboard)
        #expect(try decoder.decode(AccountHealth.State.self, from: Data(#""wobbly""#.utf8)) == .current)
        #expect(try decoder.decode(ConnectionAlertKind.self, from: Data(#""newKind""#.utf8)) == .needsSignIn)
        let session = #"{"id":"s","linkID":"l","institution":"Harbor","state":"paused","expiresAt":"2026-10-17T12:00:00Z"}"#
        #expect(try decoder.decode(ReconnectSession.self, from: Data(session.utf8)).state == .failed)
        // Known values still read as themselves.
        #expect(try decoder.decode(DataAttention.Kind.self, from: Data(#""needsReauth""#.utf8)) == .needsReauth)
        #expect(try decoder.decode(ReconnectSession.State.self, from: Data(#""done""#.utf8)) == .done)
    }

    @Test("A ledger stored by 0.5.5 decodes, with the new fields empty, and round-trips")
    func oldLedger() throws {
        let state = LedgerBudgetAPI.demoState(now: Fixture.now, calendar: Fixture.calendar)
        let old = try RemoteBudgetAPI.decoder.decode(LedgerState.self, from: Self.asOldServer(state))
        #expect(old.holdings.isEmpty && old.possibleDuplicates.isEmpty && old.mergeLog.isEmpty && old.pendingMisses.isEmpty)
        #expect(old.transactions.count == state.transactions.count && old.accounts.count == state.accounts.count)
        let again = try RemoteBudgetAPI.decoder.decode(LedgerState.self, from: RemoteBudgetAPI.encoder.encode(old))
        #expect(again == old)
    }

    @Test("A nickname names the account everywhere its short label is used")
    func displayName() {
        var account = Account(id: "a", name: "CREDIT CARD", institution: "Chase", kind: .credit, balance: .zero, source: .plaid, mask: "1008")
        #expect(account.displayName == "CREDIT CARD" && account.shortLabel == "CREDIT CARD ••1008")
        account.nickname = "Freedom"
        #expect(account.displayName == "Freedom" && account.shortLabel == "Freedom ••1008")
    }

    @Test("Sources say how they deliver rows")
    func syncStyle() {
        #expect(SourceKind.plaid.syncStyle == .cursor && SourceKind.simplefin.syncStyle == .window && SourceKind.teller.syncStyle == .window)
        #expect(SourceKind.fileImport.syncStyle == .file && SourceKind.financekit.syncStyle == .device)
    }
}
