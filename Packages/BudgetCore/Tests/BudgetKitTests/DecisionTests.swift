import Foundation
import Testing
@testable import BudgetKit

@Suite("Decision model")
struct DecisionTests {
    static let question = DecisionQuestion.choice(instructions: "Which category?", options: [("dining", "Dining"), ("groceries", "Groceries")])

    @Test("Threshold: at or above accepts, below goes to review with the ranking")
    func threshold() {
        let policy = DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category])
        let known: Set = ["dining", "groceries", "shopping"]
        let sure = DecisionAnswer(value: "dining", confidence: 0.80, distribution: ["dining": 0.8, "groceries": 0.2])
        #expect(CategoryDecisions.outcome(sure, policy: policy, knownCategoryIDs: known) == .accept(categoryID: "dining", confidence: 0.8))
        let unsure = DecisionAnswer(value: "dining", confidence: 0.79, distribution: ["dining": 0.79, "groceries": 0.15, "pets": 0.06])
        #expect(CategoryDecisions.outcome(unsure, policy: policy, knownCategoryIDs: known)
            == .review(suggestions: [CategorySuggestion(categoryID: "dining", confidence: 0.79), CategorySuggestion(categoryID: "groceries", confidence: 0.15)]))
        let unknown = DecisionAnswer(value: "pets", confidence: 0.99)
        guard case .review = CategoryDecisions.outcome(unknown, policy: policy, knownCategoryIDs: known) else { Issue.record("accepted an unknown id"); return }
    }

    @Test("What's sent to the model omits account, date, exact amount and id")
    func privacy() throws {
        let row = try #require(Fixture.ledger().reviewItems.first { $0.transaction.merchant == "Casa Taco" }).transaction
        let request = CategoryDecisions.request(for: row, categories: DemoLedger.categoryList)
        #expect(request.state.contains("CASA TACO"))
        #expect(request.state.contains("$10–50"))
        #expect(request.state.contains("Square — small-business point of sale"))
        #expect(!request.state.contains("23.5"))
        #expect(!request.state.contains(row.id))
        #expect(!request.state.contains(row.accountID))
        #expect(!request.state.contains("2026"))
    }

    @Test("People are stripped from descriptors before anything is sent")
    func redaction() throws {
        #expect(CategoryDecisions.redacted("VENMO *J. PARK") == "VENMO")
        #expect(CategoryDecisions.redacted("ZELLE TO JOHN SMITH") == "ZELLE TO")
        #expect(CategoryDecisions.redacted("ZELLE PAYMENT FROM ANA LOPEZ") == "ZELLE PAYMENT FROM")
        #expect(CategoryDecisions.redacted("PAYMENT jane.doe@example.com REF") == "PAYMENT REF")
        #expect(CategoryDecisions.redacted("CASA TACO") == "CASA TACO")
        let venmo = try #require(Fixture.ledger().reviewItems.first { $0.transaction.merchant == "Venmo" }).transaction
        let state = CategoryDecisions.request(for: venmo, categories: DemoLedger.categoryList).state
        #expect(!state.uppercased().contains("PARK"))
        #expect(state.contains("\"descriptor\":\"VENMO\""))
    }

    @Test("Jev / Laya request and response match the /v1/systemone wire shape")
    func systemOne() throws {
        let jev = SystemOneDecisionModel(transport: .openRouter(apiKey: "k"))
        #expect(jev.endpoint.url.absoluteString == "https://openrouter.ai/api/alpha/decisions")
        #expect(!jev.runsLocally)
        let body = jev.body(for: DecisionRequest(state: "SQ *TACO", questions: ["category": Self.question]))
        guard case let .object(b) = body, case let .object(qs)? = b["questions"], case let .object(q)? = qs["category"] else { Issue.record("shape"); return }
        #expect(b["model"] == .string("typesafe/jev-1.13"))
        #expect(q["type"] == .string("choice"))
        #expect(q["criteria"] == .object(["dining": .string("Dining"), "groceries": .string("Groceries")]))

        let zdr = SystemOneDecisionModel(transport: .openRouter(apiKey: "k", zeroDataRetention: true))
        guard case let .object(zb) = zdr.body(for: DecisionRequest(state: "x", questions: ["category": Self.question])) else { Issue.record("shape"); return }
        #expect(zb["provider"] == .object(["zdr": .bool(true), "data_collection": .string("deny"), "allow_fallbacks": .bool(false)]))
        #expect(b["provider"] == nil)

        let wire = #"{"model":"jev-1.13","answers":{"category":{"type":"choice","choice":"dining","probabilities":{"dining":0.91,"groceries":0.09}}},"usage":{"cost":0.00004}}"#
        let response = try SystemOneDecisionModel.parse(try JSONValue.parse(Data(wire.utf8)), questions: ["category": Self.question], fallbackModel: "x")
        #expect(response.model == "jev-1.13")
        #expect(response.answers["category"] == DecisionAnswer(value: "dining", confidence: 0.91, distribution: ["dining": 0.91, "groceries": 0.09]))

        let noul = DecisionQuestion.noul(instructions: "Recurring?", whenTrue: nil, whenFalse: nil)
        let yes = try SystemOneDecisionModel.parse(try JSONValue.parse(Data(#"{"answers":{"r":{"type":"noul","noul":0.2}}}"#.utf8)), questions: ["r": noul], fallbackModel: "x")
        #expect(yes.answers["r"]?.value == "false")
        #expect(yes.answers["r"]?.confidence == 0.8)
    }

    @Test("Qwen Decide request and response match the /v1/decision wire shape, batched")
    func llamaDecision() throws {
        let model = LlamaDecisionModel(baseURL: URL(string: "https://decide.example.olares.com")!)
        #expect(model.runsLocally)
        let requests = [DecisionRequest(state: "a", questions: ["category": Self.question]), DecisionRequest(state: "b", questions: ["category": Self.question])]
        guard case let .object(b) = model.body(for: requests), case let .object(schema)? = b["schema"], case let .object(field)? = schema["category"] else { Issue.record("shape"); return }
        #expect(b["contexts"] == .array([.string("a"), .string("b")]))
        #expect(b["cache_prompt"] == .bool(true))
        #expect(field["type"] == .string("enum"))
        #expect(field["choices"] == .array([.string("dining"), .string("groceries")]))
        guard case let .string(description)? = field["description"] else { Issue.record("no description"); return }
        #expect(description.contains("Options:\ndining: Dining"))

        let wire = #"{"results":[{"fields":{"category":{"value":"dining","probability":0.88}}},{"fields":{"category":{"value":"groceries","probability":0.61}}}]}"#
        let parsed = try LlamaDecisionModel.parse(try JSONValue.parse(Data(wire.utf8)), questions: ["category": Self.question], count: 2, label: "qwen")
        #expect(parsed.map { $0.answers["category"]?.value } == ["dining", "groceries"])
        #expect(parsed[1].answers["category"]?.confidence == 0.61)
        #expect(throws: DecisionError.self) {
            try LlamaDecisionModel.parse(try JSONValue.parse(Data(#"{"results":[]}"#.utf8)), questions: [:], count: 2, label: "q")
        }
    }

    @Test("Turning on the decision model auto-accepts sure items and leaves the rest for review")
    func endToEnd() async throws {
        let api = Fixture.api()
        #expect(try await api.reviewQueue().count == 11)
        let result = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .localDecide, autoAcceptPercent: 80)))
        #expect(result.affectedTransactions == 3)
        #expect(result.message.contains("Auto-accepted 3 of 11"))
        let remaining = try await api.reviewQueue()
        // Four named merchants and the four Meadow withdrawals, which name none.
        #expect(remaining.count == 8)
        #expect(remaining.allSatisfy { $0.transaction.categorization?.tier == .decisionModel && !$0.suggestions.isEmpty })

        let taco = try #require(try await api.transactions(TransactionFilter(search: "Casa Taco")).first)
        #expect(taco.categorization == Categorization(categoryID: "dining", confidence: 0.91, tier: .decisionModel, needsReview: false,
                                                     decidedBy: "qwen3.8-27b-decide (demo)"))

        // Lowering the threshold takes more; the person can still overrule any of them.
        let lower = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(autoAcceptPercent: 70)))
        #expect(lower.affectedTransactions == 1)
        #expect(try await api.reviewQueue().count == 7)
        _ = try await api.confirmCategory(transactionID: taco.id, categoryID: "groceries")
        #expect(try await api.transactions(TransactionFilter(search: "Casa Taco")).first?.categorization?.tier == .user)

        let status = try await api.serverStatus()
        #expect(status.decisionPolicy.autoAcceptPercent == 70)
        #expect(status.rawDataStaysLocal)
    }

    @Test("Choosing Jev discloses exactly what it receives, and status shows the sample")
    func jevDisclosed() async throws {
        let api = Fixture.api()
        let reply = try await api.ask("Use Jev for decisions", conversationID: nil)
        let proposal = try #require(reply.proposedActions.first)
        #expect(proposal.detail?.contains("Jev receives the merchant, a cleaned descriptor and an amount band") == true)
        _ = try await api.perform(proposal.action)
        let status = try await api.serverStatus()
        #expect(status.rawDataStaysLocal == false)
        let sample = try #require(status.decisionSample)
        #expect(sample.contains("\"amountBand\""))
        #expect(!sample.uppercased().contains("PARK"))
    }

    @Test("Escalation: local first, Jev for what's left, accepted only above the bar")
    func escalation() async throws {
        let api = Fixture.api()
        let result = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, escalateToJev: true)))
        // Local accepts Casa Taco, Local 123, Apple; Jev then clears 80% on Amazon and Venmo.
        #expect(result.affectedTransactions == 5)
        #expect(result.message.contains("Auto-accepted 5 of 11 waiting (2 by Jev); 6 still need you."))
        let venmo = try #require(try await api.transactions(TransactionFilter(search: "Venmo")).first)
        #expect(venmo.categorization?.decidedBy == "jev-1.13 (demo) · escalated")
        #expect(venmo.categorization?.categoryID == "transfer")
        #expect(Set(try await api.reviewQueue().map(\.transaction.merchant)) == ["PayPal", "CVS", "Withdrawal"])
        #expect(try await api.serverStatus().rawDataStaysLocal == false)
    }

    @Test("Ask can turn on escalation")
    func askEscalation() async throws {
        // The demo already decides with the local model, so only escalation changes.
        let proposal = try #require(try await Fixture.api().ask("Use Jev as a backup for the decision model", conversationID: nil).proposedActions.first)
        #expect(proposal.action == .updateDecisionPolicy(UpdateDecisionPolicy(escalateToJev: true, rerunPending: true)))
        // With the model off, turning on escalation turns the local model on too.
        let api = Fixture.api()
        _ = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .off)))
        let off = try #require(try await api.ask("Use Jev as a backup for the decision model", conversationID: nil).proposedActions.first)
        #expect(off.action == .updateDecisionPolicy(UpdateDecisionPolicy(provider: .localDecide, escalateToJev: true, rerunPending: true)))
    }

    @Test("One protocol: the factory builds /v1/systemone clients that differ only by endpoint")
    func factory() throws {
        let shim = URL(string: "https://jevshim.example.olares.com")!
        let endpoints = DecisionEndpoints(jev: .openRouter(apiKey: "k"), qwenDecide: shim, laya: URL(string: "https://laya.example")!)
        #expect(try DecisionModels.make(.off, endpoints) == nil)
        let jev = try #require(try DecisionModels.make(.jev, endpoints) as? SystemOneDecisionModel)
        #expect(jev.endpoint.url.absoluteString == "https://openrouter.ai/api/alpha/decisions")
        let qwen = try #require(try DecisionModels.make(.localDecide, endpoints) as? SystemOneDecisionModel)
        #expect(qwen.endpoint.url.absoluteString == "https://jevshim.example.olares.com/v1/systemone")
        #expect(qwen.runsLocally)
        guard case let .object(qb) = qwen.body(for: DecisionRequest(state: "x", questions: ["category": Self.question])) else { Issue.record("shape"); return }
        #expect(qb["system2"] == .string("off"))
        guard case let .object(jb) = jev.body(for: DecisionRequest(state: "x", questions: ["category": Self.question])) else { Issue.record("shape"); return }
        #expect(jb["system2"] == nil) // never sent to Jev
        var direct = endpoints
        direct.qwenDecideDirect = true
        #expect(try DecisionModels.make(.localDecide, direct) is LlamaDecisionModel)
        #expect(throws: DecisionError.missingKey) { try DecisionModels.make(.jev, DecisionEndpoints()) }
    }

    @Test("Threshold outside 50–99% is rejected")
    func bounds() async {
        await #expect(throws: BudgetAPIError.self) {
            try await Fixture.api().perform(.updateDecisionPolicy(UpdateDecisionPolicy(autoAcceptPercent: 40)))
        }
    }
}
