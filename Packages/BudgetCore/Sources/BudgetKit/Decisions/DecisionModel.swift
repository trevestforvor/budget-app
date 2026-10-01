import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession/URLRequest on Linux
#endif

// A decision model reads a state and answers typed questions with probabilities, without
// writing text. Shapes follow the ones measured in ~/Developer/Olares/decision-bench:
// Jev / Laya `/v1/systemone` and the llama.cpp fork's `/v1/decision` (Qwen Decide).

public enum DecisionQuestion: Hashable, Sendable {
    /// Pick one option. `options` maps option id → description (may be empty).
    case choice(instructions: String, options: [(id: String, description: String)])
    /// Yes/no, answered as P(yes).
    case noul(instructions: String, whenTrue: String?, whenFalse: String?)
    /// Ordered scale; the answer is a level index.
    case score(instructions: String, levels: [String])

    public static func == (lhs: DecisionQuestion, rhs: DecisionQuestion) -> Bool { lhs.wire == rhs.wire }
    public func hash(into hasher: inout Hasher) { hasher.combine(wire) }

    /// Jev-shaped question object: `{type, instructions, criteria}`.
    var wire: JSONValue {
        switch self {
        case let .choice(instructions, options):
            return .object(["type": .string("choice"), "instructions": .string(instructions),
                            "criteria": .object(Dictionary(uniqueKeysWithValues: options.map { ($0.id, JSONValue.string($0.description)) }))])
        case let .noul(instructions, whenTrue, whenFalse):
            var criteria: [String: JSONValue] = [:]
            if let whenTrue { criteria["true"] = .string(whenTrue) }
            if let whenFalse { criteria["false"] = .string(whenFalse) }
            var o: [String: JSONValue] = ["type": .string("noul"), "instructions": .string(instructions)]
            if !criteria.isEmpty { o["criteria"] = .object(criteria) }
            return .object(o)
        case let .score(instructions, levels):
            return .object(["type": .string("score"), "instructions": .string(instructions), "criteria": .array(levels.map(JSONValue.string))])
        }
    }
}

/// One state and the questions asked about it.
public struct DecisionRequest: Hashable, Sendable {
    public var state: String
    public var questions: [String: DecisionQuestion]
    public var instructions: String

    public init(state: String, questions: [String: DecisionQuestion], instructions: String = "Answer each question about the given state using only the evidence given.") {
        self.state = state
        self.questions = questions
        self.instructions = instructions
    }
}

/// A normalized answer. `confidence` is the winning answer's probability.
public struct DecisionAnswer: Hashable, Sendable, Codable {
    public var value: String
    public var confidence: Double?
    /// Full distribution when the backend returns one (Jev/Laya do; /v1/decision doesn't).
    public var distribution: [String: Double]?

    public init(value: String, confidence: Double?, distribution: [String: Double]? = nil) {
        self.value = value
        self.confidence = confidence
        self.distribution = distribution
    }

    /// Options ranked by probability, best first. Falls back to the winner alone.
    public var ranked: [(id: String, probability: Double)] {
        if let distribution { return distribution.sorted { $0.value > $1.value }.map { ($0.key, $0.value) } }
        return [(value, confidence ?? 0)]
    }
}

public struct DecisionResponse: Hashable, Sendable {
    public var answers: [String: DecisionAnswer]
    public var model: String
    /// Set when the model rejected this one request (a 400 about its content, an answer that didn't parse) while the
    /// rest of the batch went through. An outage doesn't come back this way: `decide` throws.
    public var failure: String? = nil
}

public protocol DecisionModel: Sendable {
    /// Shown in the UI and stored on each decision, e.g. "jev-1.13" or "qwen3.8-27b-decide".
    var label: String { get }
    /// False when calls leave the Olares.
    var runsLocally: Bool { get }
    /// One response per request, in order. Backends that batch do so internally.
    func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse]
}

public enum DecisionError: LocalizedError, Equatable {
    case http(Int, String)
    case malformed(String)
    case missingKey
    case notConfigured(String)

    /// A failure about one request's content, not the model being unreachable: a 4xx other than auth, not-found or rate
    /// limits, or an answer that doesn't parse. The rest of a batch can still be answered.
    public static func isAboutTheRequest(_ error: any Error) -> Bool {
        switch error as? DecisionError {
        case let .http(status, _)?: [400, 409, 413, 415, 422].contains(status)
        case .malformed?: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .http(status, body): "The model returned \(status): \(body.prefix(200))"
        case let .malformed(detail): "Decision model response was malformed: \(detail)"
        case .missingKey: "No API key is configured for the decision model."
        case let .notConfigured(what): "\(what) isn't configured on the server."
        }
    }
}

// MARK: - Jev / Laya: POST /v1/systemone

public struct SystemOneDecisionModel: DecisionModel {
    public enum Transport: Sendable {
        /// `https://openrouter.ai/api/alpha/decisions`, model `typesafe/jev-1.13`.
        /// `zeroDataRetention` adds OpenRouter's provider routing flags (`zdr`, `data_collection: deny`,
        /// no fallbacks), so the call fails rather than reaching an endpoint that retains data.
        case openRouter(apiKey: String, zeroDataRetention: Bool = false)
        /// `https://api.typesafe.ai/v1/systemone`, model `jev-latest`.
        case typeSafe(apiKey: String)
        /// A self-hosted engine with the same wire shape (e.g. Laya on the Olares).
        case selfHosted(baseURL: URL, model: String, apiKey: String?)
    }

    public let transport: Transport
    /// Requests in flight at once. The API takes one state per call, so backfills need parallelism;
    /// decision-bench ran Jev at 4 concurrent (~21 decisions/s). Keep it modest for rate limits.
    public let maxConcurrent: Int
    /// Extra top-level request fields for self-hosted engines, e.g. the jevshim's
    /// `"system2": "off"` (Jev itself has no such field, so these are never sent to Jev).
    public let extraFields: [String: JSONValue]
    private let session: URLSession

    public init(transport: Transport, maxConcurrent: Int = 4, extraFields: [String: JSONValue] = [:], session: URLSession = .shared) {
        self.transport = transport
        self.maxConcurrent = max(1, maxConcurrent)
        self.extraFields = extraFields
        self.session = session
    }

    public var label: String {
        switch transport {
        case .openRouter: "typesafe/jev-1.13"
        case .typeSafe: "jev-latest"
        case let .selfHosted(_, model, _): model
        }
    }

    public var runsLocally: Bool {
        if case .selfHosted = transport { return true }
        return false
    }

    var endpoint: (url: URL, model: String, key: String?) {
        switch transport {
        case let .openRouter(key, _): (URL(string: "https://openrouter.ai/api/alpha/decisions")!, "typesafe/jev-1.13", key)
        case let .typeSafe(key): (URL(string: "https://api.typesafe.ai/v1/systemone")!, "jev-latest", key)
        case let .selfHosted(base, model, key): (base.appending(path: "v1/systemone"), model, key)
        }
    }

    /// `{"model", "state", "questions"}`
    func body(for request: DecisionRequest) -> JSONValue {
        var o: [String: JSONValue] = ["model": .string(endpoint.model), "state": .string(request.state),
                                      "questions": .object(request.questions.mapValues(\.wire))]
        if case .openRouter(_, true) = transport {
            o["provider"] = .object(["zdr": .bool(true), "data_collection": .string("deny"), "allow_fallbacks": .bool(false)])
        }
        if case .selfHosted = transport {
            for (key, value) in extraFields { o[key] = value }
        }
        return .object(o)
    }

    /// `{"model", "answers": {id: {type, choice|noul|score, probabilities?, confidence?}}, "usage"}`
    static func parse(_ json: JSONValue, questions: [String: DecisionQuestion], fallbackModel: String) throws -> DecisionResponse {
        guard case let .object(root) = json, case let .object(rawAnswers)? = root["answers"] else { throw DecisionError.malformed("no answers object") }
        var answers: [String: DecisionAnswer] = [:]
        for (id, question) in questions {
            guard case let .object(a)? = rawAnswers[id] else { continue }
            let distribution: [String: Double]? = {
                guard case let .object(p)? = a["probabilities"] else { return nil }
                return p.compactMapValues { if case let .number(n) = $0 { n } else { nil } }
            }()
            switch question {
            case .choice:
                guard case let .string(choice)? = a["choice"] else { continue }
                answers[id] = DecisionAnswer(value: choice, confidence: distribution?[choice] ?? distribution?.values.max(), distribution: distribution)
            case .noul:
                guard case let .number(pTrue)? = a["noul"] else { continue }
                answers[id] = DecisionAnswer(value: pTrue >= 0.5 ? "true" : "false", confidence: max(pTrue, 1 - pTrue),
                                             distribution: ["true": pTrue, "false": 1 - pTrue])
            case .score:
                if let best = distribution?.max(by: { $0.value < $1.value }) {
                    answers[id] = DecisionAnswer(value: best.key, confidence: best.value, distribution: distribution)
                } else if case let .number(level)? = a["score"] {
                    answers[id] = DecisionAnswer(value: String(Int(level.rounded())), confidence: nil)
                }
            }
        }
        var model = fallbackModel
        if case let .string(served)? = root["model"] { model = served }
        return DecisionResponse(answers: answers, model: model)
    }

    func decideOne(_ request: DecisionRequest) async throws -> DecisionResponse {
        var urlRequest = URLRequest(url: endpoint.url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = endpoint.key { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try body(for: request).data()
        urlRequest.timeoutInterval = 60
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                return try Self.parse(try JSONValue.parse(data), questions: request.questions, fallbackModel: endpoint.model)
            }
            // Back off on rate limits and transient errors, up to 3 retries.
            guard [429, 500, 502, 503, 504].contains(status), attempt < 3 else { throw DecisionError.http(status, String(decoding: data, as: UTF8.self)) }
            attempt += 1
            try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
        }
    }

    /// One call per state, `maxConcurrent` at a time, results in request order. A request the model rejects for its
    /// content comes back marked `failure`, so one descriptor it always refuses can't hold back the rest; anything that
    /// means the model can't be reached (a timeout, 5xx or 429 after retries, a key or credit problem) stops the batch.
    public func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse] {
        var results = [DecisionResponse?](repeating: nil, count: requests.count)
        let model = endpoint.model
        try await withThrowingTaskGroup(of: (Int, DecisionResponse).self) { group in
            var next = 0
            func launch() {
                let index = next
                next += 1
                group.addTask {
                    do { return (index, try await decideOne(requests[index])) } catch where DecisionError.isAboutTheRequest(error) {
                        return (index, DecisionResponse(answers: [:], model: model, failure: error.localizedDescription))
                    }
                }
            }
            while next < min(maxConcurrent, requests.count) { launch() }
            while let (index, response) = try await group.next() {
                results[index] = response
                if next < requests.count { launch() }
            }
        }
        return results.map { $0! }
    }
}

// MARK: - Qwen Decide: POST /v1/decision (llama.cpp fork)

public struct LlamaDecisionModel: DecisionModel {
    public let baseURL: URL
    public let model: String?
    public let label: String
    /// Sent as a bearer token, for a decision server behind a router that asks for one.
    public let apiKey: String?
    /// The endpoint accepts up to 256 contexts sharing one schema.
    public let maxBatch: Int
    private let session: URLSession

    public init(baseURL: URL, model: String? = nil, label: String = "qwen3.8-27b-decide", maxBatch: Int = 256, apiKey: String? = nil,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.label = label
        self.apiKey = apiKey
        self.maxBatch = maxBatch
        self.session = session
    }

    public var runsLocally: Bool { true }

    /// Field description = instructions plus the option catalog (the endpoint requires one).
    static func description(_ q: DecisionQuestion) -> String {
        switch q {
        case let .choice(instructions, options):
            return instructions + "\nOptions:\n" + options.map { $0.description.isEmpty ? $0.id : "\($0.id): \($0.description)" }.joined(separator: "\n")
        case let .noul(instructions, whenTrue, whenFalse):
            return ([instructions] + [whenTrue.map { "true: \($0)" }, whenFalse.map { "false: \($0)" }].compactMap { $0 }).joined(separator: "\n")
        case let .score(instructions, levels):
            return instructions + "\nLevels:\n" + levels.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
        }
    }

    /// `{fieldId: {type: enum|boolean|integer, choices?, minimum?, maximum?, description}}`
    static func schema(_ questions: [String: DecisionQuestion]) -> JSONValue {
        .object(questions.mapValues { q in
            switch q {
            case let .choice(_, options):
                return .object(["type": .string("enum"), "choices": .array(options.map { .string($0.id) }), "description": .string(description(q))])
            case .noul:
                return .object(["type": .string("boolean"), "description": .string(description(q))])
            case let .score(_, levels):
                return .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(Double(levels.count - 1)), "description": .string(description(q))])
            }
        })
    }

    /// Requests in one batch must share questions and instructions.
    func body(for batch: [DecisionRequest]) -> JSONValue {
        var o: [String: JSONValue] = [
            "instructions": .string(batch[0].instructions),
            "schema": Self.schema(batch[0].questions),
            "contexts": .array(batch.map { .string($0.state) }),
            "cache_prompt": .bool(true),
        ]
        if let model { o["model"] = .string(model) }
        return .object(o)
    }

    /// `{"results": [{"fields": {id: {value, probability, probabilities?}}}]}`. Stock engines return the
    /// winner's probability only; the patched engine on the Olares also returns the full distribution.
    static func parse(_ json: JSONValue, questions: [String: DecisionQuestion], count: Int, label: String) throws -> [DecisionResponse] {
        guard case let .object(root) = json, case let .array(results)? = root["results"], results.count == count else {
            throw DecisionError.malformed("expected \(count) results")
        }
        return results.map { result in
            var answers: [String: DecisionAnswer] = [:]
            if case let .object(r) = result, case let .object(fields)? = r["fields"] {
                for (id, question) in questions {
                    guard case let .object(f)? = fields[id] else { continue }
                    let p: Double? = if case let .number(n)? = f["probability"] { n } else { nil }
                    let distribution: [String: Double]? = {
                        guard case let .object(all)? = f["probabilities"] else { return nil }
                        return all.compactMapValues { if case let .number(n) = $0 { n } else { nil } }
                    }()
                    switch (question, f["value"]) {
                    case let (.choice, .string(v)?): answers[id] = DecisionAnswer(value: v, confidence: p, distribution: distribution)
                    case let (.noul, .bool(v)?): answers[id] = DecisionAnswer(value: v ? "true" : "false", confidence: p)
                    case let (.score, .number(v)?): answers[id] = DecisionAnswer(value: String(Int(v)), confidence: p)
                    default: break
                    }
                }
            }
            return DecisionResponse(answers: answers, model: label)
        }
    }

    public func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse] {
        var out: [DecisionResponse] = []
        // Group consecutive requests that share a schema, then chunk to maxBatch.
        var index = 0
        while index < requests.count {
            var end = index + 1
            while end < requests.count, end - index < maxBatch,
                  requests[end].questions == requests[index].questions, requests[end].instructions == requests[index].instructions { end += 1 }
            let batch = Array(requests[index..<end])
            out += try await decideBatch(batch)
            index = end
        }
        return out
    }

    /// One POST for `batch`. When the engine rejects it for its content, it's split in half until the request it refuses
    /// stands alone and comes back marked `failure`; an outage throws.
    func decideBatch(_ batch: [DecisionRequest]) async throws -> [DecisionResponse] {
        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/decision"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try body(for: batch).data()
        urlRequest.timeoutInterval = 120
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw DecisionError.http(status, String(decoding: data, as: UTF8.self)) }
            return try Self.parse(try JSONValue.parse(data), questions: batch[0].questions, count: batch.count, label: label)
        } catch where DecisionError.isAboutTheRequest(error) {
            guard batch.count > 1 else { return [DecisionResponse(answers: [:], model: label, failure: error.localizedDescription)] }
            let half = batch.count / 2
            return try await decideBatch(Array(batch[..<half])) + decideBatch(Array(batch[half...]))
        }
    }
}

// MARK: - Factory

/// Where each provider lives. Jev's `/v1/systemone` is the one protocol: Qwen Decide is reached
/// through `decision-bench/jevshim` (a Jev-compatible front door for `/v1/decision`) and Laya
/// speaks it natively, so switching providers only changes the base URL, model and key.
public struct DecisionEndpoints: Sendable {
    public var jev: SystemOneDecisionModel.Transport?
    /// Base URL of the jevshim in front of Qwen Decide (or of the engine, when `qwenDecideDirect`).
    public var qwenDecide: URL?
    /// Call the engine's batched `/v1/decision` directly instead of the shim — faster for bulk.
    public var qwenDecideDirect: Bool
    public var laya: URL?

    public init(jev: SystemOneDecisionModel.Transport? = nil, qwenDecide: URL? = nil, qwenDecideDirect: Bool = false, laya: URL? = nil) {
        self.jev = jev
        self.qwenDecide = qwenDecide
        self.qwenDecideDirect = qwenDecideDirect
        self.laya = laya
    }
}

public enum DecisionModels {
    /// The client for a provider, or nil when the provider is off.
    public static func make(_ provider: DecisionProvider, _ endpoints: DecisionEndpoints, session: URLSession = .shared) throws -> (any DecisionModel)? {
        switch provider {
        case .off:
            return nil
        case .jev:
            guard let transport = endpoints.jev else { throw DecisionError.missingKey }
            return SystemOneDecisionModel(transport: transport, session: session)
        case .localDecide:
            guard let url = endpoints.qwenDecide else { throw DecisionError.notConfigured("Qwen Decide") }
            return endpoints.qwenDecideDirect
                ? LlamaDecisionModel(baseURL: url, session: session)
                // system2 off: the shim's think-then-rescore pass pushes ambiguous categories to ~98%
                // (docs/assistant/eval.md), hiding exactly the items the review queue exists for.
                : SystemOneDecisionModel(transport: .selfHosted(baseURL: url, model: "qwen3.8-27b-decide", apiKey: nil),
                                         extraFields: ["system2": .string("off")], session: session)
        case .laya:
            guard let url = endpoints.laya else { throw DecisionError.notConfigured("Laya") }
            return SystemOneDecisionModel(transport: .selfHosted(baseURL: url, model: "jev-latest", apiKey: nil), session: session)
        }
    }
}
