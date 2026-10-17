import BudgetKit
import Foundation

/// SimpleFIN's own state for one link, kept on its `StoredLink` (`StoredLink.simplefin`). Every field is optional or
/// defaulted, so a link stored before one existed still decodes. The bridge's connection ids stay here: clients see
/// `StableHash.short` of them.
public struct SimpleFINLinkState: Codable, Hashable, Sendable {
    /// Requests in the last 24 hours (`SimpleFINBudget`).
    public var requests: [SimpleFINRequest] = []
    /// Each bank behind the link, by the bridge's `conn_id`.
    public var connections: [String: SimpleFINConnectionState] = [:]
    /// The history walk; nil until the first pull since 0.6.0 starts it.
    public var backfill: SimpleFINBackfill? = nil
    /// The last daily log of the bridge's `extra` key names.
    public var extraKeysLoggedAt: Date? = nil

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = try c.decodeIfPresent([SimpleFINRequest].self, forKey: .requests) ?? []
        connections = try c.decodeIfPresent([String: SimpleFINConnectionState].self, forKey: .connections) ?? [:]
        backfill = try c.decodeIfPresent(SimpleFINBackfill.self, forKey: .backfill)
        extraKeysLoggedAt = try c.decodeIfPresent(Date.self, forKey: .extraKeysLoggedAt)
    }

    /// Where a bank's sign-in is fixed. The phone opens only this host.
    static let bridgeURL = "https://beta-bridge.simplefin.org"

    /// The id clients see for a bank: never the bridge's own.
    static func bankID(_ connectionID: String) -> String { StableHash.short(connectionID) }

    /// One bank's row id in Settings → Accounts: `<linkID>~<bank id>`. Syncing it syncs the link (`syncLinkID`).
    static func rowID(linkID: String, connectionID: String) -> String { "\(linkID)~\(bankID(connectionID))" }

    /// The link id inside a bank's row id; any other id unchanged. An app that sends a row id back gets the link.
    static func linkID(fromRowID id: String) -> String { id.firstIndex(of: "~").map { String(id[..<$0]) } ?? id }

    static func ledgerID(_ externalID: String) -> String { SimpleFINSource.ledgerAccountID(externalID) }

    /// Requests in the rolling 24 hours, for the dashboard's "Requests today: N of 20".
    func requestsToday(now: Date) -> Int { SimpleFINBudget.recent(requests, now: now).count }

    /// The banks in name order.
    var sortedConnections: [(id: String, state: SimpleFINConnectionState)] {
        connections.map { (id: $0.key, state: $0.value) }.sorted { ($0.state.name, $0.id) < ($1.state.name, $1.id) }
    }

    /// Each bank behind the link, for the dashboard; nil until the first pull since 0.6.0 names them.
    func banksSummary() -> [LinkBank]? {
        guard !connections.isEmpty else { return nil }
        return sortedConnections.map { id, bank in
            LinkBank(id: Self.bankID(id), name: bank.name, status: bank.status, errorKind: bank.status == .needsReauth ? .needsSignIn : nil,
                     lastGoodAt: bank.lastGoodData, accountIDs: bank.accountIDs.map(Self.ledgerID))
        }
    }

    /// The rows Settings → Accounts lists for this link: one per bank, so the phone (even an app from before 0.6.0) names
    /// the bank that needs a sign-in, and the others read as syncing. Before the banks are known, and while SimpleFIN
    /// refuses the whole link (a new setup token fixes that, on the dashboard), the link itself.
    static func institutionRows(_ link: StoredLink, base: InstitutionLink, accounts: [Account]) -> [InstitutionLink] {
        guard let state = link.simplefin, !state.connections.isEmpty, link.status != .needsReauth else {
            var row = base
            row.reconnect = link.status == .needsReauth ? .dashboard : nil
            return [row]
        }
        let known = Set(accounts.map(\.id))
        return state.sortedConnections.map { id, bank in
            var row = base
            row.id = rowID(linkID: link.id, connectionID: id)
            row.institution = bank.name
            row.syncLinkID = link.id
            row.reconnect = .providerSite
            row.accountIDs = bank.accountIDs.map(ledgerID).filter(known.contains)
            row.lastSync = bank.lastGoodData ?? base.lastSync
            if bank.status == .needsReauth {
                row.status = .needsReauth
                row.errorKind = .needsSignIn
                row.failingSince = bank.firstFailedAt
                row.reconnectURL = bridgeURL
                row.lastError = bank.lastMessage ?? "\(bank.name) needs you to sign in again on SimpleFIN Bridge."
                row.note = "\(bank.name) needs you to sign in again on SimpleFIN Bridge. Nothing new comes in from \(bank.name) until then; your other banks keep syncing."
            }
            return row
        }
    }
}
