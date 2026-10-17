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

    /// A 32-byte key for one purpose (`info` names it), derived from the sealing key with HKDF-SHA256, so the sealing key
    /// itself never leaves this type and each purpose gets a key of its own.
    public func derivedKey(info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data(info.utf8), outputByteCount: 32)
    }
}

/// A connection to a provider: a Plaid Item or a SimpleFIN access URL. (A Teller enrollment stored before 0.6.0 still
/// decodes, as `SourceKind.teller`; it can only be removed.)
public struct StoredLink: Codable, Hashable, Sendable {
    public var id: String
    public var provider: SourceKind
    public var institution: String
    /// Provider-side id (Plaid item_id).
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
    // 0.6.0. Every new field is optional: links are stored whole as JSON, and a stored doc without a key must decode.
    /// What the last failure was, provider-agnostic; nil while healthy.
    public var errorKind: LinkErrorKind? = nil
    /// The provider's code: "ITEM_LOCKED", "con.auth", "http-403".
    public var errorCode: String? = nil
    /// Plaid's request_id for the failing call; safe to log and show.
    public var errorRequestID: String? = nil
    /// The start of the current run of failures.
    public var firstFailedAt: Date? = nil
    /// Failures in a row; nil or 0 while healthy.
    public var failureCount: Int? = nil
    public var lastAttemptAt: Date? = nil
    /// Scheduled and webhook runs wait until then; the person asking doesn't.
    public var nextAttemptAt: Date? = nil
    /// Plaid's own state for this Item (`PlaidLinkState.swift`).
    public var plaid: PlaidLinkState? = nil
    /// SimpleFIN's own state for this link (`SimpleFINLinkState.swift`).
    public var simplefin: SimpleFINLinkState? = nil
    /// The last holdings check on this Item; nil until one ran.
    public var holdings: HoldingsCheck? = nil

    /// What clients may see — never the token.
    public var summary: LinkSummary {
        var summary = LinkSummary(id: id, provider: provider, institution: institution, status: status, lastSync: lastSync, lastError: lastError,
                                  createdAt: createdAt, externalID: externalID, cardBills: cardBills)
        summary.errorKind = errorKind
        summary.errorCode = errorCode
        summary.errorRequestID = errorRequestID
        summary.firstFailedAt = firstFailedAt
        summary.failureCount = failureCount
        summary.lastAttemptAt = lastAttemptAt
        summary.nextAttemptAt = nextAttemptAt
        summary.holdings = holdings
        plaid?.summaryFields(into: &summary, liveItem: hasLiveItem)
        summary.banks = simplefin?.banksSummary()
        summary.requestsToday = simplefin?.requestsToday(now: Date())  // [lane S] SimpleFIN's daily budget
        return summary
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
    /// The provider's own id for the connection (Plaid item_id). Not a credential.
    public var externalID: String?
    /// Whether this Item gives card bills, as last checked; nil until checked (or for links that aren't Plaid's).
    public var cardBills: CardBillCheck? = nil
    // 0.6.0, so the dashboard never parses `lastError` again. All nil from older servers.
    public var errorKind: LinkErrorKind? = nil
    public var errorCode: String? = nil
    public var errorRequestID: String? = nil
    public var firstFailedAt: Date? = nil
    public var failureCount: Int? = nil
    public var lastAttemptAt: Date? = nil
    public var nextAttemptAt: Date? = nil
    /// Plaid's institution id (`ins_…`), so the dashboard can refuse a second Item at a bank already linked.
    public var institutionID: String? = nil
    /// When the bank's consent runs out (Plaid).
    public var consentExpiresAt: Date? = nil
    /// The last daily Item check (Plaid `/item/get`).
    public var lastItemCheckAt: Date? = nil
    public var webhook: LinkWebhookStatus? = nil
    /// Each bank behind an aggregator link (SimpleFIN).
    public var banks: [LinkBank]? = nil
    public var reconnect: ReconnectMethod? = nil
    /// Provider requests in the last 24 hours (SimpleFIN's daily budget).
    public var requestsToday: Int? = nil
    public var holdings: HoldingsCheck? = nil
}

/// Whether Plaid's webhooks reach this server for an Item.
public struct LinkWebhookStatus: Codable, Hashable, Sendable {
    /// The URL last registered with Plaid.
    public var url: String?
    public var acknowledgedAt: Date?
    public var lastReceivedAt: Date?
    /// Type and code only ("TRANSACTIONS/SYNC_UPDATES_AVAILABLE"), never the payload.
    public var lastCode: String?

    public init(url: String? = nil, acknowledgedAt: Date? = nil, lastReceivedAt: Date? = nil, lastCode: String? = nil) {
        self.url = url; self.acknowledgedAt = acknowledgedAt; self.lastReceivedAt = lastReceivedAt; self.lastCode = lastCode
    }
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
    /// Nil (an older record) reads as `.ok`.
    public var outcome: ImportOutcome? = nil
    /// A failed sync, in words the person can read.
    public var error: String? = nil
    public var errorKind: LinkErrorKind? = nil
    /// What Undo may do with this batch. Never trusted from storage: `annotated()` sets it on every read.
    public var undo: UndoPolicy? = nil
    /// When the person hid the batch's rows instead of undoing it.
    public var hiddenAt: Date? = nil

    /// The record as read routes return it, with `undo` worked out now.
    public func annotated() -> ImportRecord {
        var record = self
        record.undo = ImportUndo.policy(for: self)
        return record
    }
}

/// How an ingest went. Tolerant: unknown reads as `.ok`.
public enum ImportOutcome: String, Codable, Hashable, Sendable {
    case ok, warning, failed

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .ok
    }
}

/// What Undo may do with a batch, and why.
public struct UndoPolicy: Codable, Hashable, Sendable {
    /// Tolerant: unknown reads as `.refused`, the safe answer.
    public enum Mode: String, Codable, Hashable, Sendable {
        case allowed, warn, refused

        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .refused
        }
    }

    public var mode: Mode
    /// The reason (refused), or what to warn about (warn).
    public var message: String?

    public init(mode: Mode, message: String? = nil) { self.mode = mode; self.message = message }
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
    /// Deletes these import records (only the history entry; rows are never touched). Used to prune sync records that
    /// wrote no rows (`LinkHealthBook.prunableSyncRecords`).
    func deleteImports(_ batchIDs: [String]) async throws
    /// Settings saved from the dashboard, one JSON document per key (nil = none saved).
    func setting(_ key: String) async throws -> Data?
    func saveSetting(_ key: String, _ document: Data) async throws
}

extension ServerStore {
    /// A store that can't delete history entries keeps them (pruning is housekeeping, never correctness).
    public func deleteImports(_ batchIDs: [String]) async throws {}

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
    /// The saved models and picks: a row of their own, which a 0.5.0 server never rewrites.
    public func modelSettings() async throws -> StoredModelSettings? {
        try await setting("models").map { try JSONDecoder().decode(StoredModelSettings.self, from: $0) }
    }
    public func saveModelSettings(_ settings: StoredModelSettings) async throws {
        try await saveSetting("models", JSONEncoder().encode(settings))
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
    public func deleteImports(_ batchIDs: [String]) async throws { for id in batchIDs { importTable[id] = nil } }
    public func setting(_ key: String) async throws -> Data? { settings[key] }
    public func saveSetting(_ key: String, _ document: Data) async throws { settings[key] = document }
}
