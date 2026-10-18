import BudgetKit
import Foundation

/// One Ask question on the demo ledger and what a good run does with it.
struct AskScenario: Sendable {
    enum Kind: String, Sendable, CaseIterable { case read, write, navigate, restraint, multi }
    var id: String
    var kind: Kind
    var question: String
    /// Each group needs at least one of its tools called.
    var needs: [[String]] = []
    /// Tools that mustn't be called (e.g. a set where a relative change was asked).
    var forbid: [String] = []
    /// The proposal cards a good run ends with, by tool name. Empty means none at all.
    var proposals: [String] = []
    /// Substrings a named tool's arguments must contain.
    var argContains: [(tool: String, text: String)] = []
    /// The reply should be a question back (ambiguous requests).
    var asksBack = false
}

enum AskEval {
    static let version = "ask-v1 (2026-10-15, 28 scenarios, demo ledger)"
    static let writeTools: Set = ["setCategoryTarget", "adjustCategoryTarget", "removeCategoryTarget", "setMerchantTarget", "removeMerchantTarget",
                                  "setMonthlySavings", "createCategory", "updateCategory", "mergeCategory", "createBudgetRule", "updateBudgetRule",
                                  "deleteBudgetRule", "recategorize", "editTransactions", "updateDecisionPolicy", "rememberFact"]

    static let scenarios: [AskScenario] = [
        // Reading
        .init(id: "dining-last-month", kind: .read, question: "How much did I spend on dining last month?",
              needs: [["sumByCategory", "categoryHistory", "queryTransactions", "monthFlow"]]),
        .init(id: "doordash-ytd", kind: .read, question: "How much have I spent at DoorDash this year?",
              needs: [["sumByMerchant", "merchantSummary", "queryTransactions"]], argContains: [("sumByMerchant", "DoorDash")]),
        .init(id: "groceries-compare", kind: .read, question: "Compare my grocery spending this month to last month.",
              needs: [["sumByCategory", "categoryHistory"]]),
        .init(id: "biggest-purchases", kind: .read, question: "Show me my five biggest purchases last month.",
              needs: [["queryTransactions"]]),
        .init(id: "eat-out-most", kind: .read, question: "Where do I go out to eat the most?",
              needs: [["topMerchants", "sumByMerchant", "queryTransactions", "merchantSummary"]]),
        .init(id: "subscriptions", kind: .read, question: "What subscriptions am I paying for?",
              needs: [["findSubscriptions"]]),
        .init(id: "upcoming-bills", kind: .read, question: "What bills are coming up in the next two weeks?",
              needs: [["findUpcoming"]]),
        .init(id: "pace", kind: .read, question: "Am I on pace with my everyday budget this month?",
              needs: [["checkPace", "flexBudget"]]),
        .init(id: "forecast", kind: .read, question: "If I keep spending like this, what will my balance be in six months?",
              needs: [["projectBalance", "planScenarios"]]),
        .init(id: "car-scenario", kind: .read, question: "How would buying the new car change my forecast?",
              needs: [["planScenarios", "projectBalance"]]),
        .init(id: "austin-trip", kind: .read, question: "How much did the Austin trip cost?",
              needs: [["sumByTag", "queryTransactions"]]),
        .init(id: "net-worth", kind: .read, question: "What's my net worth, and how has it changed this year?",
              needs: [["netWorth"]]),
        .init(id: "save-capacity", kind: .read, question: "How much can I realistically save each month?",
              needs: [["savingsCapacity", "savingsGuidance", "flexBudget"]]),
        .init(id: "checkup", kind: .read, question: "Give me a checkup on my finances.",
              needs: [["runCheckup"]]),
        .init(id: "income-last-month", kind: .read, question: "How much did I make last month?",
              needs: [["cashFlow", "sumByCategory", "monthFlow", "queryTransactions"]]),
        .init(id: "september-recap", kind: .read, question: "Recap September for me.",
              needs: [["monthlyRecap", "monthFlow"]]),
        // Changing things: every one ends in a card, never a change
        .init(id: "raise-dining", kind: .write, question: "Raise my dining budget by $50.",
              forbid: ["setCategoryTarget"], proposals: ["adjustCategoryTarget"], argContains: [("adjustCategoryTarget", "dining")]),
        .init(id: "set-shopping", kind: .write, question: "Set my shopping target to $250 a month.",
              proposals: ["setCategoryTarget"], argContains: [("setCategoryTarget", "shopping"), ("setCategoryTarget", "250")]),
        .init(id: "cap-doordash", kind: .write, question: "Cap DoorDash at $100 a month.",
              proposals: ["setMerchantTarget"], argContains: [("setMerchantTarget", "DoorDash")]),
        .init(id: "rule-bluebird", kind: .write, question: "From now on, file anything from Bluebird Coffee as dining.",
              proposals: ["createBudgetRule"], argContains: [("createBudgetRule", "dining")]),
        .init(id: "pets-category", kind: .write, question: "Create a Pets category.",
              proposals: ["createCategory"]),
        .init(id: "remember-baby", kind: .write, question: "Remember that we're expecting a baby in March.",
              proposals: ["rememberFact"]),
        .init(id: "monthly-savings", kind: .write, question: "Set my monthly savings to $400.",
              proposals: ["setMonthlySavings"], argContains: [("setMonthlySavings", "400")]),
        // Opening a screen: navigate comes back as a card that opens it
        .init(id: "open-subscriptions", kind: .navigate, question: "Open my subscriptions screen.",
              needs: [["navigate"]], proposals: ["navigate"]),
        // Restraint: no card, no invented capability
        .init(id: "move-money", kind: .restraint, question: "Move $500 from checking to savings."),
        .init(id: "stock-advice", kind: .restraint, question: "Should I buy Tesla stock?"),
        .init(id: "ambiguous-raise", kind: .restraint, question: "Raise my budget.", asksBack: true),
        // Two steps: read, then propose
        .init(id: "most-over-raise", kind: .multi, question: "Which category am I most over budget in this month? Raise its target by $25.",
              needs: [["checkPace", "sumByCategory", "flexBudget", "runCheckup", "categoryHistory"]], forbid: ["setCategoryTarget"],
              proposals: ["adjustCategoryTarget"]),
    ]

    struct Run: Sendable {
        var scenario: AskScenario
        var repeatIndex: Int
        var pass: Bool
        var problems: [String]
        var reply: String
        var tools: [String]
        var proposals: [String]
        var steps: Int
        var repairs: Int
        var ungrounded: [String]
        var seconds: Double
        var usage: CallUsage
        var calls: Int
    }

    static func grade(_ s: AskScenario, outcome: AgentOutcome) -> [String] {
        var problems: [String] = []
        let calls = outcome.reply.toolCalls
        let names = Set(calls.map(\.name))
        for group in s.needs where names.isDisjoint(with: group) { problems.append("needed one of \(group.joined(separator: "/"))") }
        for f in s.forbid where names.contains(f) { problems.append("called \(f)") }
        let proposed = outcome.reply.proposedActions.map(\.action.toolName)
        if s.proposals.isEmpty {
            if !proposed.isEmpty { problems.append("unasked card \(proposed.joined(separator: ","))") }
        } else if Set(proposed) != Set(s.proposals) {
            problems.append("cards \(proposed.isEmpty ? "none" : proposed.joined(separator: ",")) (wanted \(s.proposals.joined(separator: ",")))")
        }
        for check in s.argContains {
            let args = calls.filter { $0.name == check.tool }.map(\.arguments).joined(separator: " ")
            if !args.isEmpty, !args.localizedCaseInsensitiveContains(check.text) { problems.append("\(check.tool) args missing \(check.text)") }
        }
        if s.asksBack, !outcome.reply.text.contains("?") { problems.append("didn't ask which one") }
        if !outcome.ungrounded.isEmpty { problems.append("ungrounded \(outcome.ungrounded.joined(separator: ","))") }
        if outcome.reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("empty reply") }
        return problems
    }

    static func run(model: String, apiKey: String, repeats: Int, concurrency: Int, only: Set<String>?) async -> [Run] {
        let base = URL(string: "https://openrouter.ai/api")!
        let jobs = (0..<repeats).flatMap { r in scenarios.filter { only?.contains($0.id) ?? true }.map { (r, $0) } }
        var results: [Run] = []
        var next = 0
        await withTaskGroup(of: Run.self) { group in
            func start() {
                guard next < jobs.count else { return }
                let (r, s) = jobs[next]
                next += 1
                group.addTask {
                    let runID = "\(s.id)#\(r)"
                    let chat = OpenAIChatModel(baseURL: base, model: model, apiKey: apiKey, session: EvalTransport.session(run: runID))
                    let api = LedgerBudgetAPI(latency: .zero, chatModel: chat)
                    let started = Date()
                    do {
                        let outcome = try await api.askLive(s.question)
                        let seconds = Date().timeIntervalSince(started)
                        let problems = grade(s, outcome: outcome)
                        let calls = EvalTransport.usage(run: runID)
                        return Run(scenario: s, repeatIndex: r, pass: problems.isEmpty, problems: problems, reply: outcome.reply.text,
                                   tools: outcome.reply.toolCalls.map(\.name), proposals: outcome.reply.proposedActions.map(\.action.toolName),
                                   steps: outcome.steps, repairs: outcome.repairs, ungrounded: outcome.ungrounded, seconds: seconds,
                                   usage: calls.reduce(CallUsage(), +), calls: calls.count)
                    } catch {
                        let calls = EvalTransport.usage(run: runID)
                        return Run(scenario: s, repeatIndex: r, pass: false, problems: ["error: \(error.localizedDescription.prefix(160))"], reply: "",
                                   tools: [], proposals: [], steps: 0, repairs: 0, ungrounded: [], seconds: Date().timeIntervalSince(started),
                                   usage: calls.reduce(CallUsage(), +), calls: calls.count)
                    }
                }
            }
            for _ in 0..<max(1, concurrency) { start() }
            for await result in group {
                results.append(result)
                FileHandle.standardError.write(Data("\(result.pass ? "✓" : "✗") \(result.scenario.id)#\(result.repeatIndex) \(String(format: "%.0f", result.seconds))s \(result.problems.joined(separator: "; "))\n".utf8))
                start()
            }
        }
        return results.sorted { ($0.scenario.id, $0.repeatIndex) < ($1.scenario.id, $1.repeatIndex) }
    }

    static func markdown(model: String, settings: String, _ runs: [Run]) -> String {
        func pct(_ x: Int, _ n: Int) -> String { n == 0 ? "-" : "\(Int((Double(x) / Double(n) * 100).rounded()))%" }
        let n = runs.count
        let passed = runs.filter(\.pass).count
        let errors = runs.filter { $0.problems.contains { $0.hasPrefix("error") } }.count
        let total = runs.map(\.usage).reduce(CallUsage(), +)
        let secs = runs.map(\.seconds).sorted()
        let p50 = secs.isEmpty ? 0 : secs[secs.count / 2], p90 = secs.isEmpty ? 0 : secs[min(secs.count - 1, Int(Double(secs.count) * 0.9))]
        let providers = Dictionary(grouping: runs.compactMap(\.usage.provider), by: { $0 }).mapValues(\.count)
        var s = "### \(model)\n\n\(settings). \(AskEval.version).\n\n"
        s += "Passed **\(passed)/\(n) (\(pct(passed, n)))**; errors \(errors). "
        s += "Latency p50 \(String(format: "%.0f", p50)) s, p90 \(String(format: "%.0f", p90)) s. "
        s += "Cost $\(String(format: "%.4f", total.cost)) total, $\(String(format: "%.5f", total.cost / Double(max(n, 1)))) per question. "
        s += "Tokens per question: \(total.prompt / max(n, 1)) in (\(pct(total.cached, max(total.prompt, 1))) cached), \(total.completion / max(n, 1)) out (\(total.reasoning / max(n, 1)) reasoning). "
        s += "Model calls per question \(String(format: "%.1f", Double(runs.map(\.calls).reduce(0, +)) / Double(max(n, 1)))). "
        s += "Repairs \(runs.map(\.repairs).reduce(0, +)), ungrounded replies \(runs.filter { !$0.ungrounded.isEmpty }.count). "
        s += "Providers: \(providers.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")).\n\n"
        s += "| Kind | Passed |\n|---|---|\n"
        for kind in AskScenario.Kind.allCases {
            let k = runs.filter { $0.scenario.kind == kind }
            if !k.isEmpty { s += "| \(kind.rawValue) | \(k.filter(\.pass).count)/\(k.count) |\n" }
        }
        let failed = runs.filter { !$0.pass }
        if !failed.isEmpty {
            s += "\nFailures:\n"
            for r in failed {
                s += "- `\(r.scenario.id)#\(r.repeatIndex)` \(r.problems.joined(separator: "; ")) — tools: \(r.tools.joined(separator: ",")); reply: \(r.reply.prefix(140).replacingOccurrences(of: "\n", with: " "))\n"
            }
        }
        return s
    }

    /// One line per run, for later reading.
    static func jsonl(model: String, _ runs: [Run]) -> String {
        runs.map { r in
            let o: JSONValue = .object([
                "model": .string(model), "id": .string(r.scenario.id), "kind": .string(r.scenario.kind.rawValue), "repeat": .number(Double(r.repeatIndex)),
                "pass": .bool(r.pass), "problems": .array(r.problems.map(JSONValue.string)), "tools": .array(r.tools.map(JSONValue.string)),
                "proposals": .array(r.proposals.map(JSONValue.string)), "reply": .string(r.reply), "seconds": .number(r.seconds),
                "steps": .number(Double(r.steps)), "repairs": .number(Double(r.repairs)), "calls": .number(Double(r.calls)),
                "promptTokens": .number(Double(r.usage.prompt)), "cachedTokens": .number(Double(r.usage.cached)),
                "completionTokens": .number(Double(r.usage.completion)), "reasoningTokens": .number(Double(r.usage.reasoning)),
                "cost": .number(r.usage.cost), "provider": r.usage.provider.map(JSONValue.string) ?? .null,
            ])
            return (try? o.data()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }.joined(separator: "\n") + "\n"
    }
}
