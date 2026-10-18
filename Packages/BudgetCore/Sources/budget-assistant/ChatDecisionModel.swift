import BudgetKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Eval-only: a chat model on OpenRouter answering the decision model's category question. Options are lettered so the
/// answer is one token; with `logprobs` the confidence is the letter's share of probability, otherwise the model states
/// one ("verbalized"), which isn't calibrated the same way. Reasoning is turned off for the answer.
struct ChatDecisionModel: DecisionModel {
    enum Confidence: String, Sendable { case logprobs, verbalized }
    let model: String
    let apiKey: String
    let confidence: Confidence
    /// OpenRouter provider slugs to try in order (logprobs live on some hosts only).
    let providers: [String]
    var maxConcurrent = 8

    var label: String { "\(model) · \(confidence.rawValue)" }
    var runsLocally: Bool { false }

    static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    nonisolated(unsafe) static var totals = CallUsage()
    nonisolated(unsafe) static var fallbacks = 0
    nonisolated(unsafe) static var failures: [String] = []
    private static let lock = NSLock()

    func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse] {
        var out = [DecisionResponse?](repeating: nil, count: requests.count)
        var next = 0
        try await withThrowingTaskGroup(of: (Int, DecisionResponse).self) { group in
            func start() {
                guard next < requests.count else { return }
                let i = next
                next += 1
                group.addTask { (i, await one(requests[i])) }
            }
            for _ in 0..<maxConcurrent { start() }
            for try await (i, response) in group {
                out[i] = response
                start()
            }
        }
        return out.map { $0! }
    }

    private func one(_ request: DecisionRequest) async -> DecisionResponse {
        var answers: [String: DecisionAnswer] = [:]
        var failure: String?
        for (qid, question) in request.questions {
            guard case let .choice(instructions, options) = question else { continue }
            let lettered = Array(zip(Self.letters, options))
            var prompt = "\(request.instructions)\n\n\(instructions)\n\nTransaction:\n\(request.state)\n\nOptions:\n"
            for (letter, option) in lettered { prompt += "\(letter)) \(option.id)\(option.description.isEmpty ? "" : " — \(option.description)")\n" }
            prompt += confidence == .logprobs
                ? "\nReply with the single letter of the best option and nothing else."
                : "\nReply with only JSON: {\"answer\": \"<letter>\", \"confidence\": <0-100, how likely your answer is right>}."
            do {
                let (letterProbs, stated) = try await ask(prompt)
                let byID = Dictionary(uniqueKeysWithValues: lettered.map { ($0.0, $0.1.id) })
                if let letterProbs, !letterProbs.isEmpty {
                    var dist: [String: Double] = [:]
                    for (letter, p) in letterProbs { if let id = byID[letter] { dist[id, default: 0] += p } }
                    let sum = dist.values.reduce(0, +)
                    if sum > 0, let best = dist.max(by: { $0.value < $1.value }) {
                        dist = dist.mapValues { $0 / sum }
                        answers[qid] = DecisionAnswer(value: best.key, confidence: dist[best.key], distribution: dist)
                        continue
                    }
                }
                if let stated, let id = byID[stated.letter] {
                    answers[qid] = DecisionAnswer(value: id, confidence: stated.confidence)
                } else {
                    failure = "unparsed answer"
                }
            } catch {
                failure = "\(error.localizedDescription.prefix(160))"
            }
        }
        if let failure { Self.note(failure: "\(request.state.prefix(60).replacingOccurrences(of: "\n", with: " ")): \(failure)") }
        return DecisionResponse(answers: answers, model: label, failure: failure)
    }

    /// Letter probabilities (logprobs mode) and/or a stated answer.
    private func ask(_ prompt: String) async throws -> ([(String, Double)]?, (letter: String, confidence: Double)?) {
        // Reasoning off: OpenRouter's effort "none", then `enabled: false`, then the model's default.
        // Some models can't turn reasoning off (GLM-5.3-Flash): then the least effort they take, with room to think.
        let small = confidence == .logprobs ? 4 : 60
        let reasoningTries: [(JSONValue?, Int)] = [(.object(["effort": .string("none")]), small), (.object(["enabled": .bool(false)]), small),
                                                    (.object(["effort": .string("minimal")]), 3000), (.object(["effort": .string("low")]), 3000), (nil, 6000)]
        var lastError = ""
        for (reasoning, maxTokens) in reasoningTries {
            var body: [String: JSONValue] = [
                "model": .string(model),
                "messages": .array([.object(["role": .string("user"), "content": .string(prompt)])]),
                "max_tokens": .number(Double(maxTokens)),
                "usage": .object(["include": .bool(true)]),
            ]
            if let reasoning { body["reasoning"] = reasoning }
            if confidence == .logprobs {
                body["logprobs"] = .bool(true)
                body["top_logprobs"] = .number(20)
            }
            if !providers.isEmpty {
                body["provider"] = .object(["order": .array(providers.map(JSONValue.string)), "allow_fallbacks": .bool(false),
                                            "require_parameters": .bool(confidence == .logprobs)])
            }
            var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONValue.object(body).data()
            req.timeoutInterval = 120
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, case let .object(root) = try JSONValue.parse(data) else {
                lastError = "HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))"
                if ProcessInfo.processInfo.environment["EVAL_DEBUG"] != nil { FileHandle.standardError.write(Data("\(reasoning.map { "\($0)" } ?? "no reasoning field") → \(lastError)\n".utf8)) }
                if status == 400 || status == 404 { Self.note(fallback: true); continue }
                throw DecisionError.http(status, lastError)
            }
            Self.record(root, seconds: Date().timeIntervalSince(started))
            guard case let .array(choices)? = root["choices"], case let .object(choice)? = choices.first,
                  case let .object(message)? = choice["message"] else { throw DecisionError.malformed("no choices") }
            let content: String = if case let .string(c)? = message["content"] { c } else { "" }
            if ProcessInfo.processInfo.environment["EVAL_DEBUG"] != nil {
                FileHandle.standardError.write(Data("content=\(content.debugDescription) finish=\(choice["finish_reason"].map { "\($0)" } ?? "-") logprobs=\(choice["logprobs"] != nil) \(String(decoding: (try? JSONValue.object(choice).data()) ?? Data(), as: UTF8.self).prefix(600))\n".utf8))
            }
            var probs: [(String, Double)]?
            if case let .object(lp)? = choice["logprobs"], case let .array(tokens)? = lp["content"] {
                // The first token that is a lone letter carries the answer.
                for case let .object(t) in tokens {
                    guard case let .string(tok)? = t["token"], Self.letters.contains(tok.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                    var list: [(String, Double)] = []
                    if case let .array(top)? = t["top_logprobs"] {
                        for case let .object(alt) in top {
                            if case let .string(a)? = alt["token"], case let .number(l)? = alt["logprob"] {
                                let letter = a.trimmingCharacters(in: .whitespacesAndNewlines)
                                if Self.letters.contains(letter) { list.append((letter, exp(l))) }
                            }
                        }
                    }
                    probs = list
                    break
                }
            }
            return (probs, Self.stated(content, verbalized: confidence == .verbalized))
        }
        throw DecisionError.http(400, lastError)
    }

    static func stated(_ content: String, verbalized: Bool) -> (letter: String, confidence: Double)? {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if verbalized, let data = text.range(of: #"\{[^}]*\}"#, options: .regularExpression).map({ Data(text[$0].utf8) }),
           case let .object(o)? = try? JSONValue.parse(data), case let .string(a)? = o["answer"] {
            let c: Double = if case let .number(n)? = o["confidence"] { n } else { 50 }
            return (a.trimmingCharacters(in: .whitespaces).uppercased(), min(max(c / 100, 0), 1))
        }
        let first = String(text.prefix(1)).uppercased()
        return letters.contains(first) ? (first, 1) : nil
    }

    private static func note(failure: String) {
        lock.lock(); defer { lock.unlock() }
        failures.append(failure)
    }

    private static func note(fallback: Bool) {
        lock.lock(); defer { lock.unlock() }
        if fallback { fallbacks += 1 }
    }

    private static func record(_ root: [String: JSONValue], seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        var u = CallUsage(seconds: seconds)
        if case let .string(p)? = root["provider"] { u.provider = p }
        if case let .object(o)? = root["usage"] {
            if case let .number(v)? = o["prompt_tokens"] { u.prompt = Int(v) }
            if case let .number(v)? = o["completion_tokens"] { u.completion = Int(v) }
            if case let .number(v)? = o["cost"] { u.cost = v }
        }
        totals = totals + u
    }
}
