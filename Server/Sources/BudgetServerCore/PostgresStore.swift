import BudgetKit
import Foundation
import Logging
import PostgresNIO

/// Postgres persistence. Rows are one table (indexed, one row per transaction); the rest of the
/// ledger state is a handful of JSONB documents. Saves write only what changed, in one transaction.
public final class PostgresStore: ServerStore, Sendable {
    public let client: PostgresClient
    private let logger: Logger

    /// Storage coding: Foundation's default date strategy round-trips exactly (ISO 8601 drops sub-seconds).
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()

    public init(config: ServerConfig.Database, logger: Logger) {
        self.logger = logger
        client = PostgresClient(configuration: .init(host: config.host, port: config.port, username: config.username,
                                                     password: config.password, database: config.database, tls: .disable),
                                backgroundLogger: logger)
    }

    static let migrations: [String] = [
        """
        CREATE TABLE IF NOT EXISTS budget_rows (
            id TEXT PRIMARY KEY, account_id TEXT NOT NULL, posted_at TIMESTAMPTZ NOT NULL, batch_id TEXT, doc JSONB NOT NULL);
        CREATE INDEX IF NOT EXISTS budget_rows_posted ON budget_rows (posted_at DESC);
        CREATE INDEX IF NOT EXISTS budget_rows_batch ON budget_rows (batch_id);
        CREATE TABLE IF NOT EXISTS budget_docs (key TEXT PRIMARY KEY, doc JSONB NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now());
        CREATE TABLE IF NOT EXISTS budget_links (id TEXT PRIMARY KEY, doc JSONB NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now());
        CREATE TABLE IF NOT EXISTS budget_imports (batch_id TEXT PRIMARY KEY, doc JSONB NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
        """,
        // 2: provider credentials saved from the dashboard (secrets inside are sealed).
        """
        CREATE TABLE IF NOT EXISTS budget_settings (key TEXT PRIMARY KEY, doc JSONB NOT NULL, updated_at TIMESTAMPTZ NOT NULL DEFAULT now());
        """,
        // 3: Ask's conversations, one row per conversation; the list reads `summary` alone (PostgresStore+Chats.swift).
        """
        CREATE TABLE IF NOT EXISTS budget_chats (id TEXT PRIMARY KEY, updated_at TIMESTAMPTZ NOT NULL, summary JSONB NOT NULL, doc JSONB NOT NULL);
        CREATE INDEX IF NOT EXISTS budget_chats_updated ON budget_chats (updated_at DESC);
        """,
        // 4: each account's balance at the end of a day, recorded at sync (net worth history; `PostgresBalanceHistory`).
        """
        CREATE TABLE IF NOT EXISTS budget_balances (
            account_id TEXT NOT NULL, day TEXT NOT NULL, minor BIGINT NOT NULL, currency TEXT NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY (account_id, day));
        """,
    ]

    public func migrate() async throws {
        try await client.query("CREATE TABLE IF NOT EXISTS budget_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)", logger: logger)
        var version = 0
        for try await (value) in try await client.query("SELECT value FROM budget_meta WHERE key = 'schema_version'", logger: logger).decode(String.self) {
            version = Int(value) ?? 0
        }
        for (index, migration) in Self.migrations.enumerated() where index >= version {
            try await client.withConnection { connection in
                try await connection.query("BEGIN", logger: logger)
                do {
                    for statement in migration.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !statement.isEmpty {
                        try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
                    }
                    let next = String(index + 1)
                    try await connection.query("INSERT INTO budget_meta (key, value) VALUES ('schema_version', \(next)) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value", logger: logger)
                    try await connection.query("COMMIT", logger: logger)
                } catch {
                    _ = try? await connection.query("ROLLBACK", logger: logger)
                    throw error
                }
            }
        }
    }

    // MARK: Ledger

    /// Splits a state into (documents without rows, rows by id).
    static func split(_ state: LedgerState) throws -> (docs: [String: JSONValue], rows: [String: LedgerTransaction]) {
        guard case var .object(fields) = try JSONValue.parse(encoder.encode(state)) else { return ([:], [:]) }
        fields["transactions"] = nil
        return (fields, Dictionary(uniqueKeysWithValues: state.transactions.map { ($0.id, $0) }))
    }

    public func loadLedger() async throws -> LedgerState? {
        var docs: [String: JSONValue] = [:]
        for try await (key, doc) in try await client.query("SELECT key, doc::text FROM budget_docs", logger: logger).decode((String, String).self) {
            docs[key] = try JSONValue.parse(Data(doc.utf8))
        }
        guard !docs.isEmpty else { return nil }
        var rows: [JSONValue] = []
        for try await (doc) in try await client.query("SELECT doc::text FROM budget_rows ORDER BY posted_at DESC", logger: logger).decode(String.self) {
            rows.append(try JSONValue.parse(Data(doc.utf8)))
        }
        // Stored documents over the empty ledger's: a document that was never written (a save diffs
        // against a value equal to the default) or a field added in a later version loads as its default.
        var merged = try Self.split(.empty).docs
        merged.merge(docs) { _, stored in stored }
        merged["transactions"] = .array(rows)
        return try Self.decoder.decode(LedgerState.self, from: JSONValue.object(merged).data())
    }

    public func replaceLedger(_ state: LedgerState) async throws {
        try await write { connection in
            try await connection.query("DELETE FROM budget_rows", logger: self.logger)
            try await connection.query("DELETE FROM budget_docs", logger: self.logger)
            let (docs, rows) = try Self.split(state)
            for (key, doc) in docs { try await self.upsertDoc(key, doc, on: connection) }
            for row in rows.values { try await self.upsertRow(row, on: connection) }
        }
    }

    public func save(from old: LedgerState, to new: LedgerState) async throws {
        let (oldDocs, oldRows) = try Self.split(old)
        let (newDocs, newRows) = try Self.split(new)
        let changedDocs = newDocs.filter { oldDocs[$0.key] != $0.value }
        let changedRows = newRows.values.filter { oldRows[$0.id] != $0 }
        let removed = oldRows.keys.filter { newRows[$0] == nil }
        guard !changedDocs.isEmpty || !changedRows.isEmpty || !removed.isEmpty else { return }
        try await write { connection in
            for (key, doc) in changedDocs { try await self.upsertDoc(key, doc, on: connection) }
            for row in changedRows { try await self.upsertRow(row, on: connection) }
            for id in removed { try await connection.query("DELETE FROM budget_rows WHERE id = \(id)", logger: self.logger) }
        }
    }

    private func upsertDoc(_ key: String, _ doc: JSONValue, on connection: PostgresConnection) async throws {
        let json = String(decoding: try doc.data(), as: UTF8.self)
        try await connection.query("""
            INSERT INTO budget_docs (key, doc, updated_at) VALUES (\(key), \(json)::jsonb, now())
            ON CONFLICT (key) DO UPDATE SET doc = EXCLUDED.doc, updated_at = now()
            """, logger: logger)
    }

    private func upsertRow(_ row: LedgerTransaction, on connection: PostgresConnection) async throws {
        let json = String(decoding: try Self.encoder.encode(row), as: UTF8.self)
        try await connection.query("""
            INSERT INTO budget_rows (id, account_id, posted_at, batch_id, doc) VALUES (\(row.id), \(row.accountID), \(row.postedAt), \(row.batchID), \(json)::jsonb)
            ON CONFLICT (id) DO UPDATE SET account_id = EXCLUDED.account_id, posted_at = EXCLUDED.posted_at, batch_id = EXCLUDED.batch_id, doc = EXCLUDED.doc
            """, logger: logger)
    }

    private func write(_ body: @Sendable @escaping (PostgresConnection) async throws -> Void) async throws {
        try await client.withConnection { connection in
            try await connection.query("BEGIN", logger: self.logger)
            do {
                try await body(connection)
                try await connection.query("COMMIT", logger: self.logger)
            } catch {
                _ = try? await connection.query("ROLLBACK", logger: self.logger)
                throw error
            }
        }
    }

    // MARK: Links and imports

    public func links() async throws -> [StoredLink] {
        var out: [StoredLink] = []
        for try await (doc) in try await client.query("SELECT doc::text FROM budget_links ORDER BY updated_at", logger: logger).decode(String.self) {
            out.append(try Self.decoder.decode(StoredLink.self, from: Data(doc.utf8)))
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    public func upsertLink(_ link: StoredLink) async throws {
        let json = String(decoding: try Self.encoder.encode(link), as: UTF8.self)
        try await client.query("""
            INSERT INTO budget_links (id, doc, updated_at) VALUES (\(link.id), \(json)::jsonb, now())
            ON CONFLICT (id) DO UPDATE SET doc = EXCLUDED.doc, updated_at = now()
            """, logger: logger)
    }

    public func deleteLink(_ id: String) async throws {
        try await client.query("DELETE FROM budget_links WHERE id = \(id)", logger: logger)
    }

    public func imports() async throws -> [ImportRecord] {
        var out: [ImportRecord] = []
        for try await (doc) in try await client.query("SELECT doc::text FROM budget_imports ORDER BY created_at DESC", logger: logger).decode(String.self) {
            out.append(try Self.decoder.decode(ImportRecord.self, from: Data(doc.utf8)))
        }
        return out
    }

    public func upsertImport(_ record: ImportRecord) async throws {
        let json = String(decoding: try Self.encoder.encode(record), as: UTF8.self)
        try await client.query("""
            INSERT INTO budget_imports (batch_id, doc, created_at) VALUES (\(record.batchID), \(json)::jsonb, \(record.createdAt))
            ON CONFLICT (batch_id) DO UPDATE SET doc = EXCLUDED.doc
            """, logger: logger)
    }

    public func clearImports() async throws {
        try await client.query("DELETE FROM budget_imports", logger: logger)
    }

    // MARK: Settings

    public func setting(_ key: String) async throws -> Data? {
        for try await (doc) in try await client.query("SELECT doc::text FROM budget_settings WHERE key = \(key)", logger: logger).decode(String.self) {
            return Data(doc.utf8)
        }
        return nil
    }

    public func saveSetting(_ key: String, _ document: Data) async throws {
        let json = String(decoding: document, as: UTF8.self)
        try await client.query("""
            INSERT INTO budget_settings (key, doc, updated_at) VALUES (\(key), \(json)::jsonb, now())
            ON CONFLICT (key) DO UPDATE SET doc = EXCLUDED.doc, updated_at = now()
            """, logger: logger)
    }
}
