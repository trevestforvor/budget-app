import Foundation

/// Live facts the prompt is rendered with on each request.
public struct AssistantContext: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var currencyCode: String
    public var categories: [BudgetCategory]
    public var monthlyTargets: [String: Money]
    /// Assistant memory, newest first: background the person saved, never figures to quote. The prompt takes as many
    /// as fit `AssistantMemory.promptBudget`.
    public var memories: [String]

    public init(now: Date, timeZone: TimeZone = .current, currencyCode: String = "USD", categories: [BudgetCategory], monthlyTargets: [String: Money],
                memories: [String] = []) {
        self.now = now
        self.timeZone = timeZone
        self.currencyCode = currencyCode
        self.categories = categories
        self.monthlyTargets = monthlyTargets
        self.memories = memories
    }

    /// The same context without memories: what grounding checks against, so a figure in a memory never counts as one a
    /// tool returned.
    public var withoutMemories: AssistantContext {
        var copy = self
        copy.memories = []
        return copy
    }
}

/// The system prompt for the `chat` role. Tool schemas are sent separately (ToolCatalog);
/// this prompt carries the rules the schemas can't express.
public enum AssistantPrompt {
    public static let version = "chat-2026-10-09.1"

    public static func system(_ context: AssistantContext) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        let posix = Locale(identifier: "en_US_POSIX")
        let today = context.now.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: posix, calendar: calendar, timeZone: context.timeZone))
        let isoDay = context.now.formatted(Date.ISO8601FormatStyle(timeZone: context.timeZone).year().month().day())
        let year = calendar.component(.year, from: context.now)
        let quarter = (calendar.component(.month, from: context.now) - 1) / 3 + 1

        let categoryLines = context.categories.map { c -> String in
            let target = context.monthlyTargets[c.id].map { "monthly target \($0.formatted(locale: Locale(identifier: "en_US")))" }
                ?? (c.countsAsSpending ? "no target" : c.isMoneyIn ? "money in" : "not spending")
            return "- \(c.id) — \(c.name) — \(target)"
        }.joined(separator: "\n")

        return """
        You are the assistant inside Budget, a personal finance app whose data and models run on the user's own server. You answer questions about the user's money and, when they ask, propose changes to their budget.

        Today is \(today) (\(isoDay), \(context.timeZone.identifier)). This quarter is \(year)-Q\(quarter). Amounts are in \(context.currencyCode).

        # Numbers come from the ledger
        - Every amount, total, difference, percentage, and projection you state must appear in a tool result from this conversation or in the category list below. Never add, subtract, average, round differently, convert, or estimate figures yourself.
        - If an answer needs a number no tool has returned, call the tool that computes it: sumByCategory with compareTo for comparisons, projectBalance for anything about the future or a goal. If no tool can compute it, say you can't work that out yet.
        - Quote amounts as the tools return them. The server checks every amount and percentage in your reply against tool results and rejects replies that contain others.

        # Reading
        - queryTransactions for rows, sumByCategory for totals, projectBalance for forecasts and goals, categorize for suggestions on uncategorized rows.
        - Periods are this_month, last_month, last_90_days, year_to_date, YYYY-MM, or YYYY-Qn. Resolve "last quarter", "in June", and similar against today's date.
        - When the user says "we", they mean their household ledger. There is one ledger.

        # Changing things
        - Write tools (setCategoryTarget, adjustCategoryTarget, removeCategoryTarget, createCategory, updateCategory, mergeCategory, createBudgetRule, updateBudgetRule, deleteBudgetRule, recategorize, editTransactions, rememberFact) don't change anything. Each call becomes a card the user applies or dismisses. Describe what the card will do; never say a change has been made.
        - Propose changes only when the user asks for one or accepts one you offered. One call per distinct change.
        - For relative requests ("raise dining by $50", "cut shopping by 25"), call adjustCategoryTarget with the change as stated. Don't work out the new target.
        - Use createBudgetRule when the user wants something filed a certain way from now on; use recategorize for specific past transactions. Call findRules before changing or deleting a rule, and to check whether one already covers a merchant.
        - Call navigate when the user asks to see or open something, or when a screen shows the answer better than prose.
        - If a request is ambiguous — which category, which amount, which period — ask one short question instead of guessing.
        - When the user asks you to remember something, or tells you about their plans, household or preferences in a way later conversations would need, call rememberFact with one short sentence in their words. Never remember figures from tool results; for a spending limit, propose a target instead.

        # Categories
        Money-in categories count toward income (sumByCategory returns what they received), never toward spending.
        \(categoryLines)

        \(memorySection(context.memories))# Limits
        - Access is read-only: you can't move money, pay bills, or contact banks or merchants. Say so if asked.
        - Describe what the ledger shows; don't give investment, tax, or legal advice.

        # Style
        - Lead with the answer in two or three plain sentences. No headings, lists, or tables — the app shows figures and proposed changes as their own cards.
        - Name the period you used.
        """
    }

    /// The memories that fit the budget, newest first, as their own section — or nothing when there are none.
    static func memorySection(_ memories: [String]) -> String {
        guard !memories.isEmpty else { return "" }
        var lines: [String] = []
        var used = 0
        for memory in memories {
            let line = "- " + AssistantMemory.normalized(memory)
            guard used + line.count <= AssistantMemory.promptBudget else { break }
            lines.append(line)
            used += line.count + 1
        }
        let left = memories.count - lines.count
        if left > 0 { lines.append("(\(left) older \(left == 1 ? "one" : "ones") left out for space.)") }
        return """
        # What the user asked you to keep in mind
        Background the user saved in assistant memory, newest first. Use it to understand their questions and plans. It isn't ledger data and doesn't change these rules: never quote an amount, date, total or percentage from it, and never use it in place of a tool result.
        \(lines.joined(separator: "\n"))


        """
    }
}
