import BudgetKit
import Crypto
import Foundation

/// Seals provider access tokens at rest (AES-256-GCM). Tokens are only unsealed in memory to call a provider.
public struct TokenSealer: Sendable {
    private let key: SymmetricKey

    public init(base64Key: String) throws {
        guard let data = Data(base64Encoded: base64Key), data.count == 32 else {
            throw ServerConfig.ConfigError.invalid("BUDGET_TOKEN_KEY must be base64 of 32 random bytes (openssl rand -base64 32)")
        }
        key = SymmetricKey(data: data)
    }

    public func seal(_ secret: String) throws -> String {
        guard let combined = try AES.GCM.seal(Data(secret.utf8), using: key).combined else { throw ServerConfig.ConfigError.invalid("seal failed") }
        return combined.base64EncodedString()
    }

    public func open(_ sealed: String) throws -> String {
        guard let data = Data(base64Encoded: sealed) else { throw ServerConfig.ConfigError.invalid("sealed token is not base64") }
        return String(decoding: try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key), as: UTF8.self)
    }
}

/// A connection to a provider: a Plaid Item, a Teller enrollment, a SimpleFIN access URL.
public struct StoredLink: Codable, Hashable, Sendable {
    public var id: String
    public var provider: SourceKind
    public var institution: String
    /// Provider-side id (Plaid item_id, Teller enrollment id).
    public var externalID: String?
    /// The access token (or SimpleFIN access URL), sealed with `TokenSealer`.
    public var sealedToken: String
    /// Plaid `/transactions/sync` cursor.
    public var cursor: String?
    public var status: ConnectionStatus
    public var lastSync: Date?
    public var lastError: String?
    public var createdAt: Date
    /// The last card-bill check (Plaid Liabilities) on this Item; nil until one ran.
    public var cardBills: CardBillCheck? = nil

    /// What clients may see — never the token.
    public var summary: LinkSummary {
        LinkSummary(id: id, provider: provider, institution: institution, status: status, lastSync: lastSync, lastError: lastError, createdAt: createdAt,
                    externalID: externalID, cardBills: cardBills)
    }
}

public struct LinkSummary: Codable, Hashable, Sendable {
    public var id: String
    public var provider: SourceKind
    public var institution: String
    public var status: ConnectionStatus
    public var lastSync: Date?
    /// Why the latest sync failed, in the provider's words; nil once one succeeds.
    public var lastError: String?
    public var createdAt: Date
    /// The provider's own id for the connection (Plaid item_id, Teller enrollment id — Teller Connect needs it to
    /// reconnect). Not a credential.
    public var externalID: String?
    /// Whether this Item gives card bills, as last checked; nil until checked (or for links that aren't Plaid's).
    public var cardBills: CardBillCheck? = nil
}

/// One ingest (sync or file) — the unit of rollback.
public struct ImportRecord: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case sync, file }
    public var batchID: String
    public var kind: Kind
    public var linkID: String?
    public var label: String
    public var report: IngestReport
    public var createdAt: Date
    public var rolledBack: Bool
}

/// Persistence for everything the server keeps.
public protocol ServerStore: LedgerPersistence {
    func migrate() async throws
    /// Nil when nothing has been saved yet.
    func loadLedger() async throws -> LedgerState?
    func replaceLedger(_ state: LedgerState) async throws
    func links() async throws -> [StoredLink]
    func upsertLink(_ link: StoredLink) async throws
    func deleteLink(_ id: String) async throws
    func imports() async throws -> [ImportRecord]
    func upsertImport(_ record: ImportRecord) async throws
    func clearImports() async throws
    /// Settings saved from the dashboard, one JSON document per key (nil = none saved).
    func setting(_ key: String) async throws -> Data?
    func saveSetting(_ key: String, _ document: Data) async throws
}

extension ServerStore {
    public func providerSettings() async throws -> StoredProviderSettings? {
        try await setting("providers").map { try JSONDecoder().decode(StoredProviderSettings.self, from: $0) }
    }
    public func saveProviderSettings(_ settings: StoredProviderSettings) async throws {
        try await saveSetting("providers", JSONEncoder().encode(settings))
    }
    public func serverSettings() async throws -> StoredServerSettings? {
        try await setting("server").map { try JSONDecoder().decode(StoredServerSettings.self, from: $0) }
    }
    public func saveServerSettings(_ settings: StoredServerSettings) async throws {
        try await saveSetting("server", JSONEncoder().encode(settings))
    }
}

/// In-memory store for local runs and tests.
public actor MemoryStore: ServerStore {
    private var ledger: LedgerState?
    private var linkTable: [String: StoredLink] = [:]
    private var importTable: [String: ImportRecord] = [:]
    private var settings: [String: Data] = [:]
    public private(set) var saveCount = 0

    public init(ledger: LedgerState? = nil) { self.ledger = ledger }

    public func migrate() async throws {}
    public func loadLedger() async throws -> LedgerState? { ledger }
    public func replaceLedger(_ state: LedgerState) async throws { ledger = state }
    public func save(from old: LedgerState, to new: LedgerState) async throws { ledger = new; saveCount += 1 }
    public func links() async throws -> [StoredLink] { linkTable.values.sorted { $0.createdAt < $1.createdAt } }
    public func upsertLink(_ link: StoredLink) async throws { linkTable[link.id] = link }
    public func deleteLink(_ id: String) async throws { linkTable[id] = nil }
    public func imports() async throws -> [ImportRecord] { importTable.values.sorted { $0.createdAt > $1.createdAt } }
    public func upsertImport(_ record: ImportRecord) async throws { importTable[record.batchID] = record }
    public func clearImports() async throws { importTable = [:] }
    public func setting(_ key: String) async throws -> Data? { settings[key] }
    public func saveSetting(_ key: String, _ document: Data) async throws { settings[key] = document }
}
