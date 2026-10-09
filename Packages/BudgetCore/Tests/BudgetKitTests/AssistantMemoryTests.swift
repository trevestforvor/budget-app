import Foundation
import Testing
@testable import BudgetKit

/// A clock that moves a minute every time it's read, so each question lands after the one before.
final class TickingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func next() -> Date {
        lock.withLock {
            current = current.addingTimeInterval(60)
            return current
        }
    }
}

extension LedgerBudgetAPI {
    /// The demo ledger as a server would run it: a moving clock, no latency, no demo history.
    static func serverLike(clock: TickingClock = TickingClock(Fixture.now), chatModel: (any ChatModel)? = nil) -> LedgerBudgetAPI {
        LedgerBudgetAPI(state: Fixture.ledger().state, calendar: Fixture.calendar, clock: { clock.next() }, chatModel: chatModel,
                        decisions: DecisionRouting(allowDemoFallback: true), persistence: nil,
                        deployment: DeploymentInfo(endpoint: "test", version: "test", sources: [], institutions: []))
    }
}

@Suite("Assistant memory")
struct AssistantMemoryTests {
    @Test("Added, edited and deleted in the ledger; newest first; kept as one line")
    func crud() throws {
        var ledger = Fixture.ledger()
        ledger.assistantMemories = []
        let first = try ledger.addAssistantMemory("  Saving for a trip\n to Lisbon  ", source: .person, id: "a")
        #expect(first.text == "Saving for a trip to Lisbon")
        #expect(first.createdAt == Fixture.now)
        ledger.now = Fixture.now.addingTimeInterval(60)
        try ledger.addAssistantMemory("Groceries include a farm box", source: .assistant, id: "b")
        #expect(ledger.assistantMemoriesNewestFirst.map(\.id) == ["b", "a"])

        ledger.now = Fixture.now.addingTimeInterval(120)
        let edited = try ledger.updateAssistantMemory(id: "a", text: "Saving for a trip to Porto")
        #expect(edited.text == "Saving for a trip to Porto")
        #expect(edited.updatedAt == Fixture.now.addingTimeInterval(120))
        #expect(ledger.assistantMemoriesNewestFirst.map(\.id) == ["a", "b"])

        try ledger.deleteAssistantMemory(id: "b")
        #expect(ledger.assistantMemories.map(\.id) == ["a"])
        #expect(throws: BudgetAPIError.notFound) { try ledger.deleteAssistantMemory(id: "b") }
        #expect(throws: BudgetAPIError.notFound) { try ledger.updateAssistantMemory(id: "zzz", text: "Anything") }
    }

    @Test("Empty, too long, a repeat and a full memory are refused")
    func refusals() throws {
        var ledger = Fixture.ledger()
        ledger.assistantMemories = []
        #expect(throws: BudgetAPIError.self) { try ledger.addAssistantMemory("   ", source: .person) }
        #expect(throws: BudgetAPIError.self) { try ledger.addAssistantMemory(String(repeating: "a", count: AssistantMemory.maxLength + 1), source: .person) }
        try ledger.addAssistantMemory("Jordan is my partner", source: .person, id: "p")
        #expect(throws: BudgetAPIError.rejected("Ask already keeps that in mind.")) { try ledger.addAssistantMemory("jordan IS my partner", source: .person) }
        // Editing a memory to its own text (in other case) is fine; to another's is not.
        try ledger.addAssistantMemory("Walks to work", source: .person, id: "w")
        #expect(throws: BudgetAPIError.self) { try ledger.updateAssistantMemory(id: "w", text: "Jordan is my partner") }
        _ = try ledger.updateAssistantMemory(id: "p", text: "Jordan is my Partner")

        for i in ledger.assistantMemories.count..<AssistantMemory.maxCount { try ledger.addAssistantMemory("Fact number \(i)", source: .person) }
        #expect(throws: BudgetAPIError.self) { try ledger.addAssistantMemory("One too many", source: .person) }
        #expect(throws: BudgetAPIError.self) { try ledger.preview(.rememberFact(RememberFact(fact: "One too many"))) }
    }

    @Test("Saved with the ledger; a ledger saved before memories loads with none")
    func persisted() throws {
        let ledger = Fixture.ledger()
        #expect(ledger.assistantMemories.count == 3) // the demo household's
        let data = try JSONEncoder().encode(ledger.state)
        #expect(try JSONDecoder().decode(LedgerState.self, from: data) == ledger.state)

        guard case var .object(fields) = try JSONValue.parse(data) else { Issue.record("not an object"); return }
        fields["assistantMemories"] = nil
        let old = try JSONDecoder().decode(LedgerState.self, from: try JSONValue.object(fields).data())
        #expect(old.assistantMemories.isEmpty)
        #expect(LedgerState.empty.assistantMemories.isEmpty)
    }

    @Test("rememberFact: a card first, a memory only once applied, credited to the assistant")
    func rememberFact() async throws {
        let api = Fixture.api()
        let before = try await api.assistantMemories()
        let reply = try await api.ask("Remember that we're saving for a new bike", conversationID: nil)
        let proposal = try #require(reply.proposedActions.first)
        #expect(proposal.action == .rememberFact(RememberFact(fact: "We're saving for a new bike")))
        #expect(proposal.title == "Remember: We're saving for a new bike")
        #expect(reply.toolCalls.map(\.name) == ["rememberFact"])
        #expect(try await api.assistantMemories() == before)

        let result = try await api.perform(proposal.action)
        #expect(result.message.contains("We're saving for a new bike"))
        let memories = try await api.assistantMemories()
        #expect(memories.count == before.count + 1)
        #expect(memories.first?.text == "We're saving for a new bike")
        #expect(memories.first?.source == .assistant)
        await #expect(throws: BudgetAPIError.self) { try await api.perform(proposal.action) }
        #expect(try await api.assistantConfig().systemPrompt.contains("- We're saving for a new bike"))

        // A question that starts the same way is still a question.
        let question = try await api.ask("Remember what we spent on dining in Q3?", conversationID: nil)
        #expect(!question.proposedActions.contains { if case .rememberFact = $0.action { true } else { false } })
    }

    @Test("The API's add, edit and delete write through the ledger")
    func apiWrites() async throws {
        let api = Fixture.api()
        let added = try await api.addAssistantMemory("Prefers weekly check-ins")
        #expect(added.source == .person)
        #expect(try await api.assistantMemories().first == added)
        let edited = try await api.updateAssistantMemory(id: added.id, text: "Prefers check-ins on Sundays")
        #expect(edited.text == "Prefers check-ins on Sundays")
        try await api.deleteAssistantMemory(id: added.id)
        #expect(try await api.assistantMemories().contains { $0.id == added.id } == false)
        #expect(await api.state.assistantMemories.count == 3)
    }
}

@Suite("Assistant memory in the prompt")
struct AssistantMemoryPromptTests {
    @Test("Memories get their own section, newest first, and none means no section")
    func section() {
        let ledger = Fixture.ledger()
        let prompt = AssistantPrompt.system(ledger.assistantContext)
        #expect(prompt.contains("# What the user asked you to keep in mind"))
        let trip = try! #require(prompt.range(of: "- Saving for a trip to Lisbon next spring"))
        let farm = try! #require(prompt.range(of: "- Groceries include a weekly farm-box delivery"))
        #expect(trip.lowerBound < farm.lowerBound)
        #expect(!AssistantPrompt.system(ledger.assistantContext.withoutMemories).contains("# What the user asked you to keep in mind"))
        #expect(!AssistantPrompt.system(ledger.assistantContext.withoutMemories).contains("Lisbon"))
    }

    @Test("The section stays within its budget and says how many it left out")
    func capped() {
        let memories = (0..<AssistantMemory.maxCount).map { "Memory \($0) " + String(repeating: "x", count: 180) }
        let section = AssistantPrompt.memorySection(memories)
        let lines = section.split(separator: "\n").filter { $0.hasPrefix("- ") }
        #expect(lines.count < memories.count)
        #expect(lines.reduce(0) { $0 + $1.count + 1 } <= AssistantMemory.promptBudget)
        #expect(lines.first?.hasPrefix("- Memory 0 ") == true)
        #expect(section.contains("(\(memories.count - lines.count) older ones left out for space.)"))
    }

    @Test("A figure in a memory isn't grounding: the model can't quote it as if a tool returned it")
    func notGrounding() async throws {
        var ledger = Fixture.ledger()
        try ledger.addAssistantMemory("Rent goes up to $2,345.67 in March", source: .person)
        let model = ScriptedModel([.say("Your rent will be $2,345.67."), .say("Still $2,345.67.")])
        let outcome = try await AgentLoop(model: model, toolbox: DemoToolbox(ledger: ledger, decisions: nil)).run("What will rent be?")
        #expect(outcome.ungrounded == ["$2,345.67"])
        let system = try #require(await model.requests.first?.messages.first?.content)
        #expect(system.contains("- Rent goes up to $2,345.67 in March"))
    }
}

@Suite("Chat history")
struct ChatHistoryTests {
    @Test("A conversation is kept: titled from its first question, continued by its id")
    func continues() async throws {
        let api = LedgerBudgetAPI.serverLike()
        let first = try await api.ask("Where did my money go this month?", conversationID: nil)
        let second = try await api.ask("How much do subscriptions cost me?", conversationID: first.conversationID)
        #expect(second.conversationID == first.conversationID)
        let list = try await api.chatSessions()
        #expect(list.count == 1)
        #expect(list[0].title == "Where did my money go this month?")
        #expect(list[0].turnCount == 2)
        #expect(list[0].lastQuestion == "How much do subscriptions cost me?")
        let session = try await api.chatSession(id: first.conversationID)
        #expect(session.turns.map(\.question) == ["Where did my money go this month?", "How much do subscriptions cost me?"])
        #expect(session.turns.map(\.reply) == [first, second])
        #expect(session.updatedAt > session.createdAt)

        // A new conversation lists first.
        let other = try await api.ask("How is groceries doing?", conversationID: nil)
        #expect(try await api.chatSessions().map(\.id) == [other.conversationID, first.conversationID])
    }

    @Test("Renamed and deleted; unknown ids are 404s")
    func renameDelete() async throws {
        let api = LedgerBudgetAPI.serverLike()
        let reply = try await api.ask("Where did my money go this month?", conversationID: nil)
        let renamed = try await api.renameChatSession(id: reply.conversationID, title: "  September   spending ")
        #expect(renamed.title == "September spending")
        #expect(try await api.chatSession(id: reply.conversationID).title == "September spending")
        await #expect(throws: BudgetAPIError.self) { try await api.renameChatSession(id: reply.conversationID, title: " ") }
        await #expect(throws: BudgetAPIError.notFound) { try await api.renameChatSession(id: "nope", title: "x") }
        try await api.deleteChatSession(id: reply.conversationID)
        #expect(try await api.chatSessions().isEmpty)
        await #expect(throws: BudgetAPIError.notFound) { try await api.chatSession(id: reply.conversationID) }
        await #expect(throws: BudgetAPIError.notFound) { try await api.deleteChatSession(id: reply.conversationID) }
    }

    @Test("Past the cap the least recently used conversation goes")
    func pruned() async throws {
        let api = LedgerBudgetAPI.serverLike()
        let first = try await api.ask("Where did my money go this month?", conversationID: nil)
        let second = try await api.ask("Where did my money go this month?", conversationID: nil)
        for _ in 0..<(ChatSession.maxSessions - 2) { _ = try await api.ask("How is groceries doing?", conversationID: nil) }
        // The first is used again, so the second is now the least recent.
        _ = try await api.ask("How much do subscriptions cost me?", conversationID: first.conversationID)
        #expect(try await api.chatSessions().count == ChatSession.maxSessions)
        _ = try await api.ask("How is dining doing?", conversationID: nil)
        let ids = try await api.chatSessions().map(\.id)
        #expect(ids.count == ChatSession.maxSessions)
        #expect(ids.contains(first.conversationID))
        #expect(!ids.contains(second.conversationID))
    }

    @Test("A conversation keeps its latest turns, and the model's view of the latest two")
    func turnsCapped() {
        var record = ChatSessionRecord.new(id: "c", question: "q0", at: Fixture.now)
        for i in 0..<(ChatSession.maxTurns + 5) {
            let reply = AskReply(id: "r\(i)", conversationID: "c", text: "a\(i)", figures: [], toolCalls: [], model: "m", followUps: [], proposedActions: [])
            record.append(ChatTurn(id: "t\(i)", question: "q\(i)", askedAt: Fixture.now.addingTimeInterval(Double(i)), reply: reply),
                          transcript: [.user("q\(i)"), .say("a\(i)")])
        }
        #expect(record.session.turns.count == ChatSession.maxTurns)
        #expect(record.session.turns.first?.question == "q5")
        #expect(record.session.title == "q0")
        #expect(Set(record.transcripts.keys) == ["t43", "t44"])
        // Six turns back: the newest two as transcripts, the four before as question and answer.
        let history = record.modelHistory()
        #expect(history.count == ChatSessionRecord.historyTurns * 2)
        #expect(history.first?.content == "q39")
        #expect(history.last?.content == "a44")
    }

    @Test("A grounding retry isn't kept in the transcript")
    func compacted() {
        let kept = ChatSessionRecord.compacted([.user("q"), .call("flexBudget", "{}"), .tool("c-flexBudget", "{}"), .say("$999 draft"),
                                                .user("[system check] These figures…"), .say("final")])
        #expect(kept.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(kept.last?.content == "final")
    }

    @Test("Long titles are cut at a word")
    func titles() {
        #expect(ChatSession.title(for: "  How much  did we spend? ") == "How much did we spend?")
        let long = ChatSession.title(for: "What did we spend on dining and groceries and shopping in the third quarter compared with the second?")
        #expect(long.count <= ChatSession.maxTitleLength)
        #expect(long.hasSuffix("…"))
        #expect(!long.contains("  "))
    }

    @Test("Continuing a conversation shows the model the earlier turn, and its figures stay quotable")
    func agentHistory() async throws {
        let ledger = Fixture.ledger()
        let q3 = ledger.quarter(3, year: 2026)
        let total = ledger.spent(from: q3.start, to: q3.end, categoryID: "dining").display
        let model = ScriptedModel([
            .call("sumByCategory", #"{"period":"2026-Q3","categoryID":"dining"}"#),
            .say("Dining in Q3 is \(total)."),
            .say("As I said, \(total)."),
            .say("unused"),
        ])
        let api = LedgerBudgetAPI.serverLike(chatModel: model)
        let first = try await api.ask("Dining in Q3?", conversationID: nil)
        let second = try await api.ask("Say that again?", conversationID: first.conversationID)
        #expect(second.text == "As I said, \(total).")
        let requests = await model.requests
        #expect(requests.count == 3) // no grounding retry: the figure came from a tool earlier in the conversation
        let sent = requests[2].messages.map(\.role)
        #expect(sent == [.system, .user, .assistant, .tool, .assistant, .user])
        #expect(requests[2].messages[1].content == "Dining in Q3?")
        #expect(requests[2].messages.last?.content == "Say that again?")

        // A different conversation starts clean.
        _ = try? await api.ask("Anything?", conversationID: nil)
        #expect(await model.requests.last?.messages.count == 2)
    }

    @Test("The demo opens with a few conversations to reopen")
    func demoHistory() async throws {
        let api = Fixture.api()
        let list = try await api.chatSessions()
        #expect(list.map(\.title) == ["Where did my money go this month?", "What did we spend on dining in Q3 vs Q2?", "How much do subscriptions cost me?"])
        let calendar = Fixture.calendar
        #expect(calendar.isDate(list[0].updatedAt, inSameDayAs: Fixture.now))
        #expect(!calendar.isDate(list[1].updatedAt, inSameDayAs: Fixture.now))
        let dining = try await api.chatSession(id: "demo-chat-dining")
        #expect(dining.turns.count == 2)
        #expect(dining.turns[1].reply.proposedActions.count == 1)
        #expect(dining.turns.allSatisfy { !DemoAskEngine.isFallback($0.reply) })

        // Two screens reading at once (the hub and Conversations) both see all of it.
        let fresh = Fixture.api()
        async let a = fresh.chatSessions()
        async let b = fresh.chatSessions()
        let (seenA, seenB) = try await (a, b)
        #expect(seenA.count == 3)
        #expect(seenB.count == 3)

        // Asking again continues it.
        _ = try await api.ask("How is groceries doing?", conversationID: "demo-chat-subscriptions")
        #expect(try await api.chatSessions().first?.id == "demo-chat-subscriptions")
        #expect(try await api.chatSession(id: "demo-chat-subscriptions").turns.count == 2)
    }

    @Test("Moving to another store starts with its conversations, and a reset clears them")
    func store() async throws {
        let api = Fixture.api()
        await api.setChatSessionStore(InMemoryChatSessionStore())
        #expect(try await api.chatSessions().isEmpty)
        _ = try await api.ask("Where did my money go this month?", conversationID: nil)
        #expect(try await api.chatSessions().count == 1)
        try await api.clearChatSessions()
        #expect(try await api.chatSessions().isEmpty)
    }

    @Test("Wire forms decode from what an older or newer server sends")
    func wire() throws {
        let summary = #"{"id":"c","title":"T","createdAt":"2026-09-25T17:00:00Z","updatedAt":"2026-09-25T17:00:00Z","turnCount":1,"extra":1}"#
        let decoded = try RemoteBudgetAPI.decoder.decode(ChatSessionSummary.self, from: Data(summary.utf8))
        #expect(decoded.lastQuestion == nil)
        let memory = #"{"id":"m","text":"T","createdAt":"2026-09-25T17:00:00Z","source":"somethingNew"}"#
        #expect(try RemoteBudgetAPI.decoder.decode(AssistantMemory.self, from: Data(memory.utf8)).source == .person)
    }

    @Test("A proposal this version can't read is left out, not the answer or the conversation")
    func unknownProposal() async throws {
        let api = Fixture.api()
        let reply = try await api.ask("Set the dining target to $500", conversationID: "c-unknown")
        let known = try #require(reply.proposedActions.first)
        let session = try await api.chatSession(id: "c-unknown")
        let data = try RemoteBudgetAPI.encoder.encode(session)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var turns = try #require(json["turns"] as? [[String: Any]])
        var stored = try #require(turns[0]["reply"] as? [String: Any])
        var proposals = try #require(stored["proposedActions"] as? [Any])
        let future: [String: Any] = ["id": "p-new", "title": "Something newer", "effects": [] as [Any],
                                     "action": ["type": "somethingNewer", "x": 1] as [String: Any]]
        proposals.insert(future, at: 0)
        proposals.append(future)
        stored["proposedActions"] = proposals
        turns[0]["reply"] = stored
        json["turns"] = turns
        let decoded = try RemoteBudgetAPI.decoder.decode(ChatSession.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(decoded.turns[0].reply.proposedActions == [known])
        #expect(decoded.turns[0].reply.text == reply.text)

        // Round trip unchanged, and an answer without proposals still reads.
        #expect(try RemoteBudgetAPI.decoder.decode(AskReply.self, from: try RemoteBudgetAPI.encoder.encode(reply)) == reply)
        stored["proposedActions"] = nil
        let bare = try RemoteBudgetAPI.decoder.decode(AskReply.self, from: try JSONSerialization.data(withJSONObject: stored))
        #expect(bare.proposedActions.isEmpty)
    }

    @Test("A conversation id is short and not blank")
    func conversationIDs() async throws {
        let api = LedgerBudgetAPI.serverLike()
        await #expect(throws: BudgetAPIError.self) {
            try await api.ask("How is groceries doing?", conversationID: String(repeating: "x", count: ChatSession.maxIDLength + 1))
        }
        let blank = try await api.ask("How is groceries doing?", conversationID: "  ")
        #expect(!blank.conversationID.trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(try await api.chatSessions().map(\.id) == [blank.conversationID])
    }
}
