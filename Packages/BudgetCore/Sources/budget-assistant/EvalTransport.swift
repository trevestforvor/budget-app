import BudgetKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What one model call cost, as OpenRouter reported it.
struct CallUsage: Sendable {
    var prompt = 0
    var cached = 0
    var completion = 0
    var reasoning = 0
    var cost = 0.0
    var seconds = 0.0
    var provider: String?
    var status = 200

    static func + (a: CallUsage, b: CallUsage) -> CallUsage {
        CallUsage(prompt: a.prompt + b.prompt, cached: a.cached + b.cached, completion: a.completion + b.completion,
                  reasoning: a.reasoning + b.reasoning, cost: a.cost + b.cost, seconds: a.seconds + b.seconds, provider: b.provider ?? a.provider)
    }
}

/// An eval-only transport: sits under the app's own `OpenAIChatModel`, adds OpenRouter routing fields to each request
/// body, and records usage per run. The app's client and its request bytes are otherwise what ships.
final class EvalTransport: URLProtocol, @unchecked Sendable {
    /// Fields merged into every chat request body (provider order, reasoning effort, usage accounting).
    nonisolated(unsafe) static var inject: [String: JSONValue] = [:]
    /// Replaces the client's `max_tokens` when set.
    nonisolated(unsafe) static var maxTokens: Int?
    static let runHeader = "X-Eval-Run"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var calls: [String: [CallUsage]] = [:]
    private static let forward: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    /// A session whose requests are attributed to `run`.
    static func session(run: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EvalTransport.self]
        config.httpAdditionalHeaders = [runHeader: run]
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }

    static func usage(run: String) -> [CallUsage] {
        lock.lock(); defer { lock.unlock() }
        return calls[run] ?? []
    }

    private static func record(_ usage: CallUsage, run: String) {
        lock.lock(); defer { lock.unlock() }
        calls[run, default: []].append(usage)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: runHeader) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var outgoing = request
        let run = request.value(forHTTPHeaderField: Self.runHeader) ?? "?"
        outgoing.setValue(nil, forHTTPHeaderField: Self.runHeader)
        if let body = Self.body(of: request) {
            outgoing.httpBodyStream = nil
            outgoing.httpBody = body
            if case var .object(o)? = try? JSONValue.parse(body) {
                for (key, value) in Self.inject { o[key] = value }
                if let max = Self.maxTokens { o["max_tokens"] = .number(Double(max)) }
                outgoing.httpBody = try? JSONValue.object(o).data()
            }
        }
        let started = Date()
        let task = Self.forward.dataTask(with: outgoing) { [self] data, response, error in
            if let error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let http = response as? HTTPURLResponse
            var usage = CallUsage(seconds: Date().timeIntervalSince(started), status: http?.statusCode ?? 0)
            if let data, case let .object(root)? = try? JSONValue.parse(data) {
                if case let .string(p)? = root["provider"] { usage.provider = p }
                if case let .object(u)? = root["usage"] {
                    usage.prompt = Self.int(u["prompt_tokens"])
                    usage.completion = Self.int(u["completion_tokens"])
                    if case let .number(c)? = u["cost"] { usage.cost = c }
                    if case let .object(d)? = u["prompt_tokens_details"] { usage.cached = Self.int(d["cached_tokens"]) }
                    if case let .object(d)? = u["completion_tokens_details"] { usage.reasoning = Self.int(d["reasoning_tokens"]) }
                }
            }
            Self.record(usage, run: run)
            if ProcessInfo.processInfo.environment["EVAL_DEBUG"] != nil, let data, case let .object(root)? = try? JSONValue.parse(data),
               case let .array(choices)? = root["choices"], case let .object(c)? = choices.first, case let .object(m)? = c["message"] {
                var line = "[\(run)] finish=\(c["finish_reason"].map { "\($0)" } ?? "-")"
                if case let .array(calls)? = m["tool_calls"] {
                    for case let .object(call) in calls { if case let .object(f)? = call["function"] { line += " CALL \(f["name"].map { "\($0)" } ?? "") \(f["arguments"].map { "\($0)" }?.prefix(160) ?? "")" } }
                }
                if case let .string(t)? = m["content"] { line += " TEXT \(t.prefix(200).replacingOccurrences(of: "\n", with: " "))" }
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            if let http { client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed) }
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
        task.resume()
    }

    private static func int(_ value: JSONValue?) -> Int {
        if case let .number(n)? = value { return Int(n) }
        return 0
    }

    /// URLProtocol often sees the body as a stream rather than `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
