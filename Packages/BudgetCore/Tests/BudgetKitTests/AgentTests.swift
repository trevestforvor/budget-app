import Foundation
import Testing
@testable import BudgetKit

/// Plays back a fixed script of model turns and records what the loop sent.
actor ScriptedModel: ChatModel {
    nonisolated let label = "scripted"
    private var turns: [ChatMessage]
    private(set) var requests: [ChatRequest] = []

    init(_ turns: [ChatMessage]) { self.turns = turns }

    func complete(_ request: ChatRequest) async throws -> ChatResponse {
        requests.append(request)
        return ChatResponse(message: turns.removeFirst(), finishReason: nil, tokensPerSecond: nil)
    }
}

extension ChatMessage {
    static func call(_ name: String, _ args: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: nil, toolCalls: [ChatToolCall(id: "c-\(name)", name: name, arguments: args)], toolCallID: nil)
    }

    static func say(_ text: String) -> ChatMessage { ChatMessage(role: .assistant, content: text, toolCalls: [], toolCallID: nil) }
}

@Suite("Agent loop")
struct AgentLoopTests {
    var toolbox: DemoToolbox { DemoToolbox(ledger: Fixture.ledger(), decisions: nil) }

    @Test("Tool call → ledger result → grounded answer with figures")
    func happyPath() async throws {
        let ledger = Fixture.ledger()
        let q3 = ledger.quarter(3, year: 2026)
        let total = ledger.spent(from: q3.start, to: q3.end, categoryID: "dining")
        let model = ScriptedModel([
            .call("sumByCategory", #"{"period":"2026-Q3","compareTo":"2026-Q2","categoryID":"dining"}"#),
            .say("Dining in Q3 is \(total.display)."),
        ])
        let outcome = try await AgentLoop(model: model, toolbox: toolbox).run("Dining Q3 vs Q2?")
        #expect(outcome.reply.text == "Dining in Q3 is \(total.display).")
        #expect(outcome.ungrounded.isEmpty)
        #expect(outcome.reply.figures.first?.value == total)
        #expect(outcome.reply.toolCalls.map(\.name) == ["sumByCategory"])
        let first = try #require(await model.requests.first)
        #expect(first.thinking == false)
        #expect(first.messages.first?.content?.contains("Numbers come from the ledger") == true)
    }

    @Test("Invalid arguments go back to the model as repairable errors")
    func repair() async throws {
        let model = ScriptedModel([
            .call("sumByCategory", #"{"period":"Q3 2026","categoryID":"dining"}"#),
            .call("sumByCategory", #"{"period":"2026-Q3","categoryID":"dining"}"#),
            .say("Done."),
        ])
        let outcome = try await AgentLoop(model: model, toolbox: toolbox).run("Dining in Q3?")
        #expect(outcome.repairs == 1)
        #expect(outcome.reply.toolCalls.count == 1)
        let second = try #require(await model.requests.dropFirst().first)
        let toolMessage = try #require(second.messages.last)
        #expect(toolMessage.role == .tool)
        #expect(toolMessage.content?.contains("must match") == true)
    }

    @Test("A made-up figure triggers one rewrite; a second one is reported")
    func grounding() async throws {
        let model = ScriptedModel([
            .call("sumByMerchant", #"{"merchant":"doordash","period":"this_month"}"#),
            .say("DoorDash is about $999.99 this month."),
            .say("Still $999.99."),
        ])
        let outcome = try await AgentLoop(model: model, toolbox: toolbox).run("DoorDash?")
        #expect(outcome.ungrounded == ["$999.99"])
        let retry = try #require(await model.requests.last?.messages.last)
        #expect(retry.content?.contains("don't appear in any tool result") == true)
    }

    @Test("Write tools become proposals, not changes")
    func proposals() async throws {
        let model = ScriptedModel([
            .call("setMerchantTarget", #"{"merchant":"doordash","monthlyAmount":"150"}"#),
            .say("Here's a card to cap DoorDash at $150 a month."),
        ])
        let box = toolbox
        let outcome = try await AgentLoop(model: model, toolbox: box).run("Cap DoorDash at 150")
        let proposal = try #require(outcome.reply.proposedActions.first)
        #expect(proposal.action == .setMerchantTarget(SetMerchantTarget(merchant: "doordash", monthlyAmount: DecimalAmount(string: "150")!)))
        #expect(proposal.title == "Cap DoorDash at $150 a month")
        #expect(box.ledger.merchantTargets.isEmpty)
        #expect(outcome.ungrounded.isEmpty) // "$150" came from the user's question
    }

    @Test("Chat responses parse tool calls, and <think> blocks are stripped")
    func parse() throws {
        let wire = #"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":"<think>hmm</think>","tool_calls":[{"id":"x","type":"function","function":{"name":"flexBudget","arguments":"{}"}}]}}],"timings":{"predicted_per_second":98.2}}"#
        let response = try OpenAIChatModel.parse(try JSONValue.parse(Data(wire.utf8)))
        #expect(response.message.toolCalls.first?.name == "flexBudget")
        #expect(response.message.content == "")
        #expect(response.tokensPerSecond == 98.2)
        #expect(OpenAIChatModel.stripThinking("<think>a\nb</think>\nAnswer.") == "Answer.")
        let body = OpenAIChatModel(baseURL: URL(string: "https://x")!, model: "qwen3.8-27b").body(ChatRequest(messages: [.user("hi")], thinking: true))
        guard case let .object(o) = body else { Issue.record("shape"); return }
        #expect(o["chat_template_kwargs"] == .object(["enable_thinking": .bool(true)]))
    }
}

@Suite("Near-term planning math")
struct PlanningTests {
    @Test("Flex budget: income − bills − subscriptions − savings; safe to spend = the everyday budget − everyday spent")
    func flex() {
        let f = Fixture.ledger().flexBudget()
        #expect(f.flexNumber == f.expectedIncome - f.bills - f.subscriptions - f.plannedSavings)
        #expect(f.safeToSpend == f.flexNumber - f.flexSpent)
        #expect(f.plannedSavings == Money(500)) // detected monthly transfer
        #expect(!f.plannedSavingsIsSet)
    }

    @Test("Pay yourself first: setting monthly savings lowers the flex number by the difference")
    func savingsTarget() async throws {
        let api = Fixture.api()
        let before = try await api.overview().flex
        _ = try await api.perform(.setMonthlySavings(SetMonthlySavings(monthlyAmount: DecimalAmount(string: "1200")!)))
        let after = try await api.overview().flex
        #expect(after.plannedSavings == Money(1200))
        #expect(after.plannedSavingsIsSet)
        #expect(before.flexNumber - after.flexNumber == Money(700))
    }

    @Test("Capacity: typical is what the months actually left (Plan's cash flow); the buckets are a usual month; stretch ≥ typical")
    func capacity() {
        let ledger = Fixture.ledger()
        let c = ledger.capacity()
        let flows = ledger.cashFlowHistory(months: c.months).filter { !$0.isPartial }
        let spent = flows.map(\.spending).sum()
        // Typical averages each month's net as spent, so it reconciles with the cash flow Plan shows; each of the
        // averages is rounded to the cent on its own.
        #expect(abs((c.typical - Money(minorUnits: flows.map(\.net.minorUnits).reduce(0, +) / Int64(flows.count))).minorUnits) < Int64(c.months))
        #expect(abs((c.income - c.typical - Money(minorUnits: spent.minorUnits / Int64(flows.count))).minorUnits) < Int64(c.months))
        // Nothing in the demo is spread over the year, so the buckets add up to the months' spending.
        #expect(abs((c.bills + c.subscriptions + c.everyday - Money(minorUnits: spent.minorUnits / Int64(flows.count))).minorUnits) < Int64(c.months))
        #expect(c.stretch >= c.typical)
        // Pay ($3,850 twice a month) plus what Card rewards took in, a money-in category like income: $120 over the
        // three months (three $10 dining credits, a $50 Tablesy credit, $25 of points and a $15 offer).
        #expect(c.income == Money(7740))
    }

    @Test("Guidance: 3 and 6 months of essentials, 20% of take-home")
    func guidance() {
        let g = Fixture.ledger().guidance()
        #expect(g.threeMonths == Money(minorUnits: g.essentialMonthly.minorUnits * 3))
        #expect(g.twentyPercent == Money(1548))
        #expect(g.gapToThree == .zero) // demo cash covers three months
    }

    @Test("Merchant caps show in Spending with this month's spend")
    func merchantCaps() async throws {
        let api = Fixture.api()
        _ = try await api.perform(.setMerchantTarget(SetMerchantTarget(merchant: "doordash", monthlyAmount: DecimalAmount(string: "150")!)))
        let cap = try #require(try await api.spending(.thisMonth).merchantCaps.first)
        #expect(cap.merchant == "DoorDash")
        #expect(cap.target == Money(150))
        let ledger = Fixture.ledger()
        #expect(cap.spent == ledger.merchantSpend("DoorDash", from: ledger.startOfMonth, to: Fixture.now).total)
        await #expect(throws: BudgetAPIError.self) {
            try await api.perform(.setMerchantTarget(SetMerchantTarget(merchant: "Nowhere Diner", monthlyAmount: DecimalAmount(string: "10")!)))
        }
    }

    @Test("Periods resolve the way the tools name them", arguments: [
        ("this_month", "September 2026"), ("last_month", "August 2026"), ("2026-Q2", "Q2 2026"), ("2026-07", "July 2026"),
    ])
    func periods(period: String, label: String) {
        #expect(Fixture.ledger().interval(forPeriod: period)?.label == label)
    }

    @Test("The patched /v1/decision returns full distributions and they're kept")
    func decisionDistribution() throws {
        let q = DecisionQuestion.choice(instructions: "?", options: [("dining", ""), ("groceries", "")])
        let wire = #"{"results":[{"fields":{"category":{"value":"dining","probability":0.99,"probabilities":{"dining":0.99,"groceries":0.01}}}}]}"#
        let parsed = try LlamaDecisionModel.parse(try JSONValue.parse(Data(wire.utf8)), questions: ["category": q], count: 1, label: "q")
        #expect(parsed[0].answers["category"]?.distribution == ["dining": 0.99, "groceries": 0.01])
    }
}
