import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLRequest on Linux
#endif

/// Assistant memory and chat history over HTTP (docs/API.md § Assistant memory and chat history).
extension RemoteBudgetAPI: AssistantAPI {
    public func assistantMemories() async throws -> [AssistantMemory] { try await get("v1/assistant/memories") }

    public func addAssistantMemory(_ text: String) async throws -> AssistantMemory {
        try await send("POST", "v1/assistant/memories", body: AssistantMemoryBody(text: text))
    }

    public func updateAssistantMemory(id: String, text: String) async throws -> AssistantMemory {
        try decode(try await load(try request("PATCH", "v1/assistant/memories", id: id, body: AssistantMemoryBody(text: text))))
    }

    public func deleteAssistantMemory(id: String) async throws {
        _ = try await load(deletion("v1/assistant/memories", id: id))
    }

    public func chatSessions() async throws -> [ChatSessionSummary] { try await get("v1/assistant/sessions") }

    public func chatSession(id: String) async throws -> ChatSession { try await get("v1/assistant/sessions", id: id) }

    public func renameChatSession(id: String, title: String) async throws -> ChatSessionSummary {
        try decode(try await load(try request("PATCH", "v1/assistant/sessions", id: id, body: ChatSessionRename(title: title))))
    }

    public func deleteChatSession(id: String) async throws {
        _ = try await load(deletion("v1/assistant/sessions", id: id))
    }

    private func deletion(_ path: String, id: String) -> URLRequest {
        var request = URLRequest(url: endpoint(path, id: id))
        request.httpMethod = "DELETE"
        return request
    }
}

/// Memory and history are the server's: they always go upstream, never to the offline copy.
extension CachingBudgetAPI: AssistantAPI {
    public func assistantMemories() async throws -> [AssistantMemory] { try await assistant().assistantMemories() }
    public func addAssistantMemory(_ text: String) async throws -> AssistantMemory { try await assistant().addAssistantMemory(text) }
    public func updateAssistantMemory(id: String, text: String) async throws -> AssistantMemory {
        try await assistant().updateAssistantMemory(id: id, text: text)
    }
    public func deleteAssistantMemory(id: String) async throws { try await assistant().deleteAssistantMemory(id: id) }
    public func chatSessions() async throws -> [ChatSessionSummary] { try await assistant().chatSessions() }
    public func chatSession(id: String) async throws -> ChatSession { try await assistant().chatSession(id: id) }
    public func renameChatSession(id: String, title: String) async throws -> ChatSessionSummary {
        try await assistant().renameChatSession(id: id, title: title)
    }
    public func deleteChatSession(id: String) async throws { try await assistant().deleteChatSession(id: id) }

    private func assistant() throws -> any AssistantAPI {
        guard let api = upstream as? any AssistantAPI else { throw BudgetAPIError.notFound }
        return api
    }
}
