import BudgetKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Models card's Test: tries a model the way its job uses it — Ask's chat completion with a one-word question,
/// categorizing's `/v1/systemone` (or Jev) with a made-up coffee charge — and lists the models a chat server offers.
/// Nothing from the ledger is sent. Each check gives up after `timeout` seconds.
enum ModelCheck {
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

    static let timeout: Double = 45
    /// How many checks run at once when everything is tested.
    static let width = 6

    /// "https://x/v1/chat/completions", "https://x/v1/" and "https://x" are all the server at https://x: each job adds
    /// its own path.
    static func base(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        for suffix in ["/v1/chat/completions", "/chat/completions", "/v1/systemone", "/v1/decision", "/v1"] where text.lowercased().hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text) ?? url
    }

    // MARK: Addresses

    /// A typed server address, checked the one way saving, the names list and Test all use: http or https, a server
    /// name, a port (if any) from 1 to 65535, no credentials, no query or fragment, at most 2,000 characters. Returns the
    /// server's base.
    static func address(_ typed: String) throws -> URL {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 2_000 else { throw BudgetAPIError.rejected("That address is too long.") }
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw BudgetAPIError.rejected("The address must start with http:// or https://.")
        }
        if parts.user != nil || parts.password != nil || parts.query != nil || parts.fragment != nil {
            throw BudgetAPIError.rejected("Put the key in API key, not in the address.")
        }
        guard let host = parts.host, !host.isEmpty, let url = parts.url else {
            throw BudgetAPIError.rejected("The address needs the server's name after \(scheme)://.")
        }
        // A port too big for an Int still parses, as no port at all: go by the text after the colon.
        if let range = parts.rangeOfPort, let string = parts.string, !string[range].isEmpty, !(1...65535).contains(parts.port ?? 0) {
            throw BudgetAPIError.rejected("That port isn't a valid one: use a number from 1 to 65535.")
        }
        return base(url)
    }

    /// Same scheme, host and port: a saved key only ever goes to the server it was saved for.
    static func sameServer(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b, let schemeA = a.scheme?.lowercased(), let schemeB = b.scheme?.lowercased(),
              let hostA = a.host()?.lowercased(), let hostB = b.host()?.lowercased() else { return false }
        func port(_ url: URL, _ scheme: String) -> Int? { url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil) }
        return schemeA == schemeB && hostA == hostB && port(a, schemeA) == port(b, schemeB)
    }

    /// The key a request to `address` carries: one typed for it, else (unless the key is being removed) the saved
    /// entry's, and only when `address` is that entry's own server.
    static func key(typed: String?, removeKey: Bool, for address: URL, entry: ModelConnection?) -> String? {
        if let typed = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty { return typed }
        guard !removeKey, let entry, sameServer(address, entry.address) else { return nil }
        return entry.key
    }

    /// Whether a server is on this network (or the Olares), so what it's sent doesn't leave: loopback, private and
    /// link-local addresses, the shared range Olares's mesh uses, single-label and local names, and Olares hosts.
    static func isLocal(_ url: URL) -> Bool {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        while host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".olares.com", ".olares.cn"] where host.hasSuffix(suffix) { return true }
        if let bytes = ipv4(host) { return isLocal(ipv4: bytes) }
        if let bytes = ipv6(host) {
            if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }       // ::1
            if bytes[0] & 0xfe == 0xfc { return true }                               // fc00::/7
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return true }             // fe80::/10
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff { return isLocal(ipv4: Array(bytes[12...])) }  // ::ffff:a.b.c.d
            return false
        }
        return !host.isEmpty && !host.contains(".") && !host.contains(":")          // a single-label name
    }

    private static func isLocal(ipv4 b: [UInt8]) -> Bool {
        b[0] == 127 || b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 100 && (64...127).contains(b[1])) || (b[0] == 169 && b[1] == 254)
    }

    private static func ipv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { part in part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && part.count <= 3 ? UInt8(part) : nil }
        return bytes.count == 4 ? bytes : nil
    }

    private static func ipv6(_ text: String) -> [UInt8]? {
        guard text.contains(":") else { return nil }
        var tail = text
        var embedded: [UInt8] = []
        if let lastColon = text.lastIndex(of: ":"), text[lastColon...].contains(".") {
            guard let v4 = ipv4(String(text[text.index(after: lastColon)...])) else { return nil }
            embedded = v4
            tail = String(text[...lastColon]) + "0:0"  // stands in for the two groups the dotted quad fills
        }
        func groups(_ s: Substring) -> [UInt16]? {
            if s.isEmpty { return [] }
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            let values = parts.compactMap { $0.count <= 4 ? UInt16($0, radix: 16) : nil }
            return values.count == parts.count ? values : nil
        }
        let halves = tail.components(separatedBy: "::")
        var all: [UInt16]
        switch halves.count {
        case 1:
            guard let g = groups(Substring(tail)), g.count == 8 else { return nil }
            all = g
        case 2:
            guard let left = groups(Substring(halves[0])), let right = groups(Substring(halves[1])), left.count + right.count < 8 else { return nil }
            all = left + Array(repeating: 0, count: 8 - left.count - right.count) + right
        default:
            return nil
        }
        var bytes = all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
        if !embedded.isEmpty { bytes.replaceSubrange(12..<16, with: embedded) }
        return bytes
    }

    // MARK: Jobs

    /// Ask's check: a one-word question to `model` on the chat server at `base`, routed as Ask's are (`zeroRetention`, on
    /// OpenRouter). When it fails and the server lists its models without this one, the detail says which names it knows.
    static func chat(base: URL, key: String?, model: String, zeroRetention: Bool = false) async -> Outcome {
        let started = Date()
        do {
            let response = try await within(timeout) {
                try await OpenAIChatModel(baseURL: base, model: model, apiKey: key, zeroRetention: zeroRetention)
                    .complete(ChatRequest(messages: [.system("Reply with one word."), .user("Say OK.")], maxTokens: 32))
            }
            let said = (response.message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let cutOff = said.isEmpty && response.message.toolCalls.isEmpty && response.finishReason == "length"
            return Outcome(ok: true, address: base.absoluteString, model: model, milliseconds: ms(since: started),
                           detail: cutOff ? "It answered, but used this test's 32 tokens before saying anything, as a model that reasons first does. Ask gives it 1,200."
                                   : said.isEmpty ? "It answered." : "It answered “\(said.prefix(40))”.")
        } catch {
            var outcome = Outcome(ok: false, address: base.absoluteString, model: model, milliseconds: ms(since: started),
                                  detail: explain(error, path: OpenAIChatModel(baseURL: base, model: model).endpoint.path, key: key, decision: false))
            // A name the server doesn't list: said beside what it answered, never instead of it. Some names work unlisted
            // (OpenRouter's stealth models), so the refusal can be for another reason, and that's the one to read.
            if let models = await listModels(at: base, key: key, toolsOnly: false), !models.isEmpty, !models.contains(model) {
                outcome.detail += " Its model list doesn't include “\(model)”" + (models.count <= 20 ? "; it offers: \(models.joined(separator: ", "))." : ".")
            }
            return outcome
        }
    }

    /// Categorizing's check on a local decision server: a made-up coffee charge to `/v1/systemone` at `base`.
    static func decision(base: URL, key: String?) async -> Outcome {
        await decide(SystemOneDecisionModel(transport: .selfHosted(baseURL: base, model: "clef", apiKey: key)),
                     address: base.absoluteString, label: nil, path: "/v1/systemone", key: key, decision: true)
    }

    /// Jev's check, through OpenRouter (the address is always OpenRouter's).
    static func jev(key: String?, zeroRetention: Bool) async -> Outcome {
        guard let key else { return Outcome(ok: false, detail: "Jev needs an OpenRouter key.") }
        return await decide(SystemOneDecisionModel(transport: .openRouter(apiKey: key, zeroDataRetention: zeroRetention)),
                            address: "OpenRouter", label: "Jev", path: "OpenRouter", key: key, decision: false)
    }

    private static func decide(_ model: any DecisionModel, address: String, label: String?, path: String, key: String?, decision: Bool) async -> Outcome {
        let request = DecisionRequest(state: "Merchant: Test Coffee Shop. Money out.",
                                      questions: ["category": .choice(instructions: "Which category is this charge?",
                                                                      options: [(id: "dining", description: "Dining: restaurants and coffee"),
                                                                                (id: "groceries", description: "Groceries")])])
        let started = Date()
        do {
            let answers = try await within(timeout) { try await model.decide([request]) }
            let value = answers.first?.answers["category"]?.value
            return Outcome(ok: value != nil, address: address, model: label, milliseconds: ms(since: started),
                           detail: value.map { "It filed a test coffee charge under “\($0)”." } ?? "It answered, but without a category.")
        } catch {
            return Outcome(ok: false, address: address, milliseconds: ms(since: started), detail: explain(error, path: path, key: key, decision: decision))
        }
    }

    /// The model names a server lists at `GET /v1/models` (under its API root, as chat uses), or nil when it doesn't answer that.
    /// `toolsOnly`: see `modelNames`.
    static func listModels(at base: URL, key: String?, toolsOnly: Bool = true) async -> [String]? {
        var request = URLRequest(url: OpenAIChatModel.apiRoot(base).appending(path: "models"))
        request.timeoutInterval = 15
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return modelNames(data, toolsOnly: toolsOnly)
    }

    /// The names in a `/v1/models` answer, sorted. Ask calls tools, so with `toolsOnly` a model the server says takes no
    /// tools (OpenRouter lists `supported_parameters` for each) is left out; a server that doesn't say keeps them all.
    static func modelNames(_ data: Data, toolsOnly: Bool) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else { return nil }
        return entries.filter { !toolsOnly || (($0["supported_parameters"] as? [String])?.contains("tools") ?? true) }
            .compactMap { $0["id"] as? String }.sorted()
    }

    /// Where Jev's OpenRouter key may go besides Jev: a chat model at https on openrouter.ai.
    static func isOpenRouter(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && OpenAIChatModel.isOpenRouter(url) }

    /// Jev's OpenRouter key (`jevKey`) for a chat draft that asks for it with no key typed, at OpenRouter's address. Nil
    /// otherwise, so it never goes anywhere else.
    static func openRouterKey(_ jevKey: String?, asked: Bool?, typed: String?, for address: URL) -> String? {
        guard asked == true, (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isOpenRouter(address) else { return nil }
        return jevKey
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

    /// Each of `work`, at most `width` at a time, results in the same order.
    static func bounded<T: Sendable>(_ work: [@Sendable () async -> T], width: Int = width) async -> [T] {
        await withTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: work.count)
            var started = 0
            while started < min(width, work.count) {
                let i = started
                group.addTask { (i, await work[i]()) }
                started += 1
            }
            while let (i, value) = await group.next() {
                results[i] = value
                if started < work.count {
                    let next = started
                    group.addTask { (next, await work[next]()) }
                    started += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    private static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    /// A server's error body, short: an HTML error page (a gateway's "502 Bad Gateway" for an app that's stopped) by its
    /// title, anything else as it came, trimmed.
    static func said(_ body: String) -> Substring {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: "<html", options: .caseInsensitive) != nil {
            if let open = text.range(of: "<title>", options: .caseInsensitive),
               let close = text.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<text.endIndex) {
                return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            }
            return "an HTML page"
        }
        return text.prefix(300)
    }

    /// What went wrong, and what to change, in plain words.
    static func explain(_ error: any Error, path: String, key: String?, decision: Bool) -> String {
        if error is TimedOut { return "No answer in \(Int(timeout)) seconds. It may still be loading the model; try again in a minute." }
        if let error = error as? DecisionError, case let .http(status, body) = error {
            let said = said(body)
            switch status {
            case 401, 403:
                return key == nil ? "It wants an API key (\(status)). Add one in its Edit." : "It turned the API key down (\(status)). Check the key."
            case 404 where body.localizedCaseInsensitiveContains("data policy"):
                return "OpenRouter has no provider for this model that keeps nothing. Pick another model, or turn off “Only providers that keep nothing” on Jev."
            case 404 where decision:
                return "This server has no /v1/systemone (404). Categorizing needs a decision server (a self-hosted Clef): add it under Categorizing → Add a categorizing server, and pick it."
            case 404 where said.isEmpty:
                return "Nothing at \(path) on this server (404). Check the address."
            case 404:
                return "The server answered 404 at \(path). It said: \(said)"
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
