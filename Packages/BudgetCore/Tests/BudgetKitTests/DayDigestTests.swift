import Foundation
import Testing
@testable import BudgetKit

/// The morning summary: the ledger's figures for one day, and the model's retelling of them kept only when it quotes
/// nothing the figures don't hold.
enum DigestFixture {
    static let calendar = Fixture.calendar
    /// The morning after the day summed up.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 9, minute: 30))!

    static func at(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))! }

    static func row(_ id: String, _ merchant: String, _ amount: Decimal, _ category: String, on date: Date, pending: Bool = false) -> LedgerTransaction {
        LedgerTransaction(id: id, accountID: "chk", postedAt: date, merchant: merchant, rawDescription: merchant.uppercased(), amount: Money(amount),
                          categorization: Categorization(categoryID: category, confidence: 0.99, tier: .merchantMemory, needsReview: false),
                          isPending: pending, source: .plaid)
    }

    /// Four weeks of $20 a day at a café, then a Monday with gas, groceries, a pending coffee and the power bill.
    static func state(yesterday: [LedgerTransaction]? = nil) -> LedgerState {
        var state = LedgerState.empty
        state.accounts = [Account(id: "chk", name: "Checking", institution: "Bank", kind: .checking, balance: Money(4_000), source: .plaid)]
        let usual = (1...28).map { back in
            row("cafe-\(back)", "Corner Café", -20, "dining", on: calendar.date(byAdding: .day, value: -back, to: at(9, 28))!)
        }
        // A visit long ago, so the ledger reaches back far enough to call a merchant new.
        let long = row("cafe-old", "Corner Café", -5, "dining", on: calendar.date(byAdding: .day, value: -120, to: at(9, 28))!)
        state.transactions = usual + [long] + (yesterday ?? [
            row("gas", "Shell", -62.10, "transport", on: at(9, 28)),
            row("tj", "Trader Joe's", -44.02, "groceries", on: at(9, 28)),
            row("bb", "Blue Bottle", -6.50, "dining", on: at(9, 28), pending: true),
            row("pge", "City Power", -80, "utilities", on: at(9, 28)),
        ])
        return state
    }

    static func ledger(_ state: LedgerState = state()) -> Ledger { Ledger(state: state, now: now, calendar: calendar) }

    static func api(_ state: LedgerState = state(), model: (any ChatModel)? = nil) -> LedgerBudgetAPI {
        LedgerBudgetAPI(state: state, calendar: calendar, clock: { now }, chatModel: model, decisions: DecisionRouting(), persistence: nil,
                        deployment: DeploymentInfo(endpoint: "t", version: "t", sources: [.plaid], institutions: []))
    }

    static func reply(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, content: text, toolCalls: [], toolCallID: nil) }
}

@Suite("Morning summary")
struct DayDigestTests {
    @Test("A day's spending, bills included; the everyday part against a typical day; the three biggest places")
    func figures() throws {
        let ledger = DigestFixture.ledger()
        let d = ledger.dayDigest("2026-09-28", from: try #require(ledger.startOfDay(named: "2026-09-28")))
        #expect(d.spent == Money(192.62))
        #expect(d.everydaySpent == Money(112.62))
        #expect(d.typicalDay == Money(20))
        #expect(d.count == 4 && d.pendingCount == 1)
        #expect(d.places.map(\.merchant) == ["City Power", "Shell", "Trader Joe's"])
        #expect(d.places.first?.category == "Utilities")
        #expect(d.facts.map(\.kind) == [.pace, .firstTime, .bills, .pending])
        #expect(d.facts.first?.text == "Everyday spending was 5.5× a typical day's $20.")
        #expect(d.facts[2].text == "Bills and subscriptions in it: City Power ($80).")
        #expect(d.summary == "City Power $80, Shell $62 and Trader Joe's $44. Everyday spending was 5.5× a typical day's $20.")
        #expect(d.writtenBy == nil)
        #expect(d.title("Yesterday") == "Yesterday · $193")
    }

    @Test("A refund offsets its merchant, and one that nets out isn't a place")
    func oneChargeAndRefunds() throws {
        let rows = [
            DigestFixture.row("tv", "Best Buy", -600, "shopping", on: DigestFixture.at(9, 28)),
            DigestFixture.row("tj", "Trader Joe's", -40, "groceries", on: DigestFixture.at(9, 28)),
            DigestFixture.row("tj-back", "Trader Joe's", 10, "groceries", on: DigestFixture.at(9, 28)),
            DigestFixture.row("amz", "Amazon", -25, "shopping", on: DigestFixture.at(9, 28)),
            DigestFixture.row("amz-back", "Amazon", 25, "shopping", on: DigestFixture.at(9, 28)),
        ]
        let ledger = DigestFixture.ledger(DigestFixture.state(yesterday: rows))
        let d = ledger.dayDigest("2026-09-28", from: try #require(ledger.startOfDay(named: "2026-09-28")))
        #expect(d.places.map(\.merchant) == ["Best Buy", "Trader Joe's"])
        #expect(d.places.last?.spent == Money(30))
    }

    @Test("A day with nothing spent says so, and isn't sent to the model")
    func nothingSpent() async throws {
        let model = ScriptedModel([])
        // This morning's coffee: the bank has sent everything through yesterday, and yesterday had nothing.
        let today = DigestFixture.row("today", "Bluebird Coffee", -6, "dining", on: DigestFixture.at(9, 29))
        let d = try await DigestFixture.api(DigestFixture.state(yesterday: [today]), model: model).dayDigest(day: "2026-09-28")
        #expect(d.count == 0 && d.places.isEmpty && d.received)
        #expect(d.summary.hasPrefix("Nothing spent."))
        #expect(d.title("Yesterday") == "Yesterday · nothing spent")
        #expect(await model.requests.isEmpty)
    }

    @Test("A day the bank hasn't sent yet isn't a day with nothing spent")
    func notInYet() throws {
        let ledger = DigestFixture.ledger(DigestFixture.state(yesterday: []))
        let d = ledger.dayDigest("2026-09-28", from: try #require(ledger.startOfDay(named: "2026-09-28")))
        #expect(!d.received && d.count == 0)
        #expect(d.title("Yesterday") == "Yesterday · not in from the bank yet")
        #expect(d.summary.hasPrefix("Nothing from yesterday has come in from your bank yet."))
        // Digests saved before `received` existed were of days that had come in.
        let old = try JSONSerialization.jsonObject(with: RemoteBudgetAPI.encoder.encode(d)) as! [String: Any]
        let without = try JSONSerialization.data(withJSONObject: old.filter { $0.key != "received" })
        #expect(try RemoteBudgetAPI.decoder.decode(DayDigest.self, from: without).received)
    }

    @Test("Days are dates in the ledger's calendar; anything else is refused")
    func dayNames() async throws {
        let ledger = DigestFixture.ledger()
        #expect(ledger.startOfDay(named: "2026-09-28") == DigestFixture.calendar.startOfDay(for: DigestFixture.at(9, 28)))
        #expect(ledger.startOfDay(named: "2026-02-30") == nil)
        #expect(ledger.startOfDay(named: "yesterday") == nil)
        await #expect(throws: BudgetAPIError.self) { try await DigestFixture.api().dayDigest(day: "2026-13-01") }
    }

    @Test("The model's telling is kept when it quotes only the given figures")
    func modelWrites() async throws {
        let model = ScriptedModel([DigestFixture.reply("<think>ok</think>\n\"Mostly City Power ($80) and Shell ($62). Everyday spending was 5.5× a typical day's $20.\"")])
        let d = try await DigestFixture.api(model: model).dayDigest(day: "2026-09-28")
        #expect(d.summary == "Mostly City Power ($80) and Shell ($62). Everyday spending was 5.5× a typical day's $20.")
        #expect(d.writtenBy == "scripted")
        let prompt = try #require(await model.requests.first?.messages.last?.content)
        #expect(prompt.contains("Where: City Power $80 (Utilities); Shell $62 (Transport); Trader Joe's $44 (Groceries)."))
        #expect(await model.requests.first?.thinking == false)
    }

    @Test("A telling with an amount the figures don't hold, or too long to read at a glance, falls back to the template")
    func modelRefused() async throws {
        let template = DigestFixture.ledger().dayDigest("2026-09-28", from: DigestFixture.calendar.startOfDay(for: DigestFixture.at(9, 28))).summary
        for reply in ["You spent $192.62, mostly on City Power.", String(repeating: "Shell. ", count: 40), "   "] {
            let d = try await DigestFixture.api(model: ScriptedModel([DigestFixture.reply(reply)])).dayDigest(day: "2026-09-28")
            #expect(d.summary == template, "kept: \(reply)")
            #expect(d.writtenBy == nil)
        }
    }

    @Test("An earlier summary is reused while the day's facts hold; a late charge gets a new one")
    func reuse() async throws {
        let first = try await DigestFixture.api(model: ScriptedModel([DigestFixture.reply("Mostly City Power ($80) and Shell ($62).")])).dayDigest(day: "2026-09-28")
        let quiet = ScriptedModel([])
        #expect(try await DigestFixture.api(model: quiet).dayDigest(day: "2026-09-28", reuse: first) == first)
        #expect(await quiet.requests.isEmpty)

        var later = DigestFixture.state()
        later.transactions.append(DigestFixture.row("late", "Uber", -18, "transport", on: DigestFixture.at(9, 28)))
        let again = ScriptedModel([DigestFixture.reply("City Power ($80), Shell ($62) and more.")])
        let redone = try await DigestFixture.api(later, model: again).dayDigest(day: "2026-09-28", reuse: first)
        #expect(redone.summary == "City Power ($80), Shell ($62) and more.")
        #expect(await again.requests.count == 1)
    }

    @Test("Amounts are read with or without thousands commas")
    func amounts() {
        #expect(DigestWriter.amounts(in: "$1,234.50 then $6 and $0.99.") == ["$1234.50", "$6", "$0.99"])
        #expect(Ledger.times(2.26) == "2.5×" && Ledger.times(1.9) == "2×")
    }
}

@Suite("Morning summary: what's worth saying")
struct DayDigestFactTests {
    @Test("A merchant the bank named another way before isn't new; neither is anything while the ledger is young")
    func firstTime() throws {
        var state = DigestFixture.state(yesterday: [
            DigestFixture.row("amz", "Amazon Marketplace", -38, "shopping", on: DigestFixture.at(9, 28)),
            DigestFixture.row("px", "Bluebird Coffee", -12, "dining", on: DigestFixture.at(9, 28)),
        ])
        state.transactions.append(DigestFixture.row("amz-old", "AMAZON.COM*2K4", -20, "shopping", on: DigestFixture.at(8, 2)))
        let ledger = DigestFixture.ledger(state)
        let start = try #require(ledger.startOfDay(named: "2026-09-28"))
        #expect(ledger.dayDigest("2026-09-28", from: start).facts.filter { $0.kind == .firstTime }.map(\.text) == ["First time at Bluebird Coffee."])

        var young = state
        young.transactions.removeAll { $0.id == "cafe-old" || $0.id == "amz-old" }
        #expect(!DigestFixture.ledger(young).dayDigest("2026-09-28", from: start).facts.contains { $0.kind == .firstTime })
    }

    @Test("A model that fails says why; the template it fell back to is tried with the model again next time")
    func modelDown() async throws {
        struct Down: ChatModel {
            let label = "down"
            func complete(_ request: ChatRequest) async throws -> ChatResponse { throw BudgetAPIError.unreachable }
        }
        let fallback = try await DigestFixture.api(model: Down()).dayDigest(day: "2026-09-28")
        #expect(fallback.writtenBy == nil && fallback.writerProblem?.hasPrefix("The model didn't answer") == true)
        let back = ScriptedModel([DigestFixture.reply("Mostly City Power ($80) and Shell ($62).")])
        let retried = try await DigestFixture.api(model: back).dayDigest(day: "2026-09-28", reuse: fallback)
        #expect(retried.writtenBy == "scripted" && retried.writerProblem == nil)
    }
}
