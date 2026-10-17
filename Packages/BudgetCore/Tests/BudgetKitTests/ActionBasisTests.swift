import Foundation
import Testing
@testable import BudgetKit

/// An Ask proposal carries a fingerprint of what it reaches; applying it is refused when that changed since (P1.4).
@Suite("Stale-proof proposals")
struct ActionBasisTests {
    static func ledger() -> Ledger { Fixture.ledger() }

    /// A merchant with more than a handful of rows, so a rule on it needs a review first.
    static func busyMerchant(_ ledger: Ledger) throws -> String {
        let counts = Dictionary(grouping: ledger.transactions.filter { !$0.isPending }, by: \.merchant).mapValues(\.count)
        return try #require(counts.filter { $0.value > ProposedAction.reviewAbove }.keys.sorted().first)
    }

    static func rule(_ merchant: String, _ categoryID: String = "shopping") -> AppAction {
        .createBudgetRule(CreateBudgetRule(match: RuleMatch(merchantContains: merchant), categoryID: categoryID, applyToExisting: true))
    }

    /// A copy of `row` under a new id: a new match arriving.
    static func arrival(_ row: LedgerTransaction, id: String) -> LedgerTransaction {
        var copy = row
        copy.id = id
        copy.postedAt = row.postedAt.addingTimeInterval(3600)
        return copy
    }

    @Test("A new row elsewhere and another row re-filed leave the fingerprint unchanged")
    func basisStableAcrossUnrelatedChange() throws {
        var ledger = Self.ledger()
        let merchant = try Self.busyMerchant(ledger)
        let reached = ledger.transactions.filter { $0.merchant == merchant }.prefix(2).map(\.id)
        let action = AppAction.recategorize(Recategorize(transactionIDs: reached, categoryID: "shopping"))
        let before = try #require(try ledger.basis(for: action))
        #expect(before.rowCount == 2 && before.fingerprint.hasPrefix("v1:") && before.fingerprint.count == 35)

        let other = try #require(ledger.transactions.firstIndex { $0.merchant != merchant })
        ledger.transactions.append(Self.arrival(ledger.transactions[other], id: "new-elsewhere"))
        ledger.transactions[other].categorization = Categorization(categoryID: "travel", confidence: 1, tier: .user, needsReview: false)
        ledger.transactions[other].note = "changed"
        #expect(try ledger.basis(for: action) == before)
    }

    @Test("Re-filing, hiding or renaming a reached row changes the fingerprint")
    func basisChangesWhenReachedRowRecategorized() throws {
        let ledger = Self.ledger()
        let merchant = try Self.busyMerchant(ledger)
        let index = try #require(ledger.transactions.firstIndex { $0.merchant == merchant })
        let action = AppAction.recategorize(Recategorize(transactionIDs: [ledger.transactions[index].id], categoryID: "shopping"))
        let before = try #require(try ledger.basis(for: action))

        var refiled = ledger
        refiled.transactions[index].categorization = Categorization(categoryID: "travel", confidence: 1, tier: .user, needsReview: false)
        #expect(try refiled.basis(for: action) != before)
        var hidden = ledger
        hidden.transactions[index].isHidden.toggle()
        #expect(try hidden.basis(for: action) != before)
        var renamed = ledger
        renamed.transactions[index].merchant = "Someone else"
        #expect(try renamed.basis(for: action) != before)
    }

    @Test("A target change is relative, so a changed target changes its fingerprint; spending alone doesn't")
    func adjustTargetBasisChangesWhenTargetChanged() throws {
        var ledger = Self.ledger()
        let action = AppAction.adjustCategoryTarget(AdjustCategoryTarget(categoryID: "dining", change: DecimalAmount(string: "50")!))
        let before = try #require(try ledger.basis(for: action))
        #expect(before.rowCount == 0)

        let dining = try #require(ledger.transactions.first { $0.categorization?.categoryID == "dining" })
        ledger.transactions.append(Self.arrival(dining, id: "new-dinner"))
        #expect(try ledger.basis(for: action) == before)

        ledger.monthlyTargets["dining"] = (ledger.monthlyTargets["dining"] ?? .zero) + Money(25)
        #expect(try ledger.basis(for: action) != before)
    }

    @Test("A rule's fingerprint changes when a new match arrives, and counts it")
    func ruleBasisChangesWhenNewMatchArrives() throws {
        var ledger = Self.ledger()
        let merchant = try Self.busyMerchant(ledger)
        let action = Self.rule(merchant)
        let before = try #require(try ledger.basis(for: action))
        #expect(try before.rowCount == ledger.reachedRows(action).count)
        #expect(try before.rowCount == ledger.preview(action).matchCount)

        let match = try #require(ledger.transactions.first { $0.merchant == merchant })
        ledger.transactions.append(Self.arrival(match, id: "new-match"))
        let after = try #require(try ledger.basis(for: action))
        #expect(after != before)
        #expect(after.rowCount == before.rowCount + 1)
    }

    @Test("Navigating and remembering reach nothing, so they have no basis")
    func navigateHasNoBasis() throws {
        let ledger = Self.ledger()
        #expect(try ledger.basis(for: .navigate(Navigate(screen: .home))) == nil)
        #expect(try ledger.basis(for: .rememberFact(RememberFact(fact: "Saving for a trip"))) == nil)
        #expect(try ledger.reachedRows(.navigate(Navigate(screen: .home))).isEmpty)
    }

    @Test("A row that's gone is not found")
    func missingRowIsNotFound() {
        #expect(throws: BudgetAPIError.notFound) {
            try Self.ledger().basis(for: .recategorize(Recategorize(transactionIDs: ["no-such-row"], categoryID: "dining")))
        }
    }

    @Test("The same ledger always gives the same fingerprint")
    func basisIsDeterministic() throws {
        let action = Self.rule(try Self.busyMerchant(Self.ledger()))
        #expect(try Self.ledger().basis(for: action) == Self.ledger().basis(for: action))
    }

    @Test("Above five rows a proposal carries its count and a sample in words; at five or fewer, the count alone")
    func proposalCarriesCountAndSample() async throws {
        let ledger = Self.ledger()
        let merchant = try Self.busyMerchant(ledger)
        let toolbox = DemoToolbox(ledger: ledger, decisions: nil)
        let busy = try await toolbox.propose(Self.rule(merchant))
        let preview = try ledger.preview(Self.rule(merchant))
        #expect(busy.basis == (try ledger.basis(for: Self.rule(merchant)))?.fingerprint)
        #expect(busy.basis != nil)
        #expect(busy.matchCount == preview.matchCount)
        #expect(busy.needsReview)
        let sample = try #require(busy.sample)
        #expect(sample.count == min(preview.matchCount ?? 0, ActionPreview.sampleSize))
        #expect(sample.allSatisfy { $0.contains(" · \(merchant) · ") && $0.contains("$") })

        let id = try #require(ledger.transactions.first?.id)
        let one = try await toolbox.propose(.recategorize(Recategorize(transactionIDs: [id], categoryID: "shopping")))
        #expect(one.matchCount == 1 && one.sample == nil && !one.needsReview && one.basis != nil)
        let open = try await toolbox.propose(.navigate(Navigate(screen: .home)))
        #expect(open.basis == nil && !open.needsReview)
    }

    @Test("Built-in answers carry the basis too: of two caps proposed, applying one makes the other stale until refreshed")
    func builtInAnswersCarryBasis() async throws {
        let api = Fixture.api()
        let first = try #require(try await api.ask("Cap DoorDash at $150", conversationID: nil).proposedActions.first)
        let second = try #require(try await api.ask("Cap DoorDash at $200", conversationID: nil).proposedActions.first)
        let basis = try #require(first.basis)
        #expect(second.basis == basis)  // both read the same cap: none yet

        _ = try await api.perform(second.action, basis: second.basis)
        do {
            _ = try await api.perform(first.action, basis: basis)
            Issue.record("a stale cap applied")
        } catch let BudgetAPIError.server(status, _) {
            #expect(status == 409)
        }
        let refreshed = ProposedAction(id: first.id, action: first.action, preview: try await api.preview(first.action), timeZone: Fixture.calendar.timeZone) { _ in nil }
        #expect(refreshed.basis != basis && refreshed.id == first.id)
        _ = try await api.perform(refreshed.action, basis: refreshed.basis)
    }

    @Test("Applying with a stale basis is refused with a 409 and changes nothing; a current one or none applies")
    func performChecksBasis() async throws {
        let api = Fixture.api()
        let rows = try await api.transactions(TransactionFilter(limit: 2000)).filter { !$0.isPending }
        let counts = Dictionary(grouping: rows, by: \.merchant).mapValues(\.count)
        let merchant = try #require(counts.filter { $0.value > ProposedAction.reviewAbove }.keys.sorted().first)
        let action = Self.rule(merchant)
        let stale = try #require(try await api.preview(action).basis)

        // Between the proposal and the tap, one of its rows is re-filed by hand.
        let row = try #require(rows.first { $0.merchant == merchant })
        _ = try await api.perform(.recategorize(Recategorize(transactionIDs: [row.id], categoryID: "travel")))
        let rulesBefore = try await api.rules().count
        do {
            _ = try await api.perform(action, basis: stale)
            Issue.record("a stale proposal applied")
        } catch let BudgetAPIError.server(status, message) {
            #expect(status == 409)
            #expect(message?.contains("changed since this was proposed") == true)
        }
        #expect(try await api.rules().count == rulesBefore)
        #expect(try await api.transaction(id: row.id).categorization?.categoryID == "travel")

        let current = try #require(try await api.preview(action).basis)
        #expect(current != stale)
        _ = try await api.perform(action, basis: current)
        #expect(try await api.rules().count == rulesBefore + 1)
        _ = try await api.perform(.recategorize(Recategorize(transactionIDs: [row.id], categoryID: "dining")))
        #expect(try await api.transaction(id: row.id).categorization?.categoryID == "dining")
    }
}
