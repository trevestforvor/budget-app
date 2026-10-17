import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLProtocol on Linux
#endif
import Testing
@testable import BudgetKit

/// A decision model that's down, counting the calls it refused.
actor DownDecisions: DecisionModel {
    nonisolated let label = "down"
    nonisolated var runsLocally: Bool { true }
    private(set) var calls = 0
    func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse] {
        calls += 1
        throw DecisionError.http(503, "unavailable")
    }
}

/// Answers from a fixed table, but only once `release()` is called, so a test can act while a sync waits on it.
actor GatedDecisions: DecisionModel {
    nonisolated let label = "gated"
    nonisolated var runsLocally: Bool { true }
    let table: [String: (String, Double)]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ table: [String: (String, Double)]) { self.table = table }
    var waiting: Int { waiters.count }
    func release() { waiters.forEach { $0.resume() }; waiters.removeAll() }
    func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse] {
        await withCheckedContinuation { waiters.append($0) }
        return requests.map { r in
            let hit = table.first { r.state.uppercased().contains($0.key) }?.value ?? ("shopping", 0.3)
            return DecisionResponse(answers: [CategoryDecisions.questionID: DecisionAnswer(value: hit.0, confidence: hit.1, distribution: [hit.0: hit.1])], model: label)
        }
    }
}

/// A store whose next save can be held until `release()`, then fail or go through, so a test can overlap writes.
actor HeldPersistence: LedgerPersistence {
    private(set) var saves: [LedgerState] = []
    private var holdNext: Bool?
    private var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }
    func holdNextSave(failing: Bool) { holdNext = failing }
    func release() { held?.resume(); held = nil }
    func save(from old: LedgerState, to new: LedgerState) async throws {
        if let failing = holdNext {
            holdNext = nil
            await withCheckedContinuation { held = $0 }
            if failing { throw BudgetAPIError.server(status: 500, message: "deadlock detected") }
        }
        saves.append(new)
    }
}

@Suite("Model outages during ingest")
struct ModelOutageTests {
    static let table: [String: (String, Double)] = ["CASA TACO": ("dining", 0.95), "NETFLIX": ("subscriptions", 0.97), "PAYPAL": ("shopping", 0.45)]
    static var nothingNew: SourceSnapshot { SourceSnapshot(source: .plaid, accounts: [], warnings: []) }
    static func oneRow(_ id: String, _ raw: String, _ amount: Decimal) -> SourceSnapshot {
        SourceSnapshot(source: .plaid, accounts: [
            SourceAccount(externalID: "summit-1", institution: "Summit Card", institutionDomain: nil, name: "Gold Card", kind: .credit,
                          balance: Money(-412.50), availableBalance: nil, balanceDate: EngineFixture.now,
                          transactions: [SourceTransaction(externalID: id, posted: EngineFixture.day(0), amount: Money(amount), description: raw)], holdings: []),
        ], warnings: [])
    }
    static func waitFor(_ gate: GatedDecisions) async { while await gate.waiting == 0 { await Task.yield() } }

    @Test("A model that can't be reached sends new rows to review and saves them — nothing is left in memory unsaved")
    func unreachableModelKeepsRows() async throws {
        let persistence = RecordingPersistence()
        let api = EngineFixture.api(persistence: persistence, decisions: DecisionRouting(local: DownDecisions()))
        let report = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        #expect(report.rowsAdded == 5)
        #expect(report.byRule == 1 && report.byModel == 0)
        #expect(report.warnings.contains { $0.contains("Couldn't reach down") })
        let saved = try #require(await persistence.saves.last?.new)
        #expect(saved.transactions.count == 5)
        let waiting = saved.transactions.filter { saved.reviewReasons[$0.id] == Categorizer.modelUnreachableReason }
        #expect(waiting.count == 4)  // all but the Venmo rule's row
        #expect(waiting.allSatisfy { $0.categorization?.needsReview == true })
    }

    @Test("After a restart, the next sync with the model back files what waited, and the replayed rows are all there")
    func retriedAfterRestart() async throws {
        let persistence = RecordingPersistence()
        let down = EngineFixture.api(persistence: persistence, decisions: DecisionRouting(local: DownDecisions()))
        _ = try await down.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        let saved = try #require(await persistence.saves.last?.new)
        let api = LedgerBudgetAPI(state: saved, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil,
                                  decisions: DecisionRouting(local: StubDecisions(Self.table)), persistence: persistence,
                                  deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        // Plaid replays the same rows (the cursor never moved).
        let report = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-2")
        #expect(report.rowsAdded == 0)
        #expect(report.byModel == 0 && report.needsReview == 0)   // this batch's own counts: it added nothing
        #expect(report.notes?.contains { $0.contains("Asked again about 4 transactions") && $0.contains("3 filed, 1 waiting") } == true)
        #expect(!report.warnings.contains { $0.contains("Asked again") })   // a note, not a warning
        let state = try #require(await persistence.saves.last?.new)
        #expect(state.transactions.count == 5)
        #expect(state.transactions.allSatisfy { state.reviewReasons[$0.id] != Categorizer.modelUnreachableReason })
        #expect(state.reviewReasons["plaid:p4"] == nil)   // Netflix was filed, so its waiting note went with it
    }

    @Test("A confirm made while a sync waits on the model isn't overwritten by the model's answer")
    func confirmDuringRetryStands() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: DownDecisions()))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        let gate = GatedDecisions(Self.table)
        await api.reconfigure(chatModel: nil, decisions: DecisionRouting(local: gate))
        let sync = Task { try await api.ingest(Self.nothingNew, batchID: "sync-2") }
        await Self.waitFor(gate)
        _ = try await api.confirmCategory(transactionID: "plaid:p4", categoryID: "groceries")
        await gate.release()
        _ = try await sync.value
        let netflix = try #require(await api.state.transactions.first { $0.id == "plaid:p4" }?.categorization)
        #expect(netflix.categoryID == "groceries" && netflix.tier == .user)
        // The rows nobody touched were filed.
        let taco = try #require(await api.state.transactions.first { $0.id == "plaid:p1" }?.categorization)
        #expect(taco.categoryID == "dining" && !taco.needsReview)
    }

    @Test("A write that fails while the model is asked doesn't take the new rows with it")
    func otherRollbackKeepsNewRows() async throws {
        let persistence = RecordingPersistence()
        let api = EngineFixture.api(persistence: persistence, decisions: DecisionRouting(local: StubDecisions(Self.table)))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        let gate = GatedDecisions(["TRADER JOE": ("groceries", 0.96)])
        await api.reconfigure(chatModel: nil, decisions: DecisionRouting(local: gate))
        let sync = Task { try await api.ingest(Self.oneRow("p9", "TRADER JOE S #552", -38), batchID: "sync-2") }
        await Self.waitFor(gate)
        await persistence.setFailNext()
        await #expect(throws: BudgetAPIError.self) { try await api.confirmCategory(transactionID: "plaid:p3", categoryID: "groceries") }
        await gate.release()
        let report = try await sync.value
        #expect(report.rowsAdded == 1)
        let saved = try #require(await persistence.saves.last?.new)
        #expect(saved.transactions.contains { $0.id == "plaid:p9" && $0.categorization?.categoryID == "groceries" })
        #expect(await api.state.transactions.contains { $0.id == "plaid:p9" })
    }

    @Test("After a re-ask can't reach the model, re-asks pause instead of resending the backlog on every link's sync")
    func reAsksPause() async throws {
        let down = DownDecisions()
        let api = EngineFixture.api(decisions: DecisionRouting(local: down))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        #expect(await down.calls == 1)
        _ = try await api.ingest(Self.nothingNew, batchID: "sync-2")   // re-asks the 4 waiting rows, fails, pauses
        #expect(await down.calls == 2)
        _ = try await api.ingest(Self.nothingNew, batchID: "sync-3")   // paused: nothing is sent
        #expect(await down.calls == 2)
    }

    @Test("A row saved with no category (an older build's leftover) is filed on the next sync")
    func uncategorizedRowsHeal() async throws {
        var state = LedgerState.empty
        state.accounts = Small.accounts
        var row = Small.row("a", at: Small.date(2026, 9, 20), -15.49, category: "shopping", raw: "NETFLIX.COM", tier: .model, needsReview: true)
        row.categorization = nil
        state.transactions = [row]
        state.decisionPolicy = DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category])
        let api = LedgerBudgetAPI(state: state, calendar: Small.calendar, clock: { Small.date(2026, 9, 25) }, chatModel: nil,
                                  decisions: DecisionRouting(local: StubDecisions(Self.table)), persistence: nil,
                                  deployment: DeploymentInfo(endpoint: "x", version: "x", sources: [], institutions: []))
        _ = try await api.ingest(Self.nothingNew, batchID: "sync-1")
        let filed = try #require(await api.state.transactions.first?.categorization)
        #expect(filed.categoryID == "subscriptions" && !filed.needsReview)
    }

    @Test("Switching the model without re-checking the queue doesn't send waiting rows to the new one")
    func switchWithoutRerunReleasesWaitingRows() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: DownDecisions(), jev: StubDecisions(Self.table)))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        _ = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .jev, rerunPending: false)))
        let state = await api.state
        #expect(state.transactions.allSatisfy { state.reviewReasons[$0.id] != Categorizer.modelUnreachableReason })
        let report = try await api.ingest(Self.nothingNew, batchID: "sync-2")
        #expect(report.notes == nil)
        #expect(state.transactions.first { $0.id == "plaid:p1" }.flatMap { state.reviewReasons[$0.id] } == Categorizer.modelWasUnreachableReason)
    }

    @Test("Nudging the threshold without re-checking keeps waiting rows waiting for the model")
    func thresholdChangeKeepsWaitingRows() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: DownDecisions()))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        _ = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(autoAcceptPercent: 85, rerunPending: false)))
        #expect(await api.state.transactions.filter { $0.categorization?.needsReview == true }.count == 4)
        await api.reconfigure(chatModel: nil, decisions: DecisionRouting(local: StubDecisions(Self.table)))
        let report = try await api.ingest(Self.nothingNew, batchID: "sync-2")
        #expect(report.notes?.contains { $0.contains("Asked again about 4") } == true)
    }

    @Test("Writes take turns: a file import whose save fails can't take a sync's row with it")
    func writesTakeTurns() async throws {
        let persistence = HeldPersistence()
        let api = EngineFixture.api(persistence: persistence, decisions: DecisionRouting(local: StubDecisions(Self.table)))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        // A statement row for the same charge, into the same card, whose save hangs and then fails.
        let file = SourceSnapshot(source: .fileImport, accounts: [
            SourceAccount(externalID: "file", institution: "Summit Card", institutionDomain: nil, name: "Gold Card", kind: .credit,
                          balance: Money(-412.50), availableBalance: nil, balanceDate: EngineFixture.now,
                          transactions: [SourceTransaction(externalID: "f1", posted: EngineFixture.day(0), amount: Money(-38), description: "TRADER JOE'S #552")], holdings: []),
        ], warnings: [])
        await persistence.holdNextSave(failing: true)
        let importing = Task { try await api.ingest(file, batchID: "file-1", into: "plaid:summit-1") }
        while await !persistence.isHolding { await Task.yield() }
        let syncing = Task { try await api.ingest(Self.oneRow("p9", "TRADER JOE S #552", -38), batchID: "sync-2") }
        for _ in 0..<50 { await Task.yield() }
        await persistence.release()
        await #expect(throws: BudgetAPIError.self) { try await importing.value }
        let report = try await syncing.value
        #expect(report.rowsAdded == 1 && report.duplicatesSkipped == 0)
        #expect(await persistence.saves.last?.transactions.contains { $0.id == "plaid:p9" } == true)
        #expect(await api.state.transactions.contains { $0.id == "plaid:p9" })
    }

    @Test("A re-check that reaches the model clears the 'couldn't be reached' note on what it leaves waiting")
    func rerunClearsStaleNote() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: DownDecisions()))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        await api.reconfigure(chatModel: nil, decisions: DecisionRouting(local: StubDecisions(Self.table)))
        _ = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(rerunPending: true)))
        let state = await api.state
        #expect(state.transactions.allSatisfy { state.reviewReasons[$0.id] != Categorizer.modelUnreachableReason })
        #expect(state.transactions.first { $0.id == "plaid:p3" }?.categorization?.needsReview == true)   // PayPal at 45%
    }

    @Test("Turning the model on with a re-run keeps the setting when the model can't be reached")
    func policyChangeSurvivesRerunFailure() async throws {
        let persistence = RecordingPersistence()
        var state = LedgerState.empty
        state.accounts = Small.accounts
        state.transactions = [Small.row("a", at: Small.date(2026, 9, 20), -45, category: "shopping", raw: "NEW PLACE", tier: .model, needsReview: true)]
        let api = LedgerBudgetAPI(state: state, calendar: Small.calendar, clock: { Small.date(2026, 9, 25) }, chatModel: nil,
                                  decisions: DecisionRouting(local: DownDecisions()), persistence: persistence,
                                  deployment: DeploymentInfo(endpoint: "x", version: "x", sources: [], institutions: []))
        let result = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .localDecide, autoAcceptPercent: 80)))
        #expect(result.message.contains("Couldn't re-check the review queue"))
        let saved = try #require(await persistence.saves.last?.new)
        #expect(saved.decisionPolicy.provider == .localDecide && saved.decisionPolicy.isActive)
    }

    @Test("A re-check of what the model filed leaves rows the person changed meanwhile alone")
    func recheckRespectsConfirms() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions(Self.table)))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        let gate = GatedDecisions(["NETFLIX": ("entertainment", 0.97), "CASA TACO": ("groceries", 0.97)])
        await api.reconfigure(chatModel: nil, decisions: DecisionRouting(local: gate))
        let recheck = Task { try await api.recheckModelFiled(apply: true) }
        await Self.waitFor(gate)
        _ = try await api.confirmCategory(transactionID: "plaid:p1", categoryID: "dining")
        await gate.release()
        _ = try await recheck.value
        let taco = try #require(await api.state.transactions.first { $0.id == "plaid:p1" }?.categorization)
        #expect(taco.categoryID == "dining" && taco.tier == .user)
    }
}

@Suite("Currencies")
struct CurrencyTests {
    @Test("A zero takes the other side's currency, and two currencies no longer trap")
    func noTrap() {
        #expect([Money(12, currencyCode: "CAD")].sum() == Money(12, currencyCode: "CAD"))
        #expect(Money(5) + Money(minorUnits: 0, currencyCode: "CAD") == Money(5))
        // No exchange rate, so this adds in the left side's currency — wrong, but not a crash that takes the server down.
        #expect(Money(5) + Money(3, currencyCode: "CAD") == Money(8))
    }

    @Test("Ingest sets aside an account in another currency, and a stray row in one, with warnings")
    func setAside() async throws {
        let api = EngineFixture.api()
        var snapshot = EngineFixture.plaidSnapshot()
        snapshot.accounts.append(SourceAccount(externalID: "cad-1", institution: "Maple Bank", institutionDomain: nil, name: "Chequing", kind: .checking,
                                               balance: Money(900, currencyCode: "CAD"), availableBalance: nil, balanceDate: EngineFixture.now,
                                               transactions: [SourceTransaction(externalID: "c1", posted: EngineFixture.day(1), amount: Money(-20, currencyCode: "CAD"), description: "TIM HORTONS")],
                                               holdings: []))
        snapshot.accounts[0].transactions.append(SourceTransaction(externalID: "p6", posted: EngineFixture.day(6), amount: Money(-9, currencyCode: "EUR"), description: "CAFE ROMA"))
        let report = try await api.ingest(snapshot, batchID: "sync-1")
        #expect(report.accountsAdded == 1 && report.rowsAdded == 5)
        #expect(report.warnings.contains { $0.contains("Set aside Chequing") && $0.contains("CAD") })
        #expect(report.warnings.contains { $0.contains("Skipped 1 transaction on Gold Card") })
        let state = await api.state
        #expect(state.accounts.allSatisfy { $0.balance.currencyCode == Ledger.homeCurrency })
        #expect(state.transactions.allSatisfy { $0.amount.currencyCode == Ledger.homeCurrency })
        _ = try await api.overview()
    }

    @Test("Plaid's unofficial currencies and an OFX statement's CURDEF keep their currency, so ingest can set them aside")
    func sourcesKeepTheirCurrency() throws {
        let accounts = try PlaidSource.parseAccounts(try JSONValue.parse(Data(#"{"accounts":[{"account_id":"btc","name":"Crypto","type":"investment","balances":{"current":0.5,"iso_currency_code":null,"unofficial_currency_code":"BTC"}}]}"#.utf8)), institution: "X")
        #expect(accounts.first?.balance.currencyCode == "BTC")
        let row = PlaidSource.transaction(try JSONValue.parse(Data(#"{"transaction_id":"t","account_id":"a","amount":1.25,"date":"2026-09-20","name":"X","iso_currency_code":null,"unofficial_currency_code":"BTC"}"#.utf8)))
        #expect(row?.transaction.amount.currencyCode == "BTC")
        let ofx = "<OFX><CURDEF>CAD<BANKACCTFROM><ACCTID>1234</BANKACCTFROM><STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260920<TRNAMT>-12.00<FITID>1<NAME>CAFE</STMTTRN><LEDGERBAL><BALAMT>100.00</LEDGERBAL></OFX>"
        let snapshot = try FileImport.parse(ofx, ids: .test)
        #expect(snapshot.accounts.first?.balance.currencyCode == "CAD")
        #expect(snapshot.accounts.first?.transactions.first?.amount.currencyCode == "CAD")
    }
}

@Suite("Chat dialects")
struct ChatDialectTests {
    @Test("Known hosted APIs pick their dialect; anything else keeps the self-hosted shape")
    func detect() {
        #expect(ChatDialect.detect(URL(string: "https://api.openai.com/v1")!) == .openAI)
        #expect(ChatDialect.detect(URL(string: "https://openrouter.ai/api")!) == .standard)
        #expect(ChatDialect.detect(URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!) == .standard)
        #expect(ChatDialect.detect(URL(string: "https://api.anthropic.com/v1/")!) == .standard)
        #expect(ChatDialect.detect(URL(string: "https://abc123.example.olares.com")!) == .selfHosted)
        #expect(ChatDialect.detect(URL(string: "http://localhost:11434")!) == .selfHosted)
    }

    @Test("A self-hosted engine gets exactly the bytes it got before")
    func selfHostedGolden() throws {
        let body = OpenAIChatModel(baseURL: URL(string: "https://x")!, model: "qwen3.8-27b").body(ChatRequest(messages: [.system("s"), .user("hi")]))
        #expect(String(decoding: try body.data(), as: UTF8.self)
                == #"{"chat_template_kwargs":{"enable_thinking":false},"max_tokens":1200,"messages":[{"content":"s","role":"system"},{"content":"hi","role":"user"}],"model":"qwen3.8-27b","temperature":0}"#)
    }

    @Test("On OpenRouter, zero retention adds Jev's provider routing to every chat request; nowhere else, and not when it's off")
    func openRouterZeroRetention() {
        let request = ChatRequest(messages: [.user("hi")])
        func provider(_ address: String, _ zeroRetention: Bool) -> JSONValue? {
            guard case let .object(o) = OpenAIChatModel(baseURL: URL(string: address)!, model: "m", zeroRetention: zeroRetention).body(request) else { return nil }
            return o["provider"]
        }
        #expect(provider("https://openrouter.ai/api/v1", true) == .object(["zdr": .bool(true), "data_collection": .string("deny")]))
        #expect(provider("https://openrouter.ai/api/v1", false) == nil)
        #expect(provider("https://api.openai.com", true) == nil)
        #expect(provider("https://openrouter.ai.evil.example", true) == nil)
        #expect(OpenAIChatModel.isOpenRouter(URL(string: "https://eu.openrouter.ai/api")!))
        #expect(!OpenAIChatModel.isOpenRouter(URL(string: "https://notopenrouter.ai")!))
    }

    @Test("Hosted APIs don't get the template switch; OpenAI's reasoning models get room to think and no temperature, its others keep theirs")
    func bodies() {
        let request = ChatRequest(messages: [.user("hi")], tools: .array([]))
        func fields(_ address: String, _ model: String = "m", refused: ChatFieldsRefused = []) -> [String: JSONValue] {
            guard case let .object(o) = OpenAIChatModel(baseURL: URL(string: address)!, model: model).body(request, refused: refused) else { return [:] }
            return o
        }
        #expect(Set(fields("https://openrouter.ai/api").keys) == ["model", "messages", "temperature", "max_tokens", "tools"])
        #expect(Set(fields("https://api.openai.com", "gpt-4o").keys) == ["model", "messages", "temperature", "max_completion_tokens", "tools"])
        #expect(fields("https://api.openai.com", "gpt-4o")["max_completion_tokens"] == .number(1200))
        let reasoning = fields("https://api.openai.com", "gpt-5.4")
        #expect(Set(reasoning.keys) == ["model", "messages", "max_completion_tokens", "reasoning_effort", "tools"])
        #expect(reasoning["max_completion_tokens"] == .number(25_000))
        #expect(reasoning["reasoning_effort"] == .string("none"))   // what these models need to call tools on Chat Completions
        #expect(fields("https://api.openai.com", "gpt-5-mini", refused: .reasoningNone)["reasoning_effort"] == .string("minimal"))
        #expect(fields("https://api.openai.com", "o3", refused: [.reasoningNone, .reasoningMinimal])["reasoning_effort"] == .string("low"))
        #expect(fields("https://api.openai.com", "o3", refused: [.reasoningNone, .reasoningMinimal, .reasoningEffort])["reasoning_effort"] == nil)
        // Behind Azure or a proxy (any name), a model that asked for "none" gets it.
        #expect(fields("https://r.openai.azure.com/openai", "my-deployment", refused: .reasoningNoneWanted)["reasoning_effort"] == .string("none"))
        #expect(ChatDialect.detect(URL(string: "https://r.openai.azure.com/openai/v1")!) == .openAI)
        #expect(OpenAIChatModel.isReasoningModel("o3-mini") && OpenAIChatModel.isReasoningModel("openai/gpt-6-luna"))
        #expect(!OpenAIChatModel.isReasoningModel("gpt-5-chat-latest") && !OpenAIChatModel.isReasoningModel("gpt-4.1"))
        // What a proxy refused is left out, or swapped for what it takes.
        let learned = fields("https://x", refused: [.chatTemplate, .maxTokens, .temperature])
        #expect(Set(learned.keys) == ["model", "messages", "max_completion_tokens", "tools"])
        #expect(learned["max_completion_tokens"] == .number(1200))   // the same budget, only under the other name
    }

    @Test("A 400 naming a field the request carried is recognized; one naming something else isn't")
    func refusals() {
        let sent: [String: JSONValue] = ["chat_template_kwargs": .object([:]), "max_tokens": .number(1), "temperature": .number(0)]
        #expect(ChatFieldsRefused.named(in: "Unrecognized request argument supplied: chat_template_kwargs", sent: sent) == .chatTemplate)
        #expect(ChatFieldsRefused.named(in: "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.", sent: sent) == .maxTokens)
        #expect(ChatFieldsRefused.named(in: "Unsupported value: 'temperature' does not support 0 with this model.", sent: sent) == .temperature)
        #expect(ChatFieldsRefused.named(in: "The model `m` does not exist", sent: sent) == nil)
        #expect(ChatFieldsRefused.named(in: "max_completion_tokens is too large", sent: ["max_completion_tokens": .number(1)]) == nil)
        // vLLM's context overflow names max_tokens but doesn't refuse it.
        #expect(ChatFieldsRefused.named(in: "'max_tokens' or 'max_completion_tokens' is too large: 1200. This model's maximum context length is 32768 tokens and your request has 31800 input tokens", sent: sent) == nil)
        let effort: [String: JSONValue] = ["reasoning_effort": .string("none")]
        #expect(ChatFieldsRefused.named(in: "Unsupported value: 'reasoning_effort' does not support 'none' with this model.", sent: effort) == .reasoningNone)
        #expect(ChatFieldsRefused.named(in: "Unsupported value: 'reasoning_effort' does not support 'minimal' with this model.", sent: ["reasoning_effort": .string("minimal")]) == .reasoningMinimal)
        #expect(ChatFieldsRefused.named(in: "Unsupported value: 'reasoning_effort' does not support 'low' with this model.", sent: ["reasoning_effort": .string("low")]) == .reasoningEffort)
        // Real wordings from providers and proxies.
        #expect(ChatFieldsRefused.named(in: "Function tools with reasoning_effort are not supported for gpt-5.6-sol in /v1/chat/completions. To use function tools, use /v1/responses or set reasoning_effort to 'none'.", sent: ["tools": .array([]), "temperature": .number(0)]) == .reasoningNoneWanted)
        #expect(ChatFieldsRefused.named(in: "temperature is deprecated for this model.", sent: sent) == .temperature)
        #expect(ChatFieldsRefused.named(in: "body.chat_template_kwargs: property 'body.chat_template_kwargs' is unsupported", sent: sent) == .chatTemplate)
        #expect(ChatFieldsRefused.named(in: "litellm.UnsupportedParamsError: O-series models don't support temperature=0. Only temperature=1 is supported.", sent: sent) == .temperature)
        // The owner's chain: none of these refuse a field we can drop.
        #expect(ChatFieldsRefused.named(in: "the request exceeds the available context size, try increasing it (exceed_context_size_error)", sent: sent) == nil)
        #expect(ChatFieldsRefused.named(in: "System role not supported", sent: sent) == nil)
    }

    @Test("Addresses resolve to one chat endpoint whatever their shape")
    func endpoints() {
        func endpoint(_ address: String) -> String { OpenAIChatModel(baseURL: URL(string: address)!, model: "m").endpoint.absoluteString }
        #expect(endpoint("https://x") == "https://x/v1/chat/completions")
        #expect(endpoint("https://x/") == "https://x/v1/chat/completions")
        #expect(endpoint("https://x/v1") == "https://x/v1/chat/completions")
        #expect(endpoint("https://x/v1/chat/completions") == "https://x/v1/chat/completions")
        #expect(endpoint("https://x/switchboard") == "https://x/switchboard/v1/chat/completions")
        #expect(endpoint("https://openrouter.ai/api") == "https://openrouter.ai/api/v1/chat/completions")
        #expect(endpoint("https://generativelanguage.googleapis.com/v1beta/openai/") == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        // Groq and Azure document ".../openai/v1"; the server strips the /v1 before this sees it.
        #expect(endpoint("https://api.groq.com/openai") == "https://api.groq.com/openai/v1/chat/completions")
        #expect(endpoint("https://r.openai.azure.com/openai") == "https://r.openai.azure.com/openai/v1/chat/completions")
        #expect(OpenAIChatModel.apiRoot(URL(string: "https://x")!).appending(path: "models").absoluteString == "https://x/v1/models")
    }
}

/// Answers decision requests by what they carry: a PAYPAL state is refused (400), an OUTAGE state gets a 401, anything
/// else is filed as dining.
final class DecisionStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = Self.body(of: request)
        let text = String(decoding: body, as: UTF8.self).uppercased()
        var status = 200
        var reply: String
        if text.contains("OUTAGE") {
            (status, reply) = (401, #"{"error":"invalid key"}"#)
        } else if text.contains("PAYPAL") {
            (status, reply) = (400, #"{"error":"rejected context"}"#)
        } else {
            reply = #"{"model":"m","answers":{"category":{"type":"choice","choice":"dining","probabilities":{"dining":0.97}}}}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Files from a table, but refuses (as a 400 about that one request would) any request for PAYPAL.
actor RefusingDecisions: DecisionModel {
    nonisolated let label = "refusing"
    nonisolated var runsLocally: Bool { true }
    let table: [String: (String, Double)]
    init(_ table: [String: (String, Double)]) { self.table = table }
    func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse] {
        requests.map { r in
            if r.state.uppercased().contains("PAYPAL") { return DecisionResponse(answers: [:], model: label, failure: "The model returned 400: rejected context") }
            let hit = table.first { r.state.uppercased().contains($0.key) }?.value ?? ("shopping", 0.3)
            return DecisionResponse(answers: [CategoryDecisions.questionID: DecisionAnswer(value: hit.0, confidence: hit.1, distribution: [hit.0: hit.1])], model: label)
        }
    }
}

@Suite("Decision failures: a refused request versus an outage")
struct DecisionFailureTests {
    static let question: DecisionQuestion = .choice(instructions: "Which category?", options: [(id: "dining", description: "Dining"), (id: "groceries", description: "Groceries")])
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DecisionStub.self]
        return URLSession(configuration: config)
    }
    static func requests(_ states: [String]) -> [DecisionRequest] { states.map { DecisionRequest(state: $0, questions: ["category": question]) } }

    @Test("Jev's shape: a request the model rejects comes back marked, and the rest are answered")
    func systemOneRefusal() async throws {
        let model = SystemOneDecisionModel(transport: .selfHosted(baseURL: URL(string: "https://decide.test")!, model: "m", apiKey: nil), session: Self.session)
        let out = try await model.decide(Self.requests(["SQ *TACO", "PAYPAL *XJ", "NETFLIX"]))
        #expect(out.map { $0.failure != nil } == [false, true, false])
        #expect(out[0].answers["category"]?.value == "dining")
    }

    @Test("Jev's shape: a key or credit problem stops the batch, so its rows wait to be asked again")
    func systemOneOutage() async throws {
        let model = SystemOneDecisionModel(transport: .selfHosted(baseURL: URL(string: "https://decide.test")!, model: "m", apiKey: nil), session: Self.session)
        await #expect(throws: DecisionError.self) { try await model.decide(Self.requests(["SQ *TACO", "OUTAGE", "NETFLIX"])) }
    }

    @Test("Clef: the request it refuses comes back marked failed, the rest are answered, an outage stops the batch")
    func selfHostedRefusal() async throws {
        let model = SystemOneDecisionModel(transport: .selfHosted(baseURL: URL(string: "https://decide.test")!, model: "clef", apiKey: nil), session: Self.session)
        let out = try await model.decide(Self.requests(["SQ *TACO", "PAYPAL *XJ", "NETFLIX", "SHELL OIL"]))
        #expect(out.map { $0.failure != nil } == [false, true, false, false])
        #expect(out[3].answers["category"]?.value == "dining")
        await #expect(throws: DecisionError.self) { try await model.decide(Self.requests(["SQ *TACO", "OUTAGE"])) }
    }

    @Test("Ingest: a refused merchant waits with its own reason and a warning, isn't passed to Jev, and the rest are filed")
    func ingestWithRefusal() async throws {
        var state = LedgerState.empty
        state.decisionPolicy = DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category], escalateToJev: true)
        state.rules = [BudgetRule(id: "rule-1", match: RuleMatch(merchantContains: "venmo"), categoryID: "transfer")]
        let jev = StubDecisions(["NETFLIX": ("subscriptions", 0.97)])
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil,
                                  decisions: DecisionRouting(local: RefusingDecisions(["CASA TACO": ("dining", 0.95), "NETFLIX": ("subscriptions", 0.6)]), jev: jev),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        let report = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        #expect(report.warnings.contains { $0.contains("couldn't answer 1 merchant") })
        #expect(await jev.calls == 1)   // Netflix only: PayPal was never judged locally
        let state2 = await api.state
        #expect(state2.reviewReasons["plaid:p3"] == Categorizer.modelRefusedReason)
        #expect(!state2.transactions.map(\.id).contains { state2.reviewReasons[$0] == Categorizer.modelUnreachableReason })
        #expect(state2.transactions.first { $0.id == "plaid:p4" }?.categorization?.categoryID == "subscriptions")
    }
}
