import Foundation
import Testing
@testable import BudgetKit

/// P1.3's decision rule on a synthetic card (made-up merchants): one clear candidate is a match, candidates the wording
/// can't tell apart are ambiguous (added and asked about), and a decisive wording settles it.
@Suite("Dedupe decisions")
struct DedupeTests {
    static let monday = FileImport.day(2026, 9, 21)!
    static func day(_ offset: Int) -> Date { Fixture.calendar.date(byAdding: .day, value: offset, to: monday)! }

    static func row(_ id: String, _ description: String, merchant: String? = nil, _ amount: Decimal, on date: Date,
                    source: SourceKind = .plaid) -> LedgerTransaction {
        LedgerTransaction(id: id, accountID: "card", postedAt: date, merchant: merchant ?? description, rawDescription: description,
                          amount: Money(amount), categorization: nil, isPending: false, source: source)
    }

    static func decide(_ descriptions: [String], _ amount: Decimal, on date: Date, in rows: [LedgerTransaction], similarOnly: Bool = false) -> DedupeDecision {
        Deduplicator.decide(account: "card", date: date, amount: Money(amount), descriptions: descriptions, in: rows, similarOnly: similarOnly)
    }

    @Test("A single same-day candidate with no shared words is a match (the AMC case)")
    func singleCandidate() {
        let rows = [Self.row("p-amc", "AMC Theatres", -23.45, on: Self.monday)]
        #expect(Self.decide(["AplPay AMC 0001 EXAMPLE"], -23.45, on: Self.monday, in: rows) == .match(0))
        #expect(Self.decide(["Popcorn Palace"], -23.45, on: Self.monday, in: rows) == .match(0))
    }

    @Test("Two same-day, same-amount rows a generic descriptor can't tell apart are ambiguous")
    func genericIsAmbiguous() {
        let rows = [Self.row("p-deli", "Corner Deli", -15, on: Self.monday), Self.row("p-park", "Harbor Parking", -15, on: Self.monday)]
        guard case let .ambiguous(indices) = Self.decide(["PURCHASE AUTHORIZED ON 09/21"], -15, on: Self.monday, in: rows) else {
            Issue.record("expected ambiguous"); return
        }
        #expect(Set(indices) == [0, 1])
        // The old single pick still names the first, for callers that only want an index.
        #expect(Deduplicator.bestMatch(account: "card", date: Self.monday, amount: Money(-15), descriptions: ["PURCHASE AUTHORIZED ON 09/21"], in: rows) == 0)
    }

    @Test("SHELL OIL against Shell and Trader Joe's matches Shell")
    func decisiveWording() {
        let rows = [Self.row("p-tj", "Trader Joe's", -40, on: Self.monday), Self.row("p-shell", "Shell", -40, on: Self.monday)]
        #expect(Self.decide(["SHELL OIL 5741"], -40, on: Self.monday, in: rows) == .match(1))
    }

    @Test("Monday's coffee matches Monday's, not Wednesday's identical one")
    func nearestOfIdentical() {
        let rows = [Self.row("p-wed", "Blue Bottle Coffee", -6.5, on: Self.day(2)), Self.row("p-mon", "Blue Bottle Coffee", -6.5, on: Self.monday)]
        #expect(Self.decide(["BLUE BOTTLE COFFEE"], -6.5, on: Self.monday, in: rows) == .match(1))
    }

    @Test("Twin coffees on both sides pair one for one")
    func twinsPairOneForOne() {
        var rows = [Self.row("p-1", "Blue Bottle Coffee", -6.5, on: Self.monday), Self.row("p-2", "Blue Bottle Coffee", -6.5, on: Self.monday)]
        var matched: [String] = []
        for _ in 0..<2 {
            guard case let .match(i) = Self.decide(["BLUE BOTTLE COFFEE"], -6.5, on: Self.monday, in: rows) else { Issue.record("expected a match"); return }
            matched.append(rows.remove(at: i).id)
        }
        #expect(matched == ["p-1", "p-2"])
        #expect(Self.decide(["BLUE BOTTLE COFFEE"], -6.5, on: Self.monday, in: rows) == DedupeDecision.none)
    }

    @Test("A card credit four days late with near-identical wording is a match")
    func lateCredit() {
        let rows = [Self.row("p-lulu", "Platinum Lululemon Credit", 75, on: Self.day(4))]
        #expect(Self.decide(["Platinum Lululemon Credit"], 75, on: Self.monday, in: rows) == .match(0))
        // Without the wording it's too far for the any-wording rule.
        #expect(Self.decide(["Store Refund"], 75, on: Self.monday, in: rows) == DedupeDecision.none)
    }

    @Test("similarOnly: an unclear pair is ambiguous and the sweep leaves it; no shared words is no candidate at all")
    func similarOnly() {
        // Each shares two words of four with the file row (0.5): similar enough, but neither ahead of the other.
        let rows = [Self.row("p-a", "Corner Market Downtown", -9, on: Self.day(1)), Self.row("p-b", "Corner Market Uptown", -9, on: Self.day(2))]
        guard case .ambiguous = Self.decide(["Corner Market Midtown"], -9, on: Self.monday, in: rows, similarOnly: true) else {
            Issue.record("expected ambiguous"); return
        }
        let unrelated = [Self.row("p-c", "Harbor Parking", -9, on: Self.monday)]
        #expect(Self.decide(["Corner Deli"], -9, on: Self.monday, in: unrelated, similarOnly: true) == DedupeDecision.none)
        #expect(Self.decide(["Corner Deli"], -9, on: Self.monday, in: unrelated) == .match(0))

        // The after-the-fact sweep pairs nothing here and counts the one it left.
        var state = LedgerState.empty
        state.accounts = [Account(id: "card", name: "Card", institution: "Harbor", kind: .credit, balance: .zero, source: .plaid)]
        state.transactions = rows + [Self.row("f-1", "Corner Market Midtown", -9, on: Self.monday, source: .fileImport)]
        let ledger = Ledger(state: state, now: Fixture.now, calendar: Fixture.calendar)
        let sweep = ledger.crossSourceSweep()
        #expect(sweep.pairs.isEmpty && sweep.ambiguous == 1)
    }
}
