import Foundation
import Testing
@testable import BudgetKit

/// `findUpcoming` without card bills says so in words, so the model neither reads an empty list as "nothing due" nor
/// estimates a bill from the card's balance.
@Suite("findUpcoming without card bills")
struct FindUpcomingHonestyTests {
    static let noBills = "No card bills are known"

    static func result(_ ledger: Ledger) throws -> [String: JSONValue] {
        let (result, _) = DemoToolbox(ledger: ledger, decisions: nil).findUpcoming(days: 30)
        guard case let .object(o) = result else { throw ShapeError() }
        return o
    }

    struct ShapeError: Error {}

    static func string(_ value: JSONValue?) -> String? {
        if case let .string(s)? = value { return s }
        return nil
    }

    static var sixWeeksOfPay: [LedgerTransaction] {
        [(8, 7), (8, 21), (9, 4), (9, 18)].map { PayRows.pay($0.0, $0.1) }
    }

    @Test("A credit card with no card bill: the result says none are known and not to estimate them; the note drops the issuer")
    func findUpcomingSaysWhenNoCardBills() throws {
        let o = try Self.result(PayRows.ledger(Self.sixWeeksOfPay))
        let cardBills = try #require(Self.string(o["cardBills"]))
        #expect(cardBills.hasPrefix(Self.noBills))
        #expect(cardBills.contains("Don't estimate them"))
        let note = try #require(Self.string(o["note"]))
        #expect(!note.contains("card issuer"))
        #expect(note.contains("Card bills pay for spending already made."))
        #expect(o["cardsWithoutBills"] == nil)
        // Everything else is still there.
        guard case .object? = o["nextPaycheck"] else { Issue.record("no paycheck"); return }
    }

    @Test("No credit cards at all: the result says none are linked")
    func findUpcomingNoCardsSaysSo() throws {
        var state = Rows.state(Self.sixWeeksOfPay)
        state.accounts.removeAll { $0.kind == .credit }
        let o = try Self.result(Ledger(state: state, now: Fixture.now, calendar: Fixture.calendar))
        #expect(Self.string(o["cardBills"]) == "No credit cards are linked.")
    }

    @Test("With a card bill: the list as before and the issuer in the note; a second card without one is named")
    func someCardsBilled() throws {
        var state = Rows.state(Self.sixWeeksOfPay)
        state.accounts.append(Account(id: "card2", name: "Blue Card", institution: "Harbor", kind: .credit, balance: Money(-40), source: .simplefin, mask: "4411"))
        state.cardBills = ["card": CardBillTests.bill()]
        let o = try Self.result(Ledger(state: state, now: Fixture.now, calendar: Fixture.calendar))
        guard case let .array(bills)? = o["cardBills"] else { Issue.record("cardBills isn't a list"); return }
        #expect(bills.count == 1)
        #expect(Self.string(o["note"])?.contains("card bills come from the card issuer") == true)
        #expect(Self.string(o["cardsWithoutBills"]) == "No card bill is known for Blue Card ••4411. Don't estimate one.")
        // Every card billed: nothing to call out.
        let all = try Self.result(PayRows.ledger(Self.sixWeeksOfPay, cardBills: [CardBillTests.bill()]))
        #expect(all["cardsWithoutBills"] == nil)
    }

    @Test("The tool's description tells the model card bills may be unknown")
    func description() throws {
        let spec = try #require(ToolCatalog.spec(named: "findUpcoming"))
        #expect(spec.description.contains("otherwise it says none are known"))
    }

    @Test("Through the agent loop, the model is handed the words, and its answer stays grounded")
    func agentSeesNoCardBills() async throws {
        let ledger = PayRows.ledger(Self.sixWeeksOfPay)
        let model = ScriptedModel([
            .call("findUpcoming", #"{"days":30}"#),
            .say("I don't know your card bill: card bills aren't on for your Gold Card."),
        ])
        let outcome = try await AgentLoop(model: model, toolbox: DemoToolbox(ledger: ledger, decisions: nil)).run("When is my card bill due?")
        #expect(outcome.reply.toolCalls.map(\.name) == ["findUpcoming"])
        #expect(outcome.ungrounded.isEmpty)
        let second = try #require(await model.requests.dropFirst().first)
        let toolResult = try #require(second.messages.last { $0.role == .tool }?.content)
        #expect(toolResult.contains(Self.noBills))
    }

    @Test("The demo's templated answer to a card question says it doesn't know, rather than leaving cards out")
    func demoSaysSo() async throws {
        var state = Rows.state(Self.sixWeeksOfPay)
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { Fixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        let reply = try await api.ask("When is my card bill due?", conversationID: nil)
        #expect(reply.toolCalls.map(\.name) == ["findUpcoming"])
        #expect(reply.text.contains("I don't know your card bills"))
        state.accounts.removeAll { $0.kind == .credit }
        let none = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { Fixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                   persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        #expect(try await none.ask("When is my card bill due?", conversationID: nil).text.contains("No credit cards are linked."))
    }
}
