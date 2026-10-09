import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

@Suite("Assistant memory and chat history over HTTP")
struct AssistantRouteTests {
    static func decode<T: Decodable>(_ type: T.Type, _ buffer: ByteBuffer) throws -> T {
        try RemoteBudgetAPI.decoder.decode(T.self, from: Data(buffer.readableBytesView))
    }

    @Test("Memories: list, add (201), edit, delete (204); refusals are 422 and unknown ids 404")
    func memories() async throws {
        let (app, service) = try await TestServer.app()
        try await app.test(.router) { client in
            let listed = try await client.execute(uri: "/v1/assistant/memories", method: .get, headers: TestServer.auth)
            #expect(listed.status == .ok)
            #expect(try Self.decode([AssistantMemory].self, listed.body).count == 3) // the demo household's

            let added = try await client.execute(uri: "/v1/assistant/memories", method: .post, headers: TestServer.auth,
                                                 body: TestServer.body(#"{"text":"  Jordan is my partner "}"#))
            #expect(added.status == .created)
            let memory = try Self.decode(AssistantMemory.self, added.body)
            #expect(memory.text == "Jordan is my partner")
            #expect(memory.source == .person)

            try await client.execute(uri: "/v1/assistant/memories", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"text":"jordan is my partner"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("already keeps that in mind"))
            }
            try await client.execute(uri: "/v1/assistant/memories", method: .post, headers: TestServer.auth, body: TestServer.body(#"{"txt":"x"}"#)) {
                #expect($0.status == .badRequest)
            }
            let edited = try await client.execute(uri: "/v1/assistant/memories/\(memory.id)", method: .patch, headers: TestServer.auth,
                                                  body: TestServer.body(#"{"text":"Jordan and I share the ledger"}"#))
            #expect(edited.status == .ok)
            #expect(try Self.decode(AssistantMemory.self, edited.body).text == "Jordan and I share the ledger")
            try await client.execute(uri: "/v1/assistant/memories/\(memory.id)", method: .delete, headers: TestServer.auth) { #expect($0.status == .noContent) }
            try await client.execute(uri: "/v1/assistant/memories/\(memory.id)", method: .delete, headers: TestServer.auth) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/assistant/memories/nope", method: .patch, headers: TestServer.auth,
                                     body: TestServer.body(#"{"text":"x"}"#)) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/assistant/memories", method: .get) { #expect($0.status == .unauthorized) }
        }
        #expect(try await service.store.loadLedger()?.assistantMemories.count == 3) // written through to the store
    }

    @Test("The app's client: memories, rememberFact, and a conversation listed, continued, reopened, renamed and deleted")
    func parity() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let api: any AssistantAPI = CachingBudgetAPI(upstream: remote, cache: ResponseCache(directory: FileManager.default.temporaryDirectory
                .appending(path: "assistant-parity-\(UUID().uuidString)")))

            let added = try await api.addAssistantMemory("Saving for a new bike")
            #expect(try await api.assistantMemories().first == added)
            #expect(try await api.updateAssistantMemory(id: added.id, text: "Saving for a cargo bike").text == "Saving for a cargo bike")
            try await api.deleteAssistantMemory(id: added.id)
            await #expect(throws: BudgetAPIError.notFound) { try await api.deleteAssistantMemory(id: added.id) }

            let proposal = try #require(try await remote.ask("Remember that we're moving in June", conversationID: nil).proposedActions.first)
            _ = try await remote.perform(proposal.action)
            #expect(try await api.assistantMemories().first?.text == "We're moving in June")
            #expect(try await remote.assistantConfig().systemPrompt.contains("- We're moving in June"))

            #expect(try await api.chatSessions().count == 1) // the remember question was a conversation too
            let first = try await remote.ask("Where did my money go this month?", conversationID: nil)
            let second = try await remote.ask("How much do subscriptions cost me?", conversationID: first.conversationID)
            #expect(second.conversationID == first.conversationID)
            let sessions = try await api.chatSessions()
            #expect(sessions.count == 2)
            #expect(sessions.first?.id == first.conversationID)
            #expect(sessions.first?.title == "Where did my money go this month?")
            let session = try await api.chatSession(id: first.conversationID)
            #expect(session.turns.map(\.reply) == [first, second])
            #expect(try await api.renameChatSession(id: first.conversationID, title: "September").title == "September")
            try await api.deleteChatSession(id: first.conversationID)
            await #expect(throws: BudgetAPIError.notFound) { try await api.chatSession(id: first.conversationID) }
            #expect(try await api.chatSessions().count == 1)
        }
    }

    @Test("/v1/ask takes sessionID as another name for conversationID")
    func sessionAlias() async throws {
        let (app, service) = try await TestServer.app()
        try await app.test(.router) { client in
            let first = try await client.execute(uri: "/v1/ask", method: .post, headers: TestServer.auth,
                                                 body: TestServer.body(#"{"question":"Where did my money go this month?"}"#))
            let id = try Self.decode(AskReply.self, first.body).conversationID
            let second = try await client.execute(uri: "/v1/ask", method: .post, headers: TestServer.auth,
                                                  body: TestServer.body(#"{"question":"How is groceries doing?","sessionID":"\#(id)"}"#))
            #expect(try Self.decode(AskReply.self, second.body).conversationID == id)
        }
        #expect(try await service.api.chatSession(id: (try await service.api.chatSessions())[0].id).turns.count == 2)
    }

    @Test("Resetting the ledger clears its conversations")
    func resetClears() async throws {
        let (app, service) = try await TestServer.app()
        _ = try await service.api.ask("Where did my money go this month?", conversationID: nil)
        #expect(try await service.api.chatSessions().count == 1)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/admin/reset", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"confirm":"erase my ledger"}"#)) { #expect($0.status == .ok) }
        }
        #expect(try await service.api.chatSessions().isEmpty)
        #expect(try await service.api.assistantMemories().isEmpty)
    }

    @Test("The dashboard's Assistant page is embedded, linked from the rail, and writes only through api()")
    func dashboardPage() throws {
        let page = String(decoding: DashboardAssets.page.bytes, as: UTF8.self)
        let module = try #require(DashboardAssets.files["assistant.js"].map { String(decoding: $0.bytes, as: UTF8.self) })
        #expect(page.contains(##"<a href="#/assistant" data-view="assistant">"##))
        #expect(String(decoding: try #require(DashboardAssets.files["app.js"]).bytes, as: UTF8.self).contains(#"import assistant from "./assistant.js""#))
        #expect(module.contains(#"api("/v1/assistant/memories", { method: "POST", body: { text } })"#))
        #expect(module.contains("armed(")) // forgetting and deleting ask twice
    }
}
