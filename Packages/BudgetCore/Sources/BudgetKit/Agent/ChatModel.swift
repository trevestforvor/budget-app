import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession/URLRequest on Linux
#endif

// OpenAI-compatible chat completions — what llama.cpp, vLLM, SGLang and LiteLLM serve, and OpenAI, OpenRouter, Gemini and
// others host. `ChatDialect` covers where they differ.

public struct ChatToolCall: Hashable, Sendable {
    public var id: String
    public var name: String
    /// JSON text, as the model produced it.
    public var arguments: String
}

public struct ChatMessage: Hashable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }

    public var role: Role
    public var content: String?
    public var toolCalls: [ChatToolCall]
    public var toolCallID: String?

    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: .system, content: text, toolCalls: [], toolCallID: nil) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: .user, content: text, toolCalls: [], toolCallID: nil) }
    public static func tool(_ id: String, _ content: String) -> ChatMessage { ChatMessage(role: .tool, content: content, toolCalls: [], toolCallID: id) }

    var wire: JSONValue {
        var o: [String: JSONValue] = ["role": .string(role.rawValue)]
        o["content"] = content.map(JSONValue.string) ?? (toolCalls.isEmpty ? .string("") : .null)
        if !toolCalls.isEmpty {
            o["tool_calls"] = .array(toolCalls.map { call in
                .object(["id": .string(call.id), "type": .string("function"),
                         "function": .object(["name": .string(call.name), "arguments": .string(call.arguments)])])
            })
        }
        if let toolCallID { o["tool_call_id"] = .string(toolCallID) }
        return .object(o)
    }
}

public struct ChatRequest: Sendable {
    public var messages: [ChatMessage]
    public var tools: JSONValue?
    /// Per-request reasoning control (Qwen3 `enable_thinking`): off for chat and categorize, on for plan.
    public var thinking: Bool
    public var temperature: Double
    public var maxTokens: Int

    public init(messages: [ChatMessage], tools: JSONValue? = nil, thinking: Bool = false, temperature: Double = 0, maxTokens: Int = 1200) {
        self.messages = messages
        self.tools = tools
        self.thinking = thinking
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

public struct ChatResponse: Sendable {
    public var message: ChatMessage
    public var finishReason: String?
    public var tokensPerSecond: Double?
}

public protocol ChatModel: Sendable {
    var label: String { get }
    func complete(_ request: ChatRequest) async throws -> ChatResponse
}

/// Which fields a server takes in the OpenAI chat shape. The engines you run accept extras like the chat template's
/// thinking switch; hosted APIs don't all, and OpenAI's own refuses any field it doesn't know. Whatever a server still
/// refuses is learned from its 400s (`ChatFieldsRefused`), so a proxy in front of a stricter API works without setup.
public enum ChatDialect: String, Sendable, Codable, CaseIterable {
    /// llama.cpp, vLLM, SGLang, LiteLLM and the like: `temperature`, `max_tokens`, and `chat_template_kwargs.enable_thinking`,
    /// which hybrid-reasoning templates (Qwen3's among them) read and others ignore.
    case selfHosted
    /// Hosted APIs that take the plain shape (OpenRouter, Gemini's OpenAI endpoint, Anthropic's compatibility layer, Groq…):
    /// no engine-specific fields.
    case standard
    /// api.openai.com: `max_completion_tokens`, and for its reasoning models no temperature and a reasoning effort.
    case openAI

    /// Hosts known to be hosted APIs; anything else is taken for an engine you run, so its requests don't change.
    public static func detect(_ url: URL) -> ChatDialect {
        guard let host = url.host?.lowercased() else { return .selfHosted }
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if ["api.openai.com", "openai.azure.com", "cognitiveservices.azure.com"].contains(where: matches) { return .openAI }
        let hosted = ["openrouter.ai", "generativelanguage.googleapis.com", "api.anthropic.com", "api.groq.com", "api.mistral.ai",
                      "api.together.xyz", "api.fireworks.ai", "api.deepseek.com", "api.x.ai"]
        return hosted.contains(where: matches) ? .standard : .selfHosted
    }
}

/// Optional request fields a server has refused with a 400 that names them. The request is sent again without the field
/// (or, for `max_tokens`, with `max_completion_tokens`; for `reasoning_effort` "none", with "low" first), and once that
/// works the refusal is remembered for that endpoint and model for a while.
public struct ChatFieldsRefused: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let chatTemplate = ChatFieldsRefused(rawValue: 1 << 0)
    public static let temperature = ChatFieldsRefused(rawValue: 1 << 1)
    public static let maxTokens = ChatFieldsRefused(rawValue: 1 << 2)
    /// `reasoning_effort` "none" wasn't accepted; "minimal" is tried next, then "low", then leaving it out.
    public static let reasoningNone = ChatFieldsRefused(rawValue: 1 << 3)
    public static let reasoningMinimal = ChatFieldsRefused(rawValue: 1 << 5)
    public static let reasoningEffort = ChatFieldsRefused(rawValue: 1 << 4)
    /// The one refusal that says what to add: a model that calls tools only at reasoning_effort "none" (OpenAI's newer
    /// ones, also behind Azure or a proxy whose model names can't be read).
    public static let reasoningNoneWanted = ChatFieldsRefused(rawValue: 1 << 6)

    /// Wording that says a parameter itself isn't accepted. A 400 that only mentions one (vLLM's "'max_tokens' … is too
    /// large" when the context overflows) isn't a refusal.
    static let refusalWording = ["unsupported", "unrecognized", "unknown parameter", "unknown field", "unknown name", "not permitted",
                                 "not supported", "does not support", "don't support", "do not support", "deprecated", "unexpected keyword",
                                 "additional properties", "incompatible request argument"]

    /// The field a 400's text refuses among the optional ones the request carried.
    static func named(in errorText: String, sent: [String: JSONValue]) -> ChatFieldsRefused? {
        let text = errorText.lowercased()
        guard refusalWording.contains(where: text.contains) else { return nil }
        if text.contains("reasoning_effort") {
            switch sent["reasoning_effort"] {
            case nil: if sent["tools"] != nil, text.contains("none") { return .reasoningNoneWanted }
            case .string("none")?: return .reasoningNone
            case .string("minimal")?: return .reasoningMinimal
            default: return .reasoningEffort
            }
        }
        let fields: [(String, ChatFieldsRefused)] = [("chat_template_kwargs", .chatTemplate), ("temperature", .temperature), ("max_tokens", .maxTokens)]
        return fields.first { sent[$0.0] != nil && text.contains($0.0) }?.1
    }
}

/// What each endpoint and model has refused, remembered for an hour so only the first request pays for learning it, and
/// a model swapped in behind the same name gets a fresh start.
final class RefusedChatFields: @unchecked Sendable {
    static let shared = RefusedChatFields()
    static let lifetime: TimeInterval = 60 * 60
    private let lock = NSLock()
    private var refused: [String: (fields: ChatFieldsRefused, since: Date)] = [:]

    func get(_ key: String, now: Date = Date()) -> ChatFieldsRefused {
        lock.lock(); defer { lock.unlock() }
        guard let entry = refused[key], now.timeIntervalSince(entry.since) < Self.lifetime else { return [] }
        return entry.fields
    }

    func set(_ fields: ChatFieldsRefused, for key: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        refused[key] = (fields, now)
    }
}

public struct OpenAIChatModel: ChatModel {
    public let baseURL: URL
    public let model: String
    public let dialect: ChatDialect
    private let apiKey: String?
    private let session: URLSession

    /// `dialect` defaults to what the address says (`ChatDialect.detect`).
    public init(baseURL: URL, model: String, apiKey: String? = nil, dialect: ChatDialect? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.dialect = dialect ?? .detect(baseURL)
        self.session = session
    }

    public var label: String { model }

    /// The API root an address stands for: "https://x" means https://x/v1. An address that already ends in its version
    /// ("…/v1", Gemini's "…/v1beta/openai") is kept, and "/chat/completions" at the end is dropped first. A bare "…/openai" isn't a root: Groq's and
    /// Azure's "…/openai/v1" arrive that way once the server strips "/v1", and get it back. Chat and the model list both
    /// hang off it.
    public static func apiRoot(_ base: URL) -> URL {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/chat/completions") { text.removeLast("/chat/completions".count) }
        let path = (URL(string: text)?.path ?? "").lowercased()
        let isRoot = path.range(of: #"/v[0-9]+[a-z0-9]*(/openai)?$"#, options: .regularExpression) != nil
        return URL(string: isRoot ? text : text + "/v1") ?? base
    }

    public var endpoint: URL { Self.apiRoot(baseURL).appending(path: "chat/completions") }

    /// Reasoning counts against `max_completion_tokens`; OpenAI suggests leaving about 25k for reasoning and the reply.
    static let reasoningBudget = 25_000

    /// OpenAI's reasoning models by name: the o-series and gpt-5 onward, but not their "-chat" variants.
    static func isReasoningModel(_ name: String) -> Bool {
        let id = name.lowercased().split(separator: "/").last.map(String.init) ?? ""
        guard !id.contains("-chat") else { return false }
        return id.range(of: #"^(o[0-9]|gpt-([5-9]|[1-9][0-9]))"#, options: .regularExpression) != nil
    }

    func body(_ request: ChatRequest, refused: ChatFieldsRefused = []) -> JSONValue {
        var o: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(request.messages.map(\.wire)),
        ]
        let reasoning = dialect == .openAI && Self.isReasoningModel(model)
        let completionTokens = dialect == .openAI || refused.contains(.maxTokens)
        o[completionTokens ? "max_completion_tokens" : "max_tokens"] = .number(Double(reasoning ? max(request.maxTokens, Self.reasoningBudget) : request.maxTokens))
        if !reasoning, !refused.contains(.temperature) { o["temperature"] = .number(request.temperature) }
        if dialect == .selfHosted, !refused.contains(.chatTemplate) {
            o["chat_template_kwargs"] = .object(["enable_thinking": .bool(request.thinking)])
        }
        // Thinking off: "none" where the model takes it (OpenAI's newer models only call tools on Chat Completions at
        // "none"), else "low", else the model's default.
        if (reasoning && !request.thinking) || refused.contains(.reasoningNoneWanted), !refused.contains(.reasoningEffort) {
            o["reasoning_effort"] = .string(refused.contains(.reasoningMinimal) ? "low" : refused.contains(.reasoningNone) ? "minimal" : "none")
        }
        if let tools = request.tools { o["tools"] = tools }
        return .object(o)
    }

    static func parse(_ json: JSONValue) throws -> ChatResponse {
        guard case let .object(root) = json, case let .array(choices)? = root["choices"], case let .object(choice)? = choices.first,
              case let .object(message)? = choice["message"] else {
            if case let .object(root) = json, case let .object(error)? = root["error"], case let .string(text)? = error["message"] {
                throw DecisionError.http(500, text)
            }
            throw DecisionError.malformed("no choices")
        }
        var calls: [ChatToolCall] = []
        if case let .array(raw)? = message["tool_calls"] {
            for (index, item) in raw.enumerated() {
                guard case let .object(c) = item, case let .object(f)? = c["function"], case let .string(name)? = f["name"] else { continue }
                let id: String = if case let .string(v)? = c["id"] { v } else { "call_\(index)" }
                let args: String = switch f["arguments"] {
                case let .string(text)?: text
                case let value?: (try? value.data()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                case nil: "{}"
                }
                calls.append(ChatToolCall(id: id, name: name, arguments: args))
            }
        }
        var content: String? = if case let .string(text)? = message["content"] { text } else { nil }
        content = content.map(stripThinking)
        let finish: String? = if case let .string(v)? = choice["finish_reason"] { v } else { nil }
        var speed: Double?
        if case let .object(t)? = root["timings"], case let .number(v)? = t["predicted_per_second"] { speed = v }
        return ChatResponse(message: ChatMessage(role: .assistant, content: content, toolCalls: calls, toolCallID: nil),
                            finishReason: finish, tokensPerSecond: speed)
    }

    /// Qwen3 with `reasoning_format: none` puts reasoning inline as <think>…</think>.
    static func stripThinking(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "<think>"), let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let close = s.range(of: "</think>") { s.removeSubrange(s.startIndex..<close.upperBound) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let key = endpoint.absoluteString + "|" + model
        let known = RefusedChatFields.shared.get(key)
        var refused = known
        while true {
            let sent = body(request, refused: refused)
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            urlRequest.httpBody = try sent.data()
            urlRequest.timeoutInterval = request.thinking ? 300 : 120
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                // Only what the retry proved is remembered.
                if refused != known { RefusedChatFields.shared.set(refused, for: key) }
                return try Self.parse(try JSONValue.parse(data))
            }
            let text = String(decoding: data, as: UTF8.self)
            // A 400 refusing an optional field it was sent (OpenAI and strict proxies do this) is answered by asking again
            // without it. Each round adds a different field, so this ends.
            if status == 400, case let .object(fields) = sent, let field = ChatFieldsRefused.named(in: text, sent: fields), !refused.contains(field) {
                refused.insert(field)
                continue
            }
            throw DecisionError.http(status, text)
        }
    }
}
