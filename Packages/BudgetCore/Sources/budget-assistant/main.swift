import BudgetKit
import Foundation

// Prints what the `chat` model is given, or runs it live against the demo ledger.
//   swift run budget-assistant tools | prompt | catalog
//   swift run budget-assistant ask "What's my DoorDash budget?" [--think] [--base URL]
//   swift run budget-assistant decide [--base URL | --shim URL] [--percent N]   (review queue through the decision model)
//   swift run budget-assistant eval [--provider qwen|jev|<shim URL>] [--repeat N]  (labeled categorization eval)
//   swift run budget-assistant eval --provider openrouter:<model> [--confidence logprobs|verbalized] [--providers a,b]
//   swift run budget-assistant ask-eval --model <openrouter model> [--providers a,b] [--reasoning low] [--max-tokens N] [--repeat N]
//   swift run budget-assistant backlog                                             (rows vs unique descriptors)
let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
/// The model server for the live commands: `--base URL` or BUDGET_MODEL_BASE.
var base: URL {
    guard let text = option("--base") ?? ProcessInfo.processInfo.environment["BUDGET_MODEL_BASE"], let url = URL(string: text) else {
        print("Live commands need a model server: pass --base URL or set BUDGET_MODEL_BASE.")
        exit(2)
    }
    return url
}

let offline = DemoBudgetAPI(latency: .zero)
let pretty = JSONEncoder()
pretty.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

switch args.first ?? "tools" {
case "prompt":
    print(try await offline.assistantConfig().systemPrompt)
case "catalog":
    print(String(decoding: try pretty.encode(try await offline.assistantConfig().tools), as: UTF8.self))
case "ask":
    guard args.count > 1 else { print("usage: ask \"question\" [--think]"); exit(2) }
    let api = DemoBudgetAPI.live(baseURL: base)
    let started = Date()
    let outcome = try await api.askLive(args[1], thinking: args.contains("--think"))
    print("Q: \(args[1])")
    print("A: \(outcome.reply.text)")
    for call in outcome.reply.toolCalls { print("   tool  \(call.name)(\(call.displayArguments))") }
    for figure in outcome.reply.figures { print("   fig   \(figure.label): \(figure.value.display)") }
    for proposal in outcome.reply.proposedActions {
        print("   card  \(proposal.title)" + (proposal.effects.isEmpty ? "" : " — " + proposal.effects.map { "\($0.label) \($0.value.display)" }.joined(separator: ", ")))
    }
    print("   steps \(outcome.steps), schema repairs \(outcome.repairs), ungrounded \(outcome.ungrounded.isEmpty ? "none" : outcome.ungrounded.joined(separator: " ")), \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
case "decide":
    // --shim URL points decisions at a different /v1/systemone server than the chat base.
    let api: DemoBudgetAPI
    if let shim = option("--shim").flatMap(URL.init(string:)) {
        let model = try DecisionModels.make(.localDecide, DecisionEndpoints(qwenDecide: shim))
        api = DemoBudgetAPI(latency: .zero, decisionModel: model)
        print("via /v1/systemone at \(shim.absoluteString)")
    } else {
        api = DemoBudgetAPI.live(baseURL: base)
        print("via /v1/systemone at \(base.absoluteString)")
    }
    let pending = try await api.reviewQueue()
    let started = Date()
    let result = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .localDecide, autoAcceptPercent: Int(option("--percent") ?? "80") ?? 80)))
    print(result.message, String(format: "(%.2fs)", Date().timeIntervalSince(started)))
    for item in pending {
        let row = try await api.transactions(TransactionFilter(search: item.transaction.merchant)).first { $0.id == item.id }
        let c = row?.categorization
        print("   \(item.transaction.merchant.padding(toLength: 20, withPad: " ", startingAt: 0)) → \(c?.categoryID ?? "?") \(Int(((c?.confidence ?? 0) * 100).rounded()))%\(c?.needsReview == true ? "  (review)" : "  accepted")")
    }
case "eval":
    // Labeled categorization eval. --provider qwen (default, /v1/systemone on the base URL) | jev (needs OPENROUTER_API_KEY
    // or TYPESAFE_API_KEY) | shim URL. --repeat N multiplies the set to measure throughput.
    let categories = try await offline.categories()
    let provider = option("--provider") ?? "qwen"
    let model: any DecisionModel
    switch provider {
    case "jev":
        let env = ProcessInfo.processInfo.environment
        if let key = env["OPENROUTER_API_KEY"], !key.isEmpty {
            model = SystemOneDecisionModel(transport: .openRouter(apiKey: key), maxConcurrent: Int(option("--concurrency") ?? "4") ?? 4)
        } else if let key = env["TYPESAFE_API_KEY"], !key.isEmpty {
            model = SystemOneDecisionModel(transport: .typeSafe(apiKey: key), maxConcurrent: Int(option("--concurrency") ?? "4") ?? 4)
        } else {
            print("Set OPENROUTER_API_KEY or TYPESAFE_API_KEY to evaluate Jev."); exit(2)
        }
    case "qwen": model = SystemOneDecisionModel(transport: .selfHosted(baseURL: base, model: "clef", apiKey: nil))
    case let p where p.hasPrefix("openrouter:"):
        // A chat model on OpenRouter answering the same question (eval only; see ChatDecisionModel).
        guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else { print("Set OPENROUTER_API_KEY."); exit(2) }
        model = ChatDecisionModel(model: String(p.dropFirst("openrouter:".count)), apiKey: key,
                                  confidence: ChatDecisionModel.Confidence(rawValue: option("--confidence") ?? "logprobs") ?? .logprobs,
                                  providers: option("--providers")?.split(separator: ",").map(String.init) ?? [],
                                  maxConcurrent: Int(option("--concurrency") ?? "8") ?? 8)
    default:
        guard let url = URL(string: provider) else { print("unknown provider"); exit(2) }
        // --system2 off|auto|always is the jevshim's per-request switch for its think-then-rescore pass.
        let extra: [String: JSONValue] = option("--system2").map { ["system2": .string($0)] } ?? [:]
        model = SystemOneDecisionModel(transport: .selfHosted(baseURL: url, model: "qwen3.8-27b-decide · system2 \(option("--system2") ?? "auto")", apiKey: nil),
                                       maxConcurrent: 4, extraFields: extra)
    }
    print("Eval \(CategorizeEval.version)")
    print(CategorizeEval.markdown(try await CategorizeEval.run(model, categories: categories, repeatCount: Int(option("--repeat") ?? "1") ?? 1)))
    if model is ChatDecisionModel {
        let t = ChatDecisionModel.totals
        print("Cost $\(String(format: "%.4f", t.cost)), \(t.prompt) prompt and \(t.completion) completion tokens, providers \(t.provider ?? "?"), reasoning-off fallbacks \(ChatDecisionModel.fallbacks), failed requests \(ChatDecisionModel.failures.count).")
        for f in ChatDecisionModel.failures.prefix(5) { print("   failed: \(f.prefix(300))") }
    }
case "ask-eval":
    // Ask scenarios on the demo ledger through a model on OpenRouter, with the app's own agent loop and client.
    guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else { print("Set OPENROUTER_API_KEY."); exit(2) }
    guard let modelID = option("--model") else { print("usage: ask-eval --model <id>"); exit(2) }
    var inject: [String: JSONValue] = ["usage": .object(["include": .bool(true)])]
    var settings = ["default routing"]
    if let providers = option("--providers")?.split(separator: ",").map(String.init) {
        inject["provider"] = .object(["order": .array(providers.map(JSONValue.string)), "allow_fallbacks": .bool(false)])
        settings = ["providers \(providers.joined(separator: ">"))"]
    }
    if let effort = option("--reasoning") {
        inject["reasoning"] = .object(["effort": .string(effort)])
        settings.append("reasoning \(effort)")
    } else {
        settings.append("model's default reasoning")
    }
    EvalTransport.inject = inject
    if let max = option("--max-tokens").flatMap(Int.init) { EvalTransport.maxTokens = max; settings.append("max_tokens \(max)") } else { settings.append("app's max_tokens") }
    let runs = await AskEval.run(model: modelID, apiKey: key, repeats: Int(option("--repeat") ?? "1") ?? 1,
                                 concurrency: Int(option("--concurrency") ?? "6") ?? 6, only: option("--only").map { Set($0.split(separator: ",").map(String.init)) })
    print(AskEval.markdown(model: modelID, settings: settings.joined(separator: ", "), runs))
    if let out = option("--jsonl") { try AskEval.jsonl(model: modelID, runs).write(toFile: out, atomically: true, encoding: .utf8) }
case "backlog":
    // How much of a history needs a model at all: merchant memory resolves repeats of a descriptor.
    let rows = try await offline.transactions(TransactionFilter(limit: 100_000))
    let unique = Set(rows.map { Descriptor.normalize($0.rawDescription) })
    let days = Double(Calendar.current.dateComponents([.day], from: rows.map(\.postedAt).min()!, to: rows.map(\.postedAt).max()!).day ?? 1)
    print("Demo ledger: \(rows.count) transactions over \(Int(days)) days → \(unique.count) unique normalized descriptors (\(Int(Double(unique.count) / Double(rows.count) * 100))% of rows need a first decision).")
    print("Per month: \(Int(Double(rows.count) / days * 30.4)) transactions.")
default:
    let categories = try await offline.categories()
    print(String(decoding: try ToolCatalog.openAITools(for: categories).data(pretty: true), as: UTF8.self))
}
