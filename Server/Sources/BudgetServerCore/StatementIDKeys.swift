import BudgetKit
import Crypto
import Foundation

/// The key that makes statement ids unreadable (account numbers never in an id), derived from `BUDGET_TOKEN_KEY`.
enum StatementIDKeys {
    static let info = "budget statement ids v1"
    /// `budget_settings` key of the check value (`StatementIDs.checkValue`) of the key ids were first made with.
    static let checkSetting = "statementIDs"

    /// HMAC-SHA256 under a key HKDF derives from `BUDGET_TOKEN_KEY`, so someone holding a dump (or an id) without
    /// budget.env can't try account numbers against it. Without that key, a server that keeps nothing (tests, the demo)
    /// uses a key of its own for the process; one with Postgres gets none, and refuses OFX and QFX files. The ids' gate
    /// starts closed: `LedgerMigrations` opens it once the ledger's own ids are upgraded.
    static func make(sealer: TokenSealer?, persistent: Bool) -> StatementIDs? {
        let key: SymmetricKey
        if let sealer {
            key = sealer.derivedKey(info: info)
        } else if !persistent {
            key = SymmetricKey(size: .bits256)
        } else {
            return nil
        }
        return StatementIDs(digest: { text in
            HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key).map { String(format: "%02x", $0) }.joined()
        }, gate: StatementIDs.Gate(isOpen: false))
    }

    struct Check: Codable { var check: String }

    // MARK: Scrubbing what's kept outside the ledger

    /// A conversation's stored JSON with every old id swapped for its new one, and any number left in a legacy statement
    /// id ("fileImport:<ACCTID>", "ofx-<ACCTID>-<FITID>") masked. New ids ("ofxh1-…", "stmt-h1-…") are never touched,
    /// so running it again changes nothing.
    static func scrubChat(_ text: String, accounts: [String: String] = [:], rows: [String: String] = [:]) -> String {
        guard text.contains("fileImport:") || text.contains("ofx-") else { return text }
        // Longest first, so a row id's account prefix isn't swapped before the row id itself.
        let prefixes = accounts.keys.sorted { $0.count > $1.count }
        let rowPrefix = SourceKind.fileImport.rawValue + ":"
        return text.replacing(/(?:fileImport:|ofx-)[^\s"\\,]*/) { match -> String in
            var token = String(match.output)
            if let new = rows[token] ?? accounts[token] {
                token = new
            } else if let old = prefixes.first(where: { token.hasPrefix(rowPrefix + $0 + ":") }), let new = accounts[old] {
                // A row of a renamed account that isn't in the ledger any more ("fileImport:<account>:…").
                token = rowPrefix + new + token.dropFirst(rowPrefix.count + old.count)
            }
            return maskLegacySegments(token)
        }
    }

    /// In "fileImport:fileImport:9876543210123:ofx-9876543210123-F1", the number segment and the "ofx-" segment.
    static func maskLegacySegments(_ token: String) -> String {
        token.split(separator: ":", omittingEmptySubsequences: false).map { segment -> String in
            let s = String(segment)
            if s.hasPrefix("ofx-") { return StatementIDs.maskNumbers(s) }
            if s.count >= 6, s.allSatisfy({ $0.isASCII && $0.isNumber }) { return StatementIDs.maskNumbers(s) }
            return s
        }.joined(separator: ":")
    }

    /// An import record with numbers masked in what's free text: its label (the file name) and its warnings and notes.
    static func scrubImport(_ record: ImportRecord) -> ImportRecord {
        var record = record
        record.label = StatementIDs.maskNumbers(record.label)
        record.report.warnings = record.report.warnings.map(StatementIDs.maskNumbers)
        record.report.notes = record.report.notes?.map(StatementIDs.maskNumbers)
        return record
    }
}
