import Foundation

/// Retells a `DayDigest` in a sentence or two for the morning notification. The ledger has already done the arithmetic;
/// the model only chooses what to say and says it. What it writes is kept only if it's short and every amount in it is
/// one the facts hold — otherwise the template stays. A day with nothing spent isn't sent to the model at all.
public struct DigestWriter: Sendable {
    public let model: any ChatModel
    /// The longest body kept: a lock screen shows about four lines.
    public static let maxLength = 220

    public init(model: any ChatModel) { self.model = model }

    public func write(_ digest: DayDigest) async -> DayDigest {
        guard digest.count > 0 else { return digest }
        let request = ChatRequest(messages: [.system(Self.system), .user(Self.prompt(digest))], thinking: false, temperature: 0.3, maxTokens: 400)
        var written = digest
        let reply: String
        do {
            reply = try await model.complete(request).message.content ?? ""
        } catch {
            written.writerProblem = "The model didn't answer: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
            return written
        }
        guard let text = Self.accept(reply, for: digest) else {
            written.writerProblem = "The model's text was empty, too long, or quoted an amount the ledger didn't give it: \(reply.prefix(300))"
            return written
        }
        written.summary = text
        written.writtenBy = model.label
        return written
    }

    static let system = """
        You write the body of a phone notification that sums up what the person spent yesterday. \
        Write at most two short sentences, under 200 characters in all. Say where the money went, then at most one of the \
        insights — the one most worth knowing. Use only the figures given, written exactly as given; never add, round or \
        work out a number. No greeting, no emoji, no markdown, no quotation marks, no advice beyond what an insight says. \
        Reply with the notification text and nothing else.
        """

    static func prompt(_ d: DayDigest) -> String {
        var lines = ["Spent yesterday: \(Ledger.amount(d.spent)) across \(d.count) charge\(d.count == 1 ? "" : "s")."]
        let places = d.places.map { p -> String in
            let category = p.category.map { " (\($0))" } ?? ""
            let charges = p.count > 1 ? ", \(p.count) charges" : ""
            return "\(p.merchant) \(Ledger.amount(p.spent))\(category)\(charges)"
        }
        lines.append("Where: \(places.joined(separator: "; ")).")
        if !d.facts.isEmpty {
            lines.append("Insights, most useful first:")
            lines += d.facts.map { "- \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }

    /// The model's text, cleaned, if it's fit to send: not empty, short enough, and quoting no dollar amount that isn't
    /// in the prompt.
    static func accept(_ reply: String, for digest: DayDigest) -> String? {
        var text = reply
        // A reasoning model that thought out loud anyway: keep what came after.
        if let close = text.range(of: "</think>", options: .backwards) { text = String(text[close.upperBound...]) }
        text = text.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maxLength else { return nil }
        let given = Set(amounts(in: prompt(digest)))
        guard amounts(in: text).allSatisfy(given.contains) else { return nil }
        return text
    }

    /// Every "$1,234.56" in `text`, commas dropped.
    static func amounts(in text: String) -> [String] {
        let pattern = /\$[0-9][0-9,]*(?:\.[0-9]{1,2})?/
        return text.matches(of: pattern).map { String($0.output).replacingOccurrences(of: ",", with: "") }
    }
}
