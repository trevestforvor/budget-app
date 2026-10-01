import BudgetKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Models section's Test: tries each job's model the way the job uses it — Ask's chat completion with a one-word
/// question, categorizing's `/v1/decision` (or Jev) with a made-up coffee charge — and lists the models the chat server
/// offers. Nothing from the ledger is sent. Each check gives up after `timeout` seconds.
enum ModelCheck {
    /// Where categorizing runs, as the Models section offers it.
    enum Categorizing: String, Decodable, Sendable {
        /// Nothing files transactions: everything waits for the person.
        case off
        /// `/v1/decision` on the chat model's server.
        case chat
        /// `/v1/decision` on a server of its own.
        case own
        /// Jev, in the cloud through OpenRouter.
        case jev
        /// Laya on the Olares: not tested here.
        case laya
    }

    struct Outcome: Encodable, Sendable {
        var ok: Bool
        /// Nothing set up to test.
        var off = false
        var address: String?
        var model: String?
        var milliseconds: Int?
        /// What happened, in plain words: what it answered, or what went wrong and what to change.
        var detail: String
    }

    struct Report: Encodable, Sendable {
        var chat: Outcome
        var categorize: Outcome
        /// The models the chat server lists (`GET /v1/models`); nil when it doesn't say.
        var models: [String]?
    }

    struct Setup: Sendable {
        var chat: URL?
        var chatKey: String?
        var model: String
        var categorizing: Categorizing
        var decision: URL?
        var decisionKey: String?
        var openRouterKey: String?
        var zeroRetention: Bool
    }

    static let timeout: Double = 45

    /// "https://x/v1/chat/completions", "https://x/v1/" and "https://x" are all the server at https://x: each job adds
    /// its own path.
    static func base(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        for suffix in ["/v1/chat/completions", "/chat/completions", "/v1/decision", "/v1"] where text.lowercased().hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text) ?? url
    }

    static func run(_ setup: Setup) async -> Report {
        let chatBase = setup.chat.map(base)
        async let listed = chatBase.asyncMap { await listModels(at: $0, key: setup.chatKey) }
        async let chat = chatOutcome(chatBase, key: setup.chatKey, model: setup.model)
        async let categorize = categorizeOutcome(setup, chatBase: chatBase)
        let models = await listed ?? nil
        var chatResult = await chat
        // The server answered but doesn't know the name: say which names it does know.
        if !chatResult.ok, !chatResult.off, let models, !models.isEmpty, !models.contains(setup.model) {
            chatResult.detail = "The server answered, but has no model named “\(setup.model)”. It offers: \(models.prefix(12).joined(separator: ", "))."
        }
        return Report(chat: chatResult, categorize: await categorize, models: models)
    }

    // MARK: Jobs

    private static func chatOutcome(_ base: URL?, key: String?, model: String) async -> Outcome {
        guard let base else {
            return Outcome(ok: false, off: true, detail: "No chat model address, so Ask gives simple built-in answers.")
        }
        let started = Date()
        do {
            let response = try await within(timeout) {
                try await OpenAIChatModel(baseURL: base, model: model, apiKey: key)
                    .complete(ChatRequest(messages: [.system("Reply with one word."), .user("Say OK.")], maxTokens: 32))
            }
            let said = (response.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cutOff = said.isEmpty && response.message.toolCalls.isEmpty && response.finishReason == "length"
            return Outcome(ok: true, address: base.absoluteString, model: model, milliseconds: ms(since: started),
                           detail: cutOff ? "It answered, but used this test's 32 tokens before saying anything, as a model that reasons first does. Ask gives it 1,200."
                                   : said.isEmpty ? "It answered." : "It answered “\(said.prefix(40))”.")
        } catch {
            return Outcome(ok: false, address: base.absoluteString, model: model, milliseconds: ms(since: started),
                           detail: explain(error, path: OpenAIChatModel(baseURL: base, model: model).endpoint.path, key: key, decision: false))
        }
    }

    private static func categorizeOutcome(_ setup: Setup, chatBase: URL?) async -> Outcome {
        let model: (any DecisionModel)?
        let address: String?
        switch setup.categorizing {
        case .off:
            return Outcome(ok: false, off: true, detail: "Off: everything Budget isn't sure about waits for you.")
        case .laya:
            return Outcome(ok: false, off: true, detail: "Laya isn't checked from here.")
        case .chat, .own:
            let decisionBase = setup.categorizing == .chat ? chatBase : setup.decision.map(base)
            guard let decisionBase else {
                return Outcome(ok: false, detail: setup.categorizing == .chat ? "It uses the chat model's server, and there's no chat model address."
                                                                            : "Add the categorizing model's address.")
            }
            address = decisionBase.absoluteString
            model = LlamaDecisionModel(baseURL: decisionBase, label: "test", apiKey: setup.decisionKey)
        case .jev:
            guard let key = setup.openRouterKey else { return Outcome(ok: false, detail: "Jev needs an OpenRouter key.") }
            address = "OpenRouter"
            model = SystemOneDecisionModel(transport: .openRouter(apiKey: key, zeroDataRetention: setup.zeroRetention))
        }
        let request = DecisionRequest(state: "Merchant: Test Coffee Shop. Money out.",
                                      questions: ["category": .choice(instructions: "Which category is this charge?",
                                                                      options: [(id: "dining", description: "Dining: restaurants and coffee"),
                                                                                (id: "groceries", description: "Groceries")])])
        let started = Date()
        do {
            let answers = try await within(timeout) { try await model!.decide([request]) }
            let value = answers.first?.answers["category"]?.value
            return Outcome(ok: value != nil, address: address, model: setup.categorizing == .jev ? "Jev" : nil, milliseconds: ms(since: started),
                           detail: value.map { "It filed a test coffee charge under “\($0)”." } ?? "It answered, but without a category.")
        } catch {
            return Outcome(ok: false, address: address, milliseconds: ms(since: started),
                           detail: explain(error, path: setup.categorizing == .jev ? "OpenRouter" : "/v1/decision", key: setup.categorizing == .jev ? setup.openRouterKey : setup.decisionKey,
                                           decision: setup.categorizing != .jev))
        }
    }

    /// The model names a server lists at `GET /v1/models` (under its API root, as chat uses), or nil when it doesn't answer that.
    static func listModels(at base: URL, key: String?) async -> [String]? {
        var request = URLRequest(url: OpenAIChatModel.apiRoot(base).appending(path: "models"))
        request.timeoutInterval = 15
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return nil }
        return entries.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: Plumbing

    struct TimedOut: Error {}

    /// `work`, or `TimedOut` once `seconds` pass.
    static func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    /// What went wrong, and what to change, in plain words.
    static func explain(_ error: any Error, path: String, key: String?, decision: Bool) -> String {
        if error is TimedOut { return "No answer in \(Int(timeout)) seconds. It may still be loading the model; try again in a minute." }
        if let error = error as? DecisionError, case let .http(status, body) = error {
            let said = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
            switch status {
            case 401, 403:
                return key == nil ? "It wants an API key (\(status)). Add one above." : "It turned the API key down (\(status)). Check the key."
            case 404 where decision:
                return "This server has no /v1/decision (404). Categorizing needs the decision server (the llama.cpp one on your Olares): choose Its own server and put that address in."
            case 404:
                return "Nothing at \(path) on this server (404). Check the address." + (said.isEmpty ? "" : " It said: \(said)")
            default:
                return "The server answered \(status)." + (said.isEmpty ? "" : " It said: \(said)")
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed: return "Can't find that server. Check the address."
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet: return "Can't reach that server. Is it running?"
            case .timedOut: return "No answer in time. It may still be loading the model; try again in a minute."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot:
                return "Couldn't make a secure connection to that server."
            default: return error.localizedDescription
            }
        }
        if let error = error as? DecisionError, case let .malformed(what) = error {
            return "It answered, but not the way Budget expects: \(what.prefix(160))"
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
