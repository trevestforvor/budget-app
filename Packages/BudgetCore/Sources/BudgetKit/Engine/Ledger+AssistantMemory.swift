import Foundation

/// Assistant memory: facts the person asked Ask to keep in mind, kept in the ledger (`LedgerState.assistantMemories`)
/// so the server, the demo and the prompt all read the same list. Changes go through `LedgerBudgetAPI.write`.
extension Ledger {
    /// Newest first: the most recently added or edited at the top.
    var assistantMemoriesNewestFirst: [AssistantMemory] {
        assistantMemories.sorted { ($0.updatedAt ?? $0.createdAt, $0.id) > ($1.updatedAt ?? $1.createdAt, $1.id) }
    }

    /// What the prompt is rendered with: today, the categories and targets, and the memories.
    var assistantContext: AssistantContext {
        AssistantContext(now: now, timeZone: calendar.timeZone, categories: activeCategories, monthlyTargets: monthlyTargets,
                         memories: assistantMemoriesNewestFirst.map(\.text))
    }

    /// The text as it would be kept, or why it can't be: empty, too long, the same as another memory.
    func validatedMemoryText(_ raw: String, replacing id: String? = nil) throws -> String {
        let text = AssistantMemory.normalized(raw)
        guard !text.isEmpty else { throw BudgetAPIError.rejected("Write what Ask should keep in mind.") }
        guard text.count <= AssistantMemory.maxLength else {
            throw BudgetAPIError.rejected("Keep it to \(AssistantMemory.maxLength) characters — one fact per memory.")
        }
        if assistantMemories.contains(where: { $0.id != id && $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            throw BudgetAPIError.rejected("Ask already keeps that in mind.")
        }
        return text
    }

    @discardableResult
    mutating func addAssistantMemory(_ raw: String, source: AssistantMemory.Source, id: String = "mem-" + UUID().uuidString.lowercased()) throws -> AssistantMemory {
        let text = try validatedMemoryText(raw)
        guard assistantMemories.count < AssistantMemory.maxCount else {
            throw BudgetAPIError.rejected("Assistant memory is full (\(AssistantMemory.maxCount)). Delete one first.")
        }
        let memory = AssistantMemory(id: id, text: text, createdAt: now, source: source)
        assistantMemories.insert(memory, at: 0)
        return memory
    }

    mutating func updateAssistantMemory(id: String, text raw: String) throws -> AssistantMemory {
        guard let index = assistantMemories.firstIndex(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
        let text = try validatedMemoryText(raw, replacing: id)
        guard text != assistantMemories[index].text else { return assistantMemories[index] }
        assistantMemories[index].text = text
        assistantMemories[index].updatedAt = now
        return assistantMemories[index]
    }

    mutating func deleteAssistantMemory(id: String) throws {
        guard let index = assistantMemories.firstIndex(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
        assistantMemories.remove(at: index)
    }

    // MARK: rememberFact (the assistant's proposal)

    func rememberFactPreview(_ p: RememberFact) throws -> ActionPreview {
        let text = try validatedMemoryText(p.fact)
        guard assistantMemories.count < AssistantMemory.maxCount else {
            throw BudgetAPIError.rejected("Assistant memory is full (\(AssistantMemory.maxCount)). Delete one first.")
        }
        return ActionPreview(title: "Remember: \(text)",
                             detail: "Ask keeps this in mind in later conversations. Change or delete it in Settings → Assistant memory.")
    }

    mutating func rememberFact(_ p: RememberFact) throws -> ActionResult {
        let memory = try addAssistantMemory(p.fact, source: .assistant)
        return ActionResult(message: "Ask will keep “\(memory.text)” in mind.")
    }

    // MARK: Demo

    /// The demo household's memories: fictional, and with no amounts in them.
    static func demoAssistantMemories(now: Date) -> [AssistantMemory] {
        [
            AssistantMemory(id: "demo-memory-trip", text: "Saving for a trip to Lisbon next spring", createdAt: now.addingTimeInterval(-2 * 86_400),
                            source: .assistant),
            AssistantMemory(id: "demo-memory-farmbox", text: "Groceries include a weekly farm-box delivery", createdAt: now.addingTimeInterval(-9 * 86_400),
                            source: .person),
            AssistantMemory(id: "demo-memory-style", text: "Prefers short answers, with the period named", createdAt: now.addingTimeInterval(-20 * 86_400),
                            source: .person),
        ]
    }
}
