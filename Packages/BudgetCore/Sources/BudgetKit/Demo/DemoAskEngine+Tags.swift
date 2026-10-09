import Foundation

extension DemoAskEngine {
    /// "How much did the Austin trip cost?": a question naming one of the ledger's tags answers from `sumByTag`. The tag
    /// has to stand as its own words ("work" is not in "network"), and one spelled like a category ("Travel") leaves the
    /// question to the category unless it says "tag".
    func tagIntent(_ q: String, _ cid: String) -> AskReply? {
        guard let tags = try? ledger.tagSummaries() else { return nil }
        let saysTag = q.contains("tag")
        let categoryNames = Set(ledger.activeCategories.map { $0.name.lowercased() })
        let named = tags.filter { summary in
            let key = summary.tag.lowercased()
            return key.count >= 3 && Self.containsWords(q, key) && (saysTag || !categoryNames.contains(key))
        }
        guard let match = named.max(by: { $0.tag.count < $1.tag.count }),
              let summary = try? ledger.tagSummary(match.tag) else {
            return q.contains("tagged") || q.contains("my tags") ? allTags(tags, cid) : nil
        }
        let things = summary.count == 1 ? "1 transaction" : "\(summary.count) transactions"
        let top = (summary.byCategory ?? []).first.flatMap { spend in ledger.category(spend.categoryID).map { ($0.name, spend.spent) } }
        var text = "Everything tagged “\(summary.tag)” comes to \(summary.spent.formatted()) of spending, net of refunds, across \(things)."
        if let top { text += " The most went to \(top.0.lowercased()): \(top.1.formatted())." }
        if summary.income.minorUnits != 0 { text += " \(summary.income.formatted()) came in under it." }
        var figures = [Figure(id: "tag-spent", label: summary.tag, detail: "\(things), net of refunds", value: summary.spent)]
        figures += (summary.byCategory ?? []).map {
            Figure(id: "tag-\($0.categoryID)", label: ledger.category($0.categoryID)?.name ?? $0.categoryID, detail: nil, value: $0.spent)
        }
        if summary.income.minorUnits != 0 { figures.append(Figure(id: "tag-income", label: "Income", detail: nil, value: summary.income)) }
        return reply(cid, text: text, figures: figures, tools: [call("sumByTag", ["tag": .string(summary.tag)])],
                     followUps: ["What have I tagged?"])
    }

    /// Whether `phrase` appears in `text` with no letter or digit right before or after it.
    static func containsWords(_ text: String, _ phrase: String) -> Bool {
        var start = text.startIndex
        while let range = text.range(of: phrase, range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before?.isLetter ?? false), !(before?.isNumber ?? false), !(after?.isLetter ?? false), !(after?.isNumber ?? false) { return true }
            start = text.index(after: range.lowerBound)
        }
        return false
    }

    /// "What have I tagged?": every tag with its spending.
    private func allTags(_ tags: [TagSummary], _ cid: String) -> AskReply {
        guard !tags.isEmpty else {
            return reply(cid, text: "Nothing is tagged yet. Add a tag from a transaction's details, or select several in Activity and tag them together.",
                         tools: [call("sumByTag", [:])])
        }
        let named = tags.prefix(3).map { "“\($0.tag)” (\($0.spent.formatted()))" }
        let text = "You have \(tags.count == 1 ? "1 tag" : "\(tags.count) tags"). Most recently used first, with spending net of refunds: \(named.spokenList)."
        return reply(cid, text: text, figures: tags.map { Figure(id: "tag-\($0.id)", label: $0.tag, detail: "Net of refunds", value: $0.spent) },
                     tools: [call("sumByTag", [:])], followUps: tags.prefix(2).map { "How much did \($0.tag) cost?" })
    }
}
