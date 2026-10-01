import Foundation
import Testing
@testable import BudgetKit

/// The demo ledger carries enough for every Settings screen: account digits, a statement-only card, a connection
/// waiting for a sign-in, rules that disagree, and memory with answers from the person, a rule and the model.
@Suite("Demo showcase")
struct ShowcaseTests {
    @Test("Rules: newest first, the paycheck and Uber rules have filed rows, and the two Uber rules disagree")
    func rules() {
        let ledger = Fixture.ledger()
        let summaries = ledger.ruleSummaries()
        #expect(summaries.map(\.id) == ["rule-3", "rule-2", "rule-1"])
        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let payroll = ledger.transactions.filter { $0.rawDescription == "ACME CORP PAYROLL PPD" }
        #expect(byID["rule-1"]?.hitCount == payroll.count && !payroll.isEmpty)
        #expect((byID["rule-2"]?.hitCount ?? 0) > 0)
        #expect(byID["rule-3"]?.hitCount == 0)
        #expect(byID["rule-3"]?.conflicts == ["rule-2"] && byID["rule-2"]?.conflicts == ["rule-3"])
        #expect(byID["rule-1"]?.conflicts.isEmpty == true)
        #expect(summaries.allSatisfy { !$0.isDead && $0.rule.isEnabled })
        #expect(byID["rule-2"]?.rule.createdBy == .assistant)
    }

    @Test("Accounts: every one shows its last digits; Keystone comes from statements; Tidewater waits for a sign-in")
    func accounts() async throws {
        let api = Fixture.api()
        let overview = try await api.overview()
        #expect(overview.accounts.allSatisfy { $0.mask != nil })
        let status = try await api.serverStatus()
        let keystone = try #require(status.institutions.first { $0.institution == "Keystone" })
        #expect(keystone.primary == .fileImport && keystone.accountIDs == [Ledger.keystoneCardID] && keystone.coversThrough != nil)
        let tidewater = try #require(status.institutions.first { $0.institution == "Tidewater" })
        #expect(tidewater.status == .needsReauth && tidewater.lastError != nil)
        #expect(tidewater.lastSync.map { Fixture.now.timeIntervalSince($0) > 7 * 86_400 } == true)
        // Only a placeholder for apps before 0.2.0, which can't read a link without one; nothing shows it.
        #expect(status.institutions.allSatisfy { $0.priority == .core })
        // The Keystone payment is a transfer: it counts nowhere.
        let keystoneRows = try await api.transactions(TransactionFilter(accountIDs: [Ledger.keystoneCardID]))
        #expect(keystoneRows.count == 1 && keystoneRows[0].categorization?.categoryID == "transfer")
    }

    @Test("Memory knows where each answer came from: you, a rule, the model, or memory itself")
    func memorySources() {
        let entries = Fixture.ledger().merchantMemoryEntries()
        let source = Dictionary(entries.map { ($0.merchant, $0.source) }, uniquingKeysWith: { first, _ in first })
        #expect(source["DoorDash"] == .user && source["Trader Joe's"] == .user && source["Target"] == .user)
        #expect(source["Olive Grill"] == .decisionModel && source["Uniqlo"] == .decisionModel)
        #expect(source["Uber"] == .rule && source["Acme Corp"] == .rule)
        #expect(entries.first { $0.merchant == "Olive Grill" }?.confidence == 0.93)
        #expect(source["Netflix"] == .merchantMemory)
    }
}
