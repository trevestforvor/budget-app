import BudgetKit
import Foundation
import Hummingbird

// MARK: - Assistant memory and chat history (server 0.5.0)

/// `/v1/assistant/memories` (what Ask keeps in mind) and `/v1/assistant/sessions` (its conversations). Memories live in
/// the ledger, so they're written like any ledger change; conversations live in the chat store (`budget_chats`).
func addAssistantRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    let api = service.api
    /// Memories and titles are a sentence; a bigger body is a mistake.
    let small = 64 * 1024

    router.get("/v1/assistant/memories") { _, _ in try HTTP.json(try await api.assistantMemories()) }
    router.post("/v1/assistant/memories") { request, _ in
        let body = try await HTTP.body(AssistantMemoryBody.self, request, limit: small)
        return try HTTP.json(try await api.addAssistantMemory(body.text), status: .created)
    }
    router.patch("/v1/assistant/memories/:id") { request, context in
        let body = try await HTTP.body(AssistantMemoryBody.self, request, limit: small)
        return try HTTP.json(try await api.updateAssistantMemory(id: try HTTP.rowID(context), text: body.text))
    }
    router.delete("/v1/assistant/memories/:id") { _, context in
        try await api.deleteAssistantMemory(id: try HTTP.rowID(context))
        return Response(status: .noContent)
    }

    router.get("/v1/assistant/sessions") { _, _ in try HTTP.json(try await api.chatSessions()) }
    router.get("/v1/assistant/sessions/:id") { _, context in try HTTP.json(try await api.chatSession(id: try HTTP.rowID(context))) }
    router.patch("/v1/assistant/sessions/:id") { request, context in
        let body = try await HTTP.body(ChatSessionRename.self, request, limit: small)
        return try HTTP.json(try await api.renameChatSession(id: try HTTP.rowID(context), title: body.title))
    }
    router.delete("/v1/assistant/sessions/:id") { _, context in
        try await api.deleteChatSession(id: try HTTP.rowID(context))
        return Response(status: .noContent)
    }
}
