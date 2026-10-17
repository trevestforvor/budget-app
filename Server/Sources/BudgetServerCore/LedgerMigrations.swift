import BudgetKit
import Foundation

/// One-time ledger migrations that need the server (keys, the balance history), run by `prepare` after the ledger loads
/// and before anything syncs. Never throws: a failure must not stop the server from starting; each migration handles and
/// logs its own. Skipped when `ledgerInSync` is false (saving the loaded ledger failed, so memory and Postgres differ).
enum LedgerMigrations {
    /// `BUDGET_STATEMENT_ID_MIGRATION`: `audit` counts what the statement-id upgrade would rename, logs it and serves it at
    /// `GET /dash/maintenance/statement-ids`, but changes nothing (OFX imports stay off). Anything else migrates.
    enum StatementIDMode: Sendable { case migrate, audit }

    /// Tests set the mode for one `prepare` without touching the process environment.
    @TaskLocal static var statementIDModeOverride: StatementIDMode?

    static var statementIDMode: StatementIDMode {
        statementIDModeOverride ?? (ProcessInfo.processInfo.environment["BUDGET_STATEMENT_ID_MIGRATION"]?.lowercased() == "audit" ? .audit : .migrate)
    }

    static func run(_ service: BudgetService, ledgerInSync: Bool) async {
        await statementIDs(service, ledgerInSync: ledgerInSync, mode: statementIDMode)
    }

    // MARK: Statement ids (P0.6)

    /// Takes account numbers out of statement ids, then out of chats and import labels, and only then lets OFX imports
    /// in (`StatementIDs.gate`). It runs whenever the audit finds a legacy id, not just the first time: an older server
    /// still running during a deploy can write legacy ids back (its whole `accounts` document), and running it again is
    /// safe. Any failure leaves the gate closed until a restart gets through.
    static func statementIDs(_ service: BudgetService, ledgerInSync: Bool, mode: StatementIDMode) async {
        let log = service.logger
        let audit = await service.api.statementIDAudit()
        guard let ids = service.statementIDs else {
            if !audit.isClean {
                log.warning("statement ids: \(audit.accounts) accounts, \(audit.rows) rows hold account numbers; set BUDGET_TOKEN_KEY to upgrade them")
            }
            return
        }
        let keyChanged = await checkKey(ids, service, save: mode == .migrate)
        guard ledgerInSync else {
            log.error("statement ids: skipped, the upgraded ledger wasn't saved; OFX and QFX imports are off until a restart")
            return
        }
        let (chats, labels) = await outsideCounts(service)
        let counts = "\(audit.accounts) accounts, \(audit.rows) rows, \(audit.rules) rules, \(chats) chats, \(labels) labels"
        if mode == .audit {
            log.notice("statement ids: \(counts) to rename (audit only: nothing changed; OFX and QFX imports are off)")
            return
        }
        var migration: StatementIDMigration?
        if !audit.isClean {
            // The backup a deploy takes is the rollback; this line says what it's about to change.
            log.notice("statement ids: \(counts) to rename")
            do {
                migration = try await service.api.hashStatementIDs(ids)
            } catch {
                log.error("statement ids: the upgrade didn't save, so nothing changed and OFX and QFX imports are off until a restart: \(error)")
                return
            }
            if let r = migration?.report {
                log.notice("statement ids: \(r.accounts) accounts, \(r.rows) rows, \(r.rules) rules renamed\(r.collisions > 0 ? ", \(r.collisions) merged" : "")")
            }
        }
        // The ledger is safe from here, so a scrub that fails is retried at the next start and doesn't keep imports off.
        do {
            let scrubbed = try await service.api.rewriteChats { [accounts = migration?.accountMap ?? [:], rows = migration?.rowMap ?? [:]] in
                StatementIDKeys.scrubChat($0, accounts: accounts, rows: rows)
            }
            if scrubbed > 0 { log.notice("statement ids: \(scrubbed) chats scrubbed") }
            if try await service.store.setting(chatsScrubbed) == nil { try await service.store.saveSetting(chatsScrubbed, Data("true".utf8)) }
        } catch {
            log.error("statement ids: chats weren't scrubbed; tried again at the next start: \(error)")
        }
        do {
            var masked = 0
            for record in try await service.store.imports() {
                let scrubbed = StatementIDKeys.scrubImport(record)
                guard scrubbed != record else { continue }
                try await service.store.upsertImport(scrubbed)
                masked += 1
            }
            if masked > 0 { log.notice("statement ids: \(masked) import labels masked") }
        } catch {
            log.error("statement ids: import labels weren't masked; tried again at the next start: \(error)")
        }
        ids.gate.open(keyChanged: keyChanged)
    }

    /// The `budget_settings` marker set once chats have been scrubbed. Scrubbing runs at every start anyway (it's
    /// cheap and changes nothing the second time); the marker records that it got through once.
    static let chatsScrubbed = "chats-scrubbed-h1"

    /// Whether ids were first made with another key (BUDGET_TOKEN_KEY replaced): older statement rows then match a
    /// re-import by date and amount instead of by id. Saves the check value the first time (`save`). A store that can't be
    /// read answers no.
    static func checkKey(_ ids: StatementIDs, _ service: BudgetService, save: Bool) async -> Bool {
        do {
            if let data = try await service.store.setting(StatementIDKeys.checkSetting) {
                let stored = try JSONDecoder().decode(StatementIDKeys.Check.self, from: data)
                guard stored.check != ids.checkValue else { return false }
                service.logger.warning("statement ids: BUDGET_TOKEN_KEY isn't the one older statement ids were made with; their rows are matched by date and amount")
                return true
            }
            if save { try await service.store.saveSetting(StatementIDKeys.checkSetting, JSONEncoder().encode(StatementIDKeys.Check(check: ids.checkValue))) }
        } catch {
            service.logger.error("statement ids: couldn't read or save the key check: \(error)")
        }
        return false
    }

    /// Conversations and import records that still hold a legacy statement id or a long number, counted.
    static func outsideCounts(_ service: BudgetService) async -> (chats: Int, labels: Int) {
        let chats = (try? await service.api.rewriteChats(dryRun: true) { StatementIDKeys.scrubChat($0) }) ?? 0
        let labels = ((try? await service.store.imports()) ?? []).filter { StatementIDKeys.scrubImport($0) != $0 }.count
        return (chats, labels)
    }

    /// The dry run (`GET /dash/maintenance/statement-ids`): what the upgrade would rename now. Counts only.
    struct StatementIDCounts: Codable, Sendable {
        var accounts: Int
        var rows: Int
        var rules: Int
        var chats: Int
        var labels: Int
        /// Whether OFX and QFX imports are on (the upgrade got through at start).
        var importsOpen: Bool
    }

    static func statementIDCounts(_ service: BudgetService) async -> StatementIDCounts {
        let audit = await service.api.statementIDAudit()
        let (chats, labels) = await outsideCounts(service)
        return StatementIDCounts(accounts: audit.accounts, rows: audit.rows, rules: audit.rules, chats: chats, labels: labels,
                                 importsOpen: service.statementIDs?.gate.isOpen ?? false)
    }
}
