import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

/// A store that yields several times inside every settings write, so writers that overlap meet there.
actor YieldingStore: ServerStore {
    let base = MemoryStore()
    private(set) var settingWrites = 0
    func migrate() async throws {}
    func loadLedger() async throws -> LedgerState? { try await base.loadLedger() }
    func replaceLedger(_ state: LedgerState) async throws { try await base.replaceLedger(state) }
    func save(from old: LedgerState, to new: LedgerState) async throws { try await base.save(from: old, to: new) }
    func links() async throws -> [StoredLink] { try await base.links() }
    func upsertLink(_ link: StoredLink) async throws { try await base.upsertLink(link) }
    func deleteLink(_ id: String) async throws { try await base.deleteLink(id) }
    func imports() async throws -> [ImportRecord] { try await base.imports() }
    func upsertImport(_ record: ImportRecord) async throws { try await base.upsertImport(record) }
    func clearImports() async throws { try await base.clearImports() }
    func setting(_ key: String) async throws -> Data? { try await base.setting(key) }
    func saveSetting(_ key: String, _ document: Data) async throws {
        for _ in 0..<5 { await Task.yield() }
        settingWrites += 1
        try await base.saveSetting(key, document)
    }
}

/// A stand-in model server on 127.0.0.1 that answers the model list, chat and `/v1/systemone`, and records the
/// Authorization header of every request it gets.
final class FakeModelServer: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(path: String, authorization: String?)] = []
    var seen: [(path: String, authorization: String?)] { lock.withLock { log } }
    func authorizations(_ path: String) -> [String?] { seen.filter { $0.path == path }.map(\.authorization) }

    private func answer(_ request: Request, _ json: String) -> Response {
        lock.withLock { log.append((request.uri.path, request.headers[.authorization])) }
        return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(string: json)))
    }

    /// Runs `body` with this many servers listening, each on its own port.
    static func with<T>(_ count: Int, _ body: ([(url: URL, server: FakeModelServer)]) async throws -> T) async throws -> T {
        var running: [(url: URL, server: FakeModelServer)] = []
        var tasks: [Task<Void, any Error>] = []
        defer { tasks.forEach { $0.cancel() } }
        for _ in 0..<count {
            let server = FakeModelServer()
            let router = Router()
            router.get("/v1/models") { request, _ in server.answer(request, #"{"data":[{"id":"smart"},{"id":"other"}]}"#) }
            router.post("/v1/chat/completions") { request, _ in
                // "unlisted" stands for a model the list leaves out that the server then refuses, saying why (as OpenRouter does).
                let sent = String(buffer: try await request.body.collect(upTo: 1 << 20))
                guard !sent.contains(#""model":"unlisted""#) else {
                    return Response(status: .notFound, headers: [.contentType: "application/json"],
                                    body: ResponseBody(byteBuffer: ByteBuffer(string: #"{"error":{"message":"No endpoints found for unlisted.","code":404}}"#)))
                }
                return server.answer(request, #"{"choices":[{"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}"#)
            }
            router.post("/v1/systemone") { request, _ in
                server.answer(request, #"{"model":"clef","answers":{"category":{"type":"choice","choice":"dining","probabilities":{"dining":0.9}}}}"#)
            }
            let (ports, continuation) = AsyncStream.makeStream(of: Int.self)
            var logger = Logger(label: "fake-model")
            logger.logLevel = .critical  // its shutdown when the test ends isn't news
            let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)),
                                  onServerRunning: { continuation.yield($0.localAddress?.port ?? 0) }, logger: logger)
            tasks.append(Task { try await app.runService(gracefulShutdownSignals: []) })
            var iterator = ports.makeAsyncIterator()
            let port = try #require(await iterator.next())
            running.append((URL(string: "http://127.0.0.1:\(port)")!, server))
        }
        return try await body(running)
    }
}

/// The models a `ServerSettings` has in force, read in one go.
struct InForce {
    var chatURL: String?
    var chatKey: String?
    var chatName: String
    var decisionURL: String?
    var decisionKey: String?
}

extension ServerSettings {
    func inForce() -> InForce {
        InForce(chatURL: modelBaseURL?.absoluteString, chatKey: modelAPIKey, chatName: modelName,
                decisionURL: decisionBaseURL?.absoluteString, decisionKey: decisionAPIKey)
    }
}

enum ModelFixtures {
    static let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
    static let sealer = try! TokenSealer(base64Key: TestServer.key)
    /// Another server's BUDGET_TOKEN_KEY.
    static let otherSealer = try! TokenSealer(base64Key: Data((0..<32).map { UInt8(255 - $0) }).base64EncodedString())

    static func settings(_ config: ServerConfig = TestServer.config(), store: any ServerStore, sealer: TokenSealer? = sealer) -> ServerSettings {
        ServerSettings(config: config, store: store, sealer: sealer, logger: Logger(label: "test"))
    }

    /// A loaded service and its dashboard router.
    static func dashboard(_ config: ServerConfig = TestServer.config(), store: MemoryStore = MemoryStore()) async throws -> (some ApplicationProtocol, BudgetService) {
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: store, logger: Logger(label: "test"))
        try await BudgetServerApp.prepare(service)
        return (Application(router: buildRouter(service, surface: .dashboard)), service)
    }

    static func json(_ response: TestResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
    }

    static func chat(_ model: String, at address: String, key: String? = nil, name: String? = nil) -> ModelDraft {
        ModelDraft(kind: "chat", name: name, address: address, apiKey: key, model: model)
    }

    /// A chat model as stored, id "c", with no key.
    static func savedChat(_ model: String, at address: String) -> SavedModel {
        SavedModel(id: "c", kind: .chat, name: model, address: address, model: model)
    }

    static func modelsDocument(_ store: any ServerStore) async throws -> [String: Any] {
        let data = try #require(try await store.setting("models"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite("Saved models: several per job, one picked, imported from 0.5.0 and mirrored back for a rollback")
struct ModelSettingsTests {
    // MARK: Import

    @Test("Import from a 0.5.0 row: each (address, key, model) as it was paired, environment values inherited, never copied")
    func importLegacy() async throws {
        let sealedChat = try ModelFixtures.sealer.seal("sk-a")
        func loaded(_ values: [String: String]?, config: ServerConfig = TestServer.config(), sealer: TokenSealer? = ModelFixtures.sealer) async throws -> (ServerSettings, MemoryStore) {
            let store = MemoryStore()
            if let values { try await store.saveServerSettings(StoredServerSettings(values: values)) }
            let settings = ModelFixtures.settings(config, store: store, sealer: sealer)
            try await settings.load()
            return (settings, store)
        }

        // (a) Nothing anywhere: Ask is off, categorizing would use the (missing) chat server, and nothing is saved.
        let (a, aStore) = try await loaded(nil)
        let aList = await a.modelList()
        #expect(aList.chat.isEmpty && aList.decision.isEmpty && aList.chatInUse == "off" && aList.decisionInUse == "chat")
        let aNow = await a.inForce()
        #expect(aNow.chatURL == nil && aNow.decisionURL == nil)
        #expect(try await aStore.modelSettings() == StoredModelSettings())

        // (b) Only the Olares app's address: nothing saved, the environment entry in use.
        var env = TestServer.config()
        env.modelBaseURL = URL(string: "https://qwen.example/v1")
        env.modelAPIKey = "mk-env"
        let (b, bStore) = try await loaded([:], config: env)
        let bList = await b.modelList()
        #expect(bList.chat.map(\.id) == ["environment"] && bList.chatInUse == "environment")
        #expect(bList.chat.first?.inherits == ["address", "key", "model"] && bList.chat.first?.origin == "environment")
        #expect(try await bStore.modelSettings()?.models.isEmpty == true)
        let bNow = await b.inForce()
        #expect(bNow.chatURL == "https://qwen.example" && bNow.chatKey == "mk-env")

        // (c) Address, key and name saved on the dashboard: one entry with the very same sealed string, in use.
        let (c, cStore) = try await loaded(["modelBaseURL": "https://switchboard.example", "modelAPIKey": sealedChat, "modelName": "smart"])
        let cSaved = try #require(try await cStore.modelSettings())
        #expect(cSaved.models == [SavedModel(id: "migrated-chat", kind: .chat, name: "smart", address: "https://switchboard.example", sealedKey: sealedChat, model: "smart")])
        #expect(cSaved.inUse == ["chat": "migrated-chat"])
        #expect(cSaved.mirrored == ["modelBaseURL": "https://switchboard.example", "modelAPIKey": sealedChat, "modelName": "smart"])
        let cNow = await c.inForce()
        #expect(cNow.chatKey == "sk-a" && cNow.chatName == "smart" && cNow.decisionKey == "sk-a")

        // (d) Only the model name on the dashboard, address and key from the Olares app, and no sealer: the entry follows
        // the app for both, so its key is still the one sent, and it never lands in the database.
        let (d, dStore) = try await loaded(["modelName": "smart"], config: env, sealer: nil)
        let dEntry = try #require(try await dStore.modelSettings()?.models.first)
        #expect(dEntry.id == "migrated-chat" && dEntry.inherit == ["address", "key"] && dEntry.address == nil && dEntry.sealedKey == nil && dEntry.model == "smart")
        let dNow = await d.inForce()
        #expect(dNow.chatKey == "mk-env" && dNow.chatURL == "https://qwen.example" && dNow.chatName == "smart")
        #expect(dNow.decisionURL == "https://qwen.example" && dNow.decisionKey == "mk-env")
        #expect(await d.modelList().chatInUse == "migrated-chat")
        #expect(!String(decoding: try #require(try await dStore.setting("models")), as: UTF8.self).contains("mk-env"))
        // The same with DECISION_API_KEY set: the chat address still comes from the Olares app, so categorizing there
        // sends DECISION_API_KEY, as 0.5.0 did.
        var envPaired = env
        envPaired.decisionAPIKey = "dk-env"
        let (dPaired, _) = try await loaded(["modelName": "smart"], config: envPaired)
        let dPairedNow = await dPaired.inForce()
        #expect(dPairedNow.chatKey == "mk-env" && dPairedNow.decisionURL == "https://qwen.example" && dPairedNow.decisionKey == "dk-env")

        // (e) Ask turned off on the dashboard, even with an address in the Olares app.
        let (e, _) = try await loaded(["modelBaseURL": "", "modelName": "leftover"], config: env)
        #expect(await e.modelList().chatInUse == "off")
        #expect(await e.modelBaseURL == nil)

        // (f) Categorizing on the chat model's server, even with a decision server in the Olares app. That server's
        // DECISION_API_KEY stays with it: the chat model's server gets the chat model's key.
        var envDecision = env
        envDecision.decisionBaseURL = URL(string: "https://clef.example")
        envDecision.decisionAPIKey = "dk-env"
        let (f, _) = try await loaded(["decisionBaseURL": ""], config: envDecision)
        #expect(await f.modelList().decisionInUse == "chat")
        #expect(await f.decisionBaseURL?.absoluteString == "https://qwen.example")
        #expect(await f.decisionAPIKey == "mk-env")

        // (g) A decision server of its own on the dashboard with its key from the Olares app: the key is inherited.
        var envKey = TestServer.config()
        envKey.decisionAPIKey = "dk-env"
        let (g, gStore) = try await loaded(["decisionBaseURL": "https://decide.example"], config: envKey)
        let gEntry = try #require(try await gStore.modelSettings()?.models.first)
        #expect(gEntry.id == "migrated-decision" && gEntry.kind == .decision && gEntry.inherit == ["key"] && gEntry.name == "decide.example")
        let gNow = await g.inForce()
        #expect(gNow.decisionURL == "https://decide.example" && gNow.decisionKey == "dk-env")

        // A key alone never moves to a server it wasn't used with: no decision server of its own, so it's dropped.
        let (h, hStore) = try await loaded(["decisionAPIKey": try ModelFixtures.sealer.seal("dk-dash")], config: env)
        #expect(try await hStore.modelSettings()?.models.isEmpty == true)
        #expect(await h.modelList().decisionInUse == "chat")

        // DECISION_API_KEY turned off on 0.5.0's dashboard, categorizing on the Olares app's chat server: it stays off,
        // and the chat model's key goes there, with or without the empty decision address.
        for row in [["decisionAPIKey": ""], ["decisionBaseURL": "", "decisionAPIKey": ""]] {
            let (off, offStore) = try await loaded(row, config: envPaired)
            let offSaved = try #require(try await offStore.modelSettings())
            #expect(offSaved.chatServerKey == "chat" && offSaved.models.isEmpty && offSaved.inUse["decision"] == row["decisionBaseURL"].map { _ in "chat" })
            let offNow = await off.inForce()
            #expect(offNow.decisionURL == "https://qwen.example" && offNow.decisionKey == "mk-env")
            // Still off after a models write, and in the row a rolled-back 0.5.0 reads.
            try await off.use(chat: "environment", decision: nil)
            #expect(await off.decisionAPIKey == "mk-env")
            #expect(try await offStore.serverSettings()?.values["decisionAPIKey"] == "")
        }

        // Loading again imports nothing new: the mirror matches.
        let again = ModelFixtures.settings(store: cStore)
        try await again.load()
        #expect(try await cStore.modelSettings() == cSaved)
    }

    @Test("Rolled back to 0.5.0, edited there, upgraded again: every saved model survives, and the pick follows the 0.5.0 edit")
    func rollbackRoundTrip() async throws {
        let store = MemoryStore()
        let settings = ModelFixtures.settings(store: store)
        try await settings.load()
        try await settings.update(["syncIntervalHours": "2"])
        let (a, _) = try await settings.saveModel(ModelFixtures.chat("model-a", at: "https://a.example", key: "sk-a", name: "Alpha"), policy: .off)
        let (b, _) = try await settings.saveModel(ModelFixtures.chat("model-b", at: "https://b.example", key: "sk-b"), policy: .off)
        try await settings.use(chat: b, decision: nil)
        let mirrored = try #require(try await store.serverSettings()).values
        let bSealed = try #require(try await store.modelSettings()?.models.first { $0.id == b }?.sealedKey)
        #expect(mirrored["modelBaseURL"] == "https://b.example" && mirrored["modelAPIKey"] == bSealed && mirrored["modelName"] == "model-b")

        // 0.5.0 changes the model name and writes its row whole: {values} only.
        var old = mirrored
        old["modelName"] = "model-b2"
        try await store.saveSetting("server", JSONSerialization.data(withJSONObject: ["values": old]))
        let upgraded = ModelFixtures.settings(store: store)
        try await upgraded.load()
        let list = await upgraded.modelList()
        #expect(Set(list.chat.map(\.id)) == [a, b, "migrated-chat"])
        #expect(list.chat.first { $0.id == a }?.name == "Alpha")
        #expect(list.chatInUse == "migrated-chat" && list.chat.first { $0.id == "migrated-chat" }?.model == "model-b2")
        let upgradedNow = await upgraded.inForce()
        #expect(upgradedNow.chatName == "model-b2" && upgradedNow.chatKey == "sk-b") // the same sealed key, paired as it was
        #expect(await upgraded.syncIntervalHours == 2)

        // Back on a saved model's exact values: that one is reused rather than added again.
        let aEntry = try #require(try await store.modelSettings()?.models.first { $0.id == a })
        old = ["modelBaseURL": "https://a.example", "modelAPIKey": try #require(aEntry.sealedKey), "modelName": "model-a", "syncIntervalHours": "2.0"]
        try await store.saveServerSettings(StoredServerSettings(values: old))
        try await upgraded.load()
        let reused = await upgraded.modelList()
        #expect(reused.chatInUse == a && reused.chat.count == 3)
    }

    @Test("The rollback mirror follows the stored pick: a saved model's values, the Olares app's (nothing), or off")
    func mirror() async throws {
        var config = TestServer.config()
        config.modelBaseURL = URL(string: "https://qwen.example")
        let store = MemoryStore()
        let settings = ModelFixtures.settings(config, store: store)
        try await settings.load()
        let (id, picked) = try await settings.saveModel(ModelFixtures.chat("smart", at: "https://switchboard.example/v1", key: "sk-s"), policy: .off)
        #expect(!picked) // the Olares app already sets one
        func flat() async throws -> [String: String] { ServerSettings.flatModelValues(try #require(try await store.serverSettings()).values) }

        try await settings.use(chat: id, decision: nil)
        let sealed = try #require(try await store.modelSettings()?.models.first?.sealedKey)
        #expect(try await flat() == ["modelBaseURL": "https://switchboard.example", "modelAPIKey": sealed, "modelName": "smart"])
        #expect(try await store.modelSettings()?.mirrored == (try await flat()))
        try await settings.use(chat: "environment", decision: nil)
        #expect(try await flat().isEmpty)
        try await settings.use(chat: "off", decision: "chat")
        // Categorizing on the chat model's server mirrors as an empty address; with no DECISION_API_KEY, 0.5.0 then
        // borrows the chat model's key by itself.
        #expect(try await flat() == ["modelBaseURL": "", "decisionBaseURL": ""])

        // On the Olares app's chat server with DECISION_API_KEY set, 0.5.0 sends that key: the mirror leaves it to.
        var paired = config
        paired.decisionAPIKey = "dk-env"
        let pairedStore = MemoryStore()
        let pairedSettings = ModelFixtures.settings(paired, store: pairedStore)
        try await pairedSettings.load()
        try await pairedSettings.use(chat: "environment", decision: "chat")
        #expect(ServerSettings.flatModelValues(try #require(try await pairedStore.serverSettings()).values) == ["decisionBaseURL": ""])
        #expect(await pairedSettings.decisionAPIKey == "dk-env")
        // A saved chat model's own key goes with it to categorizing, and the mirror says so: an empty key, or 0.5.0 would
        // send DECISION_API_KEY there.
        let (own, _) = try await pairedSettings.saveModel(ModelFixtures.chat("smart", at: "https://s.example", key: "sk-own"), policy: .off)
        try await pairedSettings.use(chat: own, decision: nil)
        let pairedNow = await pairedSettings.inForce()
        #expect(pairedNow.decisionKey == "sk-own" && pairedNow.decisionURL == "https://s.example")
        #expect(try await pairedStore.serverSettings()?.values["decisionAPIKey"] == "")

        // With no categorizing pick at all it's the same: the default is the chat model's server.
        let defaultStore = MemoryStore()
        let defaultSettings = ModelFixtures.settings(paired, store: defaultStore)
        try await defaultSettings.load()
        let (cloud, _) = try await defaultSettings.saveModel(ModelFixtures.chat("x/y", at: "https://openrouter.ai/api/v1", key: "sk-cloud"), policy: .off)
        try await defaultSettings.use(chat: cloud, decision: nil)
        #expect(await defaultSettings.decisionAPIKey == "sk-cloud")
        let defaultFlat = ServerSettings.flatModelValues(try #require(try await defaultStore.serverSettings()).values)
        #expect(defaultFlat["decisionBaseURL"] == nil && defaultFlat["decisionAPIKey"] == "")
    }

    // MARK: Picks over HTTP

    @Test("A second chat model, picked, answers Ask at once; /v1/status names it")
    func secondChatModelLive() async throws {
        var config = TestServer.config()
        config.modelBaseURL = URL(string: "https://qwen.example")
        let (dash, service) = try await ModelFixtures.dashboard(config)
        try await dash.test(.router) { client in
            var id = ""
            try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"kind":"chat","name":"Claude","address":"https://openrouter.ai/api/v1","apiKey":"sk-or-chat","model":"anthropic/claude"}"#)) { response in
                #expect(response.status == .ok)
                let body = try ModelFixtures.json(response)
                id = try #require(body["id"] as? String)
                #expect(body["autoSelected"] as? Bool == false)
                let list = try #require(body["list"] as? [String: Any])
                let chat = try #require(list["chat"] as? [[String: Any]])
                #expect(chat.map { $0["id"] as? String } == ["environment", id])
                #expect(chat.last?["local"] as? Bool == false && chat.first?["local"] as? Bool == false)
                #expect(!String(buffer: response.body).contains("sk-or-chat"))
            }
            try await client.execute(uri: "/dash/models/use", method: .post, headers: ModelFixtures.write, body: TestServer.body(#"{"chat":"\#(id)"}"#)) { response in
                #expect(response.status == .ok)
                let list = try ModelFixtures.json(response)
                #expect(list["chatInUse"] as? String == id)
            }
            try await client.execute(uri: "/v1/status", method: .get) { response in
                let status = try RemoteBudgetAPI.decoder.decode(ServerStatus.self, from: Data(response.body.readableBytesView))
                #expect(status.roles.first { $0.role == .chat }?.model == "anthropic/claude")
                #expect(status.version == "0.5.3")
            }
            try await client.execute(uri: "/dash/models/use", method: .post, headers: ModelFixtures.write, body: TestServer.body(#"{"chat":"nope"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("No such model."))
            }
        }
        #expect(await service.settings.modelName == "anthropic/claude")
    }

    @Test("A new chat model is put in use only on a server with none; an explicit Off stays off, and so does a live categorizer")
    func autoSelect() async throws {
        let (dash, service) = try await ModelFixtures.dashboard()
        try await dash.test(.router) { client in
            try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"kind":"chat","address":"http://qwen.local:8000","model":"qwen"}"#)) { response in
                let body = try ModelFixtures.json(response)
                #expect(body["autoSelected"] as? Bool == true)
                let list = try #require(body["list"] as? [String: Any])
                #expect(list["chatInUse"] as? String == body["id"] as? String)
                #expect((list["chat"] as? [[String: Any]])?.first?["local"] as? Bool == true)
                #expect((list["chatServer"] as? [String: Any])?["address"] as? String == "http://qwen.local:8000")
            }
            // A second one isn't: switching is the person's call.
            try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"kind":"chat","address":"https://api.example","model":"big"}"#)) { response in
                let body = try ModelFixtures.json(response)
                #expect(body["autoSelected"] as? Bool == false)
            }
        }
        #expect(try await service.api.serverStatus().roles.first { $0.role == .chat }?.model == "qwen")

        let (offDash, offService) = try await ModelFixtures.dashboard()
        try await offDash.test(.router) { client in
            try await client.execute(uri: "/dash/models/use", method: .post, headers: ModelFixtures.write, body: TestServer.body(#"{"chat":"off"}"#)) { #expect($0.status == .ok) }
            try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"kind":"chat","address":"https://api.example","model":"big"}"#)) { response in
                let body = try ModelFixtures.json(response)
                #expect(body["autoSelected"] as? Bool == false)
                #expect((body["list"] as? [String: Any])?["chatInUse"] as? String == "off")
            }
        }
        #expect(try await offService.api.serverStatus().roles.first { $0.role == .chat }?.model == nil)

        // Categorizing runs on the chat model's server: picking a new chat model would move it too, so it waits.
        let (_, live) = try await ModelFixtures.dashboard()
        let settings = live.settings
        let (clef, _) = try await settings.saveModel(ModelDraft(kind: "decision", address: "http://clef.local"), policy: .off)
        try await settings.use(chat: nil, decision: clef)
        await BudgetServerApp.apply(live)
        _ = try await live.api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .localDecide, rerunPending: false)))
        try await settings.use(chat: nil, decision: "chat")
        let (_, picked) = try await settings.saveModel(ModelFixtures.chat("big", at: "https://api.example"), policy: .localDecide)
        #expect(!picked)
        #expect(await settings.modelList().chatInUse == "off")
    }

    @Test("The model in use can't be removed; a categorizing server picked while categorizing is elsewhere can, and the pick resets")
    func remove() async throws {
        let (dash, service) = try await ModelFixtures.dashboard()
        let settings = service.settings
        let (chat, _) = try await settings.saveModel(ModelFixtures.chat("qwen", at: "http://qwen.local"), policy: .off)
        let (clef, _) = try await settings.saveModel(ModelDraft(kind: "decision", address: "http://clef.local"), policy: .off)
        try await settings.use(chat: nil, decision: clef)
        await BudgetServerApp.apply(service)
        try await dash.test(.router) { client in
            try await client.execute(uri: "/dash/models/remove", method: .post, headers: ModelFixtures.write, body: TestServer.body(#"{"id":"\#(chat)"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("In use. Pick another one and save first."))
            }
            try await client.execute(uri: "/dash/models/remove", method: .post, headers: ModelFixtures.write, body: TestServer.body(#"{"id":"environment"}"#)) { response in
                #expect(String(buffer: response.body).contains("That one comes from the Olares app's settings; change it there."))
            }
            // Categorizing runs on Clef: it stays.
            try await client.execute(uri: "/v1/actions", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"type":"updateDecisionPolicy","provider":"localDecide","rerunPending":false}"#)) { #expect($0.status == .ok) }
            try await client.execute(uri: "/dash/models/remove", method: .post, headers: ModelFixtures.write, body: TestServer.body(#"{"id":"\#(clef)"}"#)) {
                #expect($0.status == .unprocessableContent)
            }
            // Jev categorizes now: Clef only looks picked, and goes.
            try await client.execute(uri: "/dash/settings", method: .patch, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"changes":{"openRouterKey":"sk-or-jev"}}"#)) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/actions", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"type":"updateDecisionPolicy","provider":"jev","rerunPending":false}"#)) { #expect($0.status == .ok) }
            try await client.execute(uri: "/dash/models/remove", method: .post, headers: ModelFixtures.write, body: TestServer.body(#"{"id":"\#(clef)"}"#)) { response in
                #expect(response.status == .ok)
                let list = try ModelFixtures.json(response)
                #expect(list["decisionInUse"] as? String == "chat" && (list["decision"] as? [Any])?.isEmpty == true)
            }
        }
        #expect(try await service.store.modelSettings()?.inUse["decision"] == nil)
    }

    // MARK: Keys

    @Test("A saved key only goes to its own server: names, Test and Save with another address never send or keep it")
    func keyStaysWithItsServer() async throws {
        let (dash, service) = try await ModelFixtures.dashboard()
        try await FakeModelServer.with(2) { servers in
            let (home, other) = (servers[0], servers[1])
            let (id, _) = try await service.settings.saveModel(ModelFixtures.chat("smart", at: home.url.absoluteString, key: "sk-home"), policy: .off)
            try await dash.test(.router) { client in
                func post(_ uri: String, _ json: String) async throws -> [String: Any] {
                    try await client.execute(uri: uri, method: .post, headers: ModelFixtures.write, body: TestServer.body(json)) { response in
                        #expect(response.status == .ok, "\(uri) \(json)")
                        return try ModelFixtures.json(response)
                    }
                }
                // Its own server: the key goes along.
                #expect(try await post("/dash/models/names", #"{"id":"\#(id)"}"#)["models"] as? [String] == ["other", "smart"])
                #expect(home.server.authorizations("/v1/models") == ["Bearer sk-home"])
                // Another server: the names list and Test go without it.
                #expect(try await post("/dash/models/names", #"{"id":"\#(id)","address":"\#(other.url.absoluteString)/v1"}"#)["models"] as? [String] == ["other", "smart"])
                #expect(other.server.authorizations("/v1/models") == [nil])
                let elsewhere = try await post("/dash/models/test", #"{"draft":{"kind":"chat","id":"\#(id)","address":"\#(other.url.absoluteString)"}}"#)
                #expect((elsewhere["draft"] as? [String: Any])?["ok"] as? Bool == true)
                #expect(elsewhere["models"] as? [String] == ["other", "smart"])
                #expect(other.server.authorizations("/v1/chat/completions") == [nil])
                // Categorizing's "chat" entry follows the same rule.
                _ = try await post("/dash/models/test", #"{"draft":{"kind":"decision","id":"chat","address":"\#(other.url.absoluteString)"}}"#)
                #expect(other.server.authorizations("/v1/systemone") == [nil])
                _ = try await post("/dash/models/test", #"{"draft":{"kind":"decision","id":"chat"}}"#)
                #expect(home.server.authorizations("/v1/systemone") == ["Bearer sk-home"])
                // Home again, with the key, unless it's about to be removed.
                _ = try await post("/dash/models/test", #"{"draft":{"kind":"chat","id":"\#(id)"}}"#)
                _ = try await post("/dash/models/test", #"{"draft":{"kind":"chat","id":"\#(id)","removeKey":true}}"#)
                #expect(home.server.authorizations("/v1/chat/completions") == ["Bearer sk-home", nil])
                // The card's Test of the saved entry.
                let saved = try await post("/dash/models/test", #"{"chat":["\#(id)"]}"#)
                #expect(((saved["chat"] as? [String: Any])?[id] as? [String: Any])?["ok"] as? Bool == true)
                #expect(home.server.authorizations("/v1/chat/completions").last == "Bearer sk-home")

                // Saving it on another server keeps no key: type that server's, or remove it.
                try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                         body: TestServer.body(#"{"id":"\#(id)","kind":"chat","address":"\#(other.url.absoluteString)","model":"smart"}"#)) { response in
                    #expect(response.status == .unprocessableContent)
                    #expect(String(buffer: response.body).contains("The address is on another server now: type its API key, or remove the key."))
                }
                // The same server written another way is the same server.
                try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                         body: TestServer.body(#"{"id":"\#(id)","kind":"chat","address":"\#(home.url.absoluteString)/v1/","model":"smart"}"#)) {
                    #expect($0.status == .ok)
                }
                let moved = try await post("/dash/models/save", #"{"id":"\#(id)","kind":"chat","address":"\#(other.url.absoluteString)","model":"smart","removeKey":true}"#)
                let entry = ((moved["list"] as? [String: Any])?["chat"] as? [[String: Any]])?.first { $0["id"] as? String == id }
                #expect(entry?["hasKey"] as? Bool == false && entry?["address"] as? String == other.url.absoluteString)
            }
        }
    }

    @Test("A chat model on OpenRouter can save a copy of Jev's key: only at OpenRouter's https address, only with a key saved, never sent elsewhere")
    func jevKeyForChat() async throws {
        let (dash, service) = try await ModelFixtures.dashboard()
        let settings = service.settings
        let openRouter = ModelDraft(kind: "chat", address: "https://openrouter.ai/api/v1", model: "anthropic/claude-sonnet-4.5", useOpenRouterKey: true)
        await #expect(throws: BudgetAPIError.rejected("No OpenRouter key is saved. Add one on Jev first.")) { try await settings.saveModel(openRouter, policy: .off) }
        try await settings.update(["openRouterKey": "sk-or-jev"])
        for address in ["https://api.openai.com", "http://openrouter.ai/api/v1", "https://openrouter.ai.evil.example"] {
            var elsewhere = openRouter
            elsewhere.address = address
            await #expect(throws: BudgetAPIError.rejected("Jev's OpenRouter key only goes to OpenRouter: use the address https://openrouter.ai/api/v1."), "\(address)") {
                try await settings.saveModel(elsewhere, policy: .off)
            }
        }
        await #expect(throws: BudgetAPIError.rejected("Jev's OpenRouter key only goes to OpenRouter: use the address https://openrouter.ai/api/v1.")) {
            try await settings.saveModel(ModelDraft(kind: "decision", address: "https://openrouter.ai/api/v1", useOpenRouterKey: true), policy: .off)
        }

        let (id, picked) = try await settings.saveModel(openRouter, policy: .off)
        #expect(picked)
        #expect(await settings.connection(.chat, id: id)?.key == "sk-or-jev")
        #expect(await settings.modelSnapshot().chatKey == "sk-or-jev")
        // A copy: a new key on Jev leaves it as it was, and the rollback mirror carries it sealed like a typed one.
        try await settings.update(["openRouterKey": "sk-or-new"])
        #expect(await settings.connection(.chat, id: id)?.key == "sk-or-jev")
        let mirrored = try #require(try await service.store.serverSettings()?.values["modelAPIKey"])
        #expect(mirrored != "sk-or-jev" && (try? ModelFixtures.sealer.open(mirrored)) == "sk-or-jev")
        // Editing it with the switch on takes Jev's key as it is now.
        _ = try await settings.saveModel(ModelDraft(id: id, kind: "chat", useOpenRouterKey: true), policy: .off)
        #expect(await settings.connection(.chat, id: id)?.key == "sk-or-new")

        // Names and Test at any other address go without it.
        try await FakeModelServer.with(1) { servers in
            let other = servers[0]
            try await dash.test(.router) { client in
                for (uri, json) in [("/dash/models/names", #"{"address":"\#(other.url.absoluteString)","useOpenRouterKey":true}"#),
                                    ("/dash/models/test", #"{"draft":{"kind":"chat","address":"\#(other.url.absoluteString)","model":"smart","useOpenRouterKey":true}}"#)] {
                    try await client.execute(uri: uri, method: .post, headers: ModelFixtures.write, body: TestServer.body(json)) { #expect($0.status == .ok) }
                }
            }
            #expect(other.server.authorizations("/v1/models").allSatisfy { $0 == nil })
            #expect(other.server.authorizations("/v1/chat/completions") == [nil])
        }
    }

    @Test("A refused model the server doesn't list: Test shows what the server said, with the list's note beside it, never instead")
    func refusalKept() async throws {
        try await FakeModelServer.with(1) { servers in
            let outcome = await ModelCheck.chat(base: servers[0].url, key: nil, model: "unlisted")
            #expect(!outcome.ok)
            #expect(outcome.detail == #"The server answered 404 at /v1/chat/completions. It said: {"error":{"message":"No endpoints found for unlisted.","code":404}} Its model list doesn't include “unlisted”; it offers: other, smart."#)
        }
    }

    @Test("The Model list keeps the models that take tools when the server says which do; a test's \"no such model\" sees them all")
    func toolNames() {
        let data = Data(#"{"data":[{"id":"b/tools","supported_parameters":["tools","temperature"]},{"id":"a/plain","supported_parameters":["temperature"]},{"id":"c/unsaid"}]}"#.utf8)
        #expect(ModelCheck.modelNames(data, toolsOnly: true) == ["b/tools", "c/unsaid"])
        #expect(ModelCheck.modelNames(data, toolsOnly: false) == ["a/plain", "b/tools", "c/unsaid"])
        #expect(ModelCheck.modelNames(Data("nope".utf8), toolsOnly: true) == nil)
        let refused = ModelCheck.explain(DecisionError.http(404, #"{"error":{"message":"No endpoints found matching your data policy (Zero data retention)","code":404}}"#),
                                         path: "/api/v1/chat/completions", key: "k", decision: false)
        #expect(refused.hasPrefix("OpenRouter has no provider for this model that keeps nothing."))
    }

    @Test("Categorizing on the chat model's server sends DECISION_API_KEY only where it's meant to go: the Olares app's chat server, with no decision server of its own")
    func decisionKeyOnTheChatServer() async throws {
        try await FakeModelServer.with(2) { servers in
            let (chat, clef) = (servers[0], servers[1])
            var config = TestServer.config()
            config.modelBaseURL = chat.url.appending(path: "v1")
            config.modelAPIKey = "chat-secret"
            config.decisionBaseURL = clef.url
            config.decisionAPIKey = "decision-secret"
            // DECISION_BASE_URL is a server of its own: the card's Test of everything sends its key there, and the chat
            // model's key to the chat model's server.
            let (dash, _) = try await ModelFixtures.dashboard(config)
            try await dash.test(.router) { client in
                try await client.execute(uri: "/dash/models/test", method: .post, headers: ModelFixtures.write, body: TestServer.body("{}")) { response in
                    let report = try ModelFixtures.json(response)
                    #expect((report["decision"] as? [String: Any])?.keys.sorted() == ["chat", "environment"])
                }
            }
            #expect(chat.server.authorizations("/v1/systemone") == ["Bearer chat-secret"])
            #expect(clef.server.authorizations("/v1/systemone") == ["Bearer decision-secret"])

            // DECISION_BASE_URL is the chat model's own: 0.5.0's pairing, DECISION_API_KEY there.
            var shared = config
            shared.decisionBaseURL = shared.modelBaseURL
            let (sharedDash, sharedService) = try await ModelFixtures.dashboard(shared)
            try await sharedDash.test(.router) { client in
                try await client.execute(uri: "/dash/models/test", method: .post, headers: ModelFixtures.write, body: TestServer.body(#"{"decision":["chat"]}"#)) {
                    #expect($0.status == .ok)
                }
            }
            #expect(chat.server.authorizations("/v1/systemone").last == "Bearer decision-secret")
            // A chat model typed on the dashboard, even at the same address, gets its own key (none here), never that one.
            let (typed, _) = try await sharedService.settings.saveModel(ModelFixtures.chat("smart", at: chat.url.absoluteString), policy: .off)
            try await sharedService.settings.use(chat: typed, decision: "chat")
            #expect(await sharedService.settings.decisionAPIKey == nil)
        }
    }

    @Test("The list never carries a key, opened or sealed; a key sealed with another BUDGET_TOKEN_KEY reads as unreadable")
    func listKeepsKeysOut() async throws {
        let store = MemoryStore()
        let foreign = try ModelFixtures.otherSealer.seal("sk-foreign")
        let ours = try ModelFixtures.sealer.seal("sk-ours")
        try await store.saveModelSettings(StoredModelSettings(models: [
            SavedModel(id: "old", kind: .chat, name: "Old", address: "https://old.example", sealedKey: foreign, model: "m"),
            SavedModel(id: "new", kind: .chat, name: "New", address: "https://new.example", sealedKey: ours, model: "m"),
        ], inUse: ["chat": "new"]))
        let (dash, _) = try await ModelFixtures.dashboard(store: store)
        try await dash.test(.router) { client in
            try await client.execute(uri: "/dash/models", method: .get) { response in
                let text = String(buffer: response.body)
                for secret in ["sk-foreign", "sk-ours", foreign, ours] { #expect(!text.contains(secret)) }
                let chat = try #require(try ModelFixtures.json(response)["chat"] as? [[String: Any]])
                #expect(chat.first { $0["id"] as? String == "old" }.map { $0["hasKey"] as? Bool == false && $0["keyUnreadable"] as? Bool == true } == true)
                #expect(chat.first { $0["id"] as? String == "new" }.map { $0["hasKey"] as? Bool == true && $0["keyUnreadable"] as? Bool == false } == true)
                #expect(text.contains(#""sealingAvailable":true"#) && text.contains(#""limit":20"#))
            }
        }
    }

    @Test("A model whose address came from the Olares app, which no longer sets one: listed without an address, off for its job, still editable")
    func inheritedAddressGone() async throws {
        let store = MemoryStore()
        try await store.saveModelSettings(StoredModelSettings(models: [
            SavedModel(id: "migrated-chat", kind: .chat, name: "smart", sealedKey: try ModelFixtures.sealer.seal("sk-s"), model: "smart", inherit: ["address"]),
        ], inUse: ["chat": "migrated-chat"]))
        let settings = ModelFixtures.settings(store: store)
        try await settings.load()
        let entry = try #require(await settings.modelList().chat.first)
        #expect(entry.address == nil && entry.hasKey && entry.inherits == ["address"])
        #expect(await settings.modelBaseURL == nil) // Ask is off until an address comes back or another model is picked
        _ = try await settings.saveModel(ModelDraft(id: "migrated-chat", kind: "chat", name: "Renamed"), policy: .off)
        #expect(await settings.modelList().chat.first?.name == "Renamed")
        // Giving it an address of its own is moving its key: type one, or remove it.
        await #expect(throws: BudgetAPIError.rejected("The address is on another server now: type its API key, or remove the key.")) {
            try await settings.saveModel(ModelDraft(id: "migrated-chat", kind: "chat", address: "https://new.example"), policy: .off)
        }
    }

    // MARK: Loading and writing safely

    @Test("Before settings load (or when they fail to), every write is refused and the stored rows stay as they were")
    func writesWaitForLoad() async throws {
        let store = MemoryStore()
        try await store.saveServerSettings(StoredServerSettings(values: ["syncIntervalHours": "2.0", "modelName": "smart"]))
        let before = (try await store.setting("server"), try await store.setting("models"))
        let settings = ModelFixtures.settings(store: store)
        // Not loaded yet: the server is still starting, so try again, not restart.
        await #expect(throws: BudgetAPIError.server(status: 503, message: "The server is still starting. Try again in a moment.")) {
            try await settings.saveModel(ModelFixtures.chat("x", at: "https://x.example"), policy: .off)
        }
        await #expect(throws: BudgetAPIError.self) { try await settings.update(["syncIntervalHours": "3"]) }
        await #expect(throws: BudgetAPIError.self) { try await settings.use(chat: "off", decision: nil) }
        await #expect(throws: BudgetAPIError.self) { try await settings.removeModel(id: "x", policy: .off) }
        #expect(try await store.setting("server") == before.0)
        #expect(try await store.setting("models") == before.1)

        // A row that doesn't decode: load fails, and writes stay refused, now as a failure the log explains.
        let broken = MemoryStore()
        try await broken.saveSetting("server", Data("not json".utf8))
        let brokenSettings = ModelFixtures.settings(store: broken)
        await #expect(throws: (any Error).self) { try await brokenSettings.load() }
        await #expect(throws: BudgetAPIError.server(status: 503, message: "Server settings didn't load, so nothing was changed. Restart the server; its log says why.")) {
            try await brokenSettings.update(["syncIntervalHours": "3"])
        }
        #expect(try await broken.setting("server") == Data("not json".utf8))
        #expect(try await broken.setting("models") == nil)

        // Over HTTP, on a server whose settings haven't loaded yet: 503, still starting.
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: MemoryStore(), logger: Logger(label: "test"))
        let dash = Application(router: buildRouter(service, surface: .dashboard))
        try await dash.test(.router) { client in
            try await client.execute(uri: "/dash/settings", method: .patch, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"changes":{"syncIntervalHours":"3"}}"#)) { response in
                #expect(response.status == .serviceUnavailable)
                let refusal = try ModelFixtures.json(response)
                #expect(refusal["error"] as? String == "The server is still starting. Try again in a moment.")
            }
            try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"kind":"chat","address":"https://x.example","model":"x"}"#)) { #expect($0.status == .serviceUnavailable) }
        }
    }

    @Test("A models row that doesn't decode leaves the server row's settings in force; writes stay refused")
    func badModelsRowKeepsServerRow() async throws {
        let store = MemoryStore()
        try await store.saveServerSettings(StoredServerSettings(values: ["timeZone": "America/New_York", "syncIntervalHours": "2.0", "publicURL": "https://budget.example"]))
        try await store.saveSetting("models", Data(#"{"models":[{"id":"x","kind":"chat"}]}"#.utf8))  // an entry without a name
        let settings = ModelFixtures.settings(store: store)
        await #expect(throws: DecodingError.self) { try await settings.load() }
        #expect(await settings.timeZone.identifier == "America/New_York")
        #expect(await settings.syncIntervalHours == 2)
        #expect(await settings.publicURL == "https://budget.example")
        await #expect(throws: BudgetAPIError.server(status: 503, message: "Server settings didn't load, so nothing was changed. Restart the server; its log says why.")) {
            try await settings.update(["syncIntervalHours": "3"])
        }
        #expect(try await store.setting("models") == Data(#"{"models":[{"id":"x","kind":"chat"}]}"#.utf8))

        // Until a restart, the models the server row mirrors run (here a typed cloud model), not the Olares app's.
        let mirrored = MemoryStore()
        try await mirrored.saveServerSettings(StoredServerSettings(values: [
            "modelBaseURL": "https://cloud.example/v1", "modelAPIKey": try ModelFixtures.sealer.seal("sk-cloud"), "modelName": "m"]))
        try await mirrored.saveSetting("models", Data(#"{"models":[{"id":"x","kind":"chat"}]}"#.utf8))
        let mirroredSettings = ModelFixtures.settings(store: mirrored)
        await #expect(throws: DecodingError.self) { try await mirroredSettings.load() }
        let running = await mirroredSettings.modelSnapshot()
        #expect(running.chatURL?.absoluteString == "https://cloud.example")
        #expect(running.chatKey == "sk-cloud")
        #expect(running.chatName == "m")
        #expect(try await mirrored.setting("models") == Data(#"{"models":[{"id":"x","kind":"chat"}]}"#.utf8))  // nothing written

        // The other way round: a server row that doesn't decode leaves the saved picks in force.
        let other = MemoryStore()
        try await other.saveSetting("server", Data("not json".utf8))
        try await other.saveModelSettings(StoredModelSettings(models: [ModelFixtures.savedChat("qwen", at: "http://qwen.local")], inUse: ["chat": "c"]))
        let otherSettings = ModelFixtures.settings(store: other)
        await #expect(throws: DecodingError.self) { try await otherSettings.load() }
        #expect(await otherSettings.modelBaseURL?.absoluteString == "http://qwen.local")
        #expect(await otherSettings.modelName == "qwen")
    }

    @Test("A model of a kind a later server added loads, is ignored, and is written back with the fields this server knows")
    func unknownKindIsWrittenBack() async throws {
        let store = MemoryStore()
        let eyes: [String: Any] = ["id": "eyes", "kind": "vision", "name": "Eyes", "address": "https://vision.example", "model": "v1", "inherit": ["key"]]
        try await store.saveSetting("models", JSONSerialization.data(withJSONObject: ["models": [eyes], "inUse": ["vision": "eyes"], "mirrored": [String: String]()]))
        let settings = ModelFixtures.settings(store: store)
        try await settings.load()
        let list = await settings.modelList()
        #expect(list.chat.isEmpty && list.decision.isEmpty)
        await #expect(throws: BudgetAPIError.rejected("No such model.")) { try await settings.removeModel(id: "eyes", policy: .off) }
        _ = try await settings.saveModel(ModelFixtures.chat("smart", at: "https://s.example"), policy: .off)
        let document = try await ModelFixtures.modelsDocument(store)
        let models = try #require(document["models"] as? [[String: Any]])
        #expect(models.count == 2)
        #expect(NSDictionary(dictionary: models[0]).isEqual(to: eyes))
        #expect((document["inUse"] as? [String: String])?["vision"] == "eyes")
    }

    @Test("Twenty saves at once, or arriving one after another among other writes, all land")
    func concurrentWrites() async throws {
        let store = YieldingStore()
        let settings = ModelFixtures.settings(store: store)
        try await settings.load()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<20 {
                group.addTask { _ = try await settings.saveModel(ModelFixtures.chat("m\(n)", at: "https://s\(n).example"), policy: .off) }
            }
            try await group.waitForAll()
        }
        #expect(try await store.modelSettings()?.models.count == 20)
        #expect(await settings.modelList().chat.count == 20)
        await #expect(throws: BudgetAPIError.rejected("That's the most this server keeps for one job.")) {
            try await settings.saveModel(ModelFixtures.chat("one-more", at: "https://more.example"), policy: .off)
        }

        let staggered = YieldingStore()
        let other = ModelFixtures.settings(store: staggered)
        try await other.load()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<20 {
                group.addTask {
                    try await Task.sleep(for: .microseconds(150 * n))
                    _ = try await other.saveModel(ModelDraft(kind: "decision", address: "http://clef\(n).local"), policy: .off)
                }
                if n % 4 == 0 {
                    group.addTask {
                        try await Task.sleep(for: .microseconds(150 * n + 75))
                        try await other.update(["syncIntervalHours": "\(n + 1)"])
                    }
                }
            }
            try await group.waitForAll()
        }
        let saved = try #require(try await staggered.modelSettings())
        #expect(saved.models.count == 20 && Set(saved.models.map(\.id)).count == 20)
        #expect(try await staggered.serverSettings()?.values["syncIntervalHours"] != nil)
    }

    @Test("Newcomers arriving while the lock passes from one writer to the next wait their turn")
    func handOff() async throws {
        for round in 0..<10 {
            let store = YieldingStore()
            let settings = ModelFixtures.settings(store: store)
            try await settings.load()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for n in 0..<40 {
                    group.addTask {
                        for _ in 0..<((n * 7 + round) % 13) { await Task.yield() }
                        _ = try await settings.saveModel(ModelDraft(kind: n % 2 == 0 ? "chat" : "decision", address: "http://s\(n).local", model: "m"), policy: .off)
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await store.modelSettings()?.models.count == 40, "round \(round)")
        }
    }

    @Test("An older model snapshot never replaces a newer one")
    func newestSnapshotWins() async throws {
        let (_, service) = try await ModelFixtures.dashboard()
        func snapshot(_ name: String, _ generation: Int) -> ModelSnapshot {
            ModelSnapshot(chatURL: URL(string: "https://x.example"), chatKey: nil, chatName: name, decisionURL: nil, decisionKey: nil,
                          openRouterKey: nil, zeroRetention: false, generation: generation)
        }
        await service.modelApplier.apply(snapshot("newer", 1_000), to: service.api)
        await service.modelApplier.apply(snapshot("older", 999), to: service.api)
        #expect(try await service.api.serverStatus().roles.first { $0.role == .chat }?.model == "newer")
    }

    // MARK: Test and checks

    @Test("Test: a draft nothing answers says so; with nothing set up there's nothing to test; addresses are checked one way")
    func testRoute() async throws {
        let (dash, _) = try await ModelFixtures.dashboard()
        try await dash.test(.router) { client in
            try await client.execute(uri: "/dash/models/test", method: .post, headers: ModelFixtures.write, body: TestServer.body("{}")) { response in
                let report = try ModelFixtures.json(response)
                #expect((report["chat"] as? [String: Any])?.isEmpty == true && (report["decision"] as? [String: Any])?.isEmpty == true)
                #expect(report["jev"] == nil && report["draft"] == nil)
            }
            try await client.execute(uri: "/dash/models/test", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"draft":{"kind":"decision","address":"http://127.0.0.1:9"}}"#)) { response in
                let draft = try #require(try ModelFixtures.json(response)["draft"] as? [String: Any])
                #expect(draft["ok"] as? Bool == false && (draft["detail"] as? String)?.contains("Can't reach") == true)
            }
            try await client.execute(uri: "/dash/models/test", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"draft":{"kind":"chat","address":"https://user:pw@x.example","model":"m"}}"#)) { response in
                let draft = try #require(try ModelFixtures.json(response)["draft"] as? [String: Any])
                #expect(draft["detail"] as? String == "Put the key in API key, not in the address.")
            }
            try await client.execute(uri: "/dash/models/test", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"draft":{"kind":"jev"}}"#)) { response in
                let draft = try ModelFixtures.json(response)["draft"] as? [String: Any]
                #expect(draft?["detail"] as? String == "Jev needs an OpenRouter key.")
            }
            try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"kind":"chat","address":"ftp://x.example","model":"m"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                let refusal = try ModelFixtures.json(response)
                #expect(refusal["error"] as? String == "The address must start with http:// or https://.")
            }
            try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"kind":"chat","address":"https://x.example/v1?key=abc","model":"m"}"#)) { response in
                #expect(String(buffer: response.body).contains("Put the key in API key, not in the address."))
            }
            try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"kind":"chat","address":"https://x.example"}"#)) { response in
                #expect(String(buffer: response.body).contains("Add the model's name"))
            }
            try await client.execute(uri: "/dash/models/save", method: .post, headers: ModelFixtures.write,
                                     body: TestServer.body(#"{"kind":"chat","address":"http://127.0.0.1:99999","model":"m"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                let refusal = try ModelFixtures.json(response)
                #expect(refusal["error"] as? String == "That port isn't a valid one: use a number from 1 to 65535.")
            }
            // Past the 64 KB these routes take: 413, in words.
            let huge = String(repeating: "x", count: 70_000)
            for (uri, json) in [("/dash/models/test", #"{"chat":["\#(huge)"]}"#), ("/dash/models/save", #"{"kind":"chat","apiKey":"\#(huge)"}"#)] {
                try await client.execute(uri: uri, method: .post, headers: ModelFixtures.write, body: TestServer.body(json)) { response in
                    #expect(response.status == .contentTooLarge, "\(uri)")
                    let refusal = try ModelFixtures.json(response)
                    #expect(refusal["error"] as? String == "That's too much to send at once.")
                }
            }
        }

        // With the Olares app's chat server set, {} tests it and categorizing on it.
        var config = TestServer.config()
        config.modelBaseURL = URL(string: "http://127.0.0.1:9/v1")
        let (envDash, _) = try await ModelFixtures.dashboard(config)
        try await envDash.test(.router) { client in
            try await client.execute(uri: "/dash/models/test", method: .post, headers: ModelFixtures.write, body: TestServer.body("{}")) { response in
                let report = try ModelFixtures.json(response)
                #expect((report["chat"] as? [String: Any])?.keys.sorted() == ["environment"])
                #expect((report["decision"] as? [String: Any])?.keys.sorted() == ["chat"])
                let chat = (report["chat"] as? [String: Any])?["environment"] as? [String: Any]
                #expect((chat?["detail"] as? String)?.contains("Can't reach") == true)
            }
        }
    }

    @Test("Which servers count as on this network")
    func localHosts() throws {
        let local = ["http://127.0.0.1:8000", "http://localhost", "http://qwen.localhost", "http://qwen.local", "http://clef", "http://10.1.2.3",
                     "http://172.20.0.1", "http://192.168.1.9", "http://100.101.7.20", "http://169.254.1.1", "http://[::1]:8080", "http://[fd12::1]",
                     "http://[fe80::1]", "https://switchboard.someone.olares.com", "http://x.internal", "http://nas.lan", "http://box.home.arpa",
                     "http://[::ffff:192.168.0.1]"]
        let cloud = ["https://openrouter.ai/api/v1", "https://api.openai.com", "http://8.8.8.8", "http://172.32.0.1", "http://100.128.0.1",
                     "http://[2001:db8::1]", "https://example.local.evil.com"]
        for text in local { #expect(ModelCheck.isLocal(URL(string: text)!), "\(text)") }
        for text in cloud { #expect(!ModelCheck.isLocal(URL(string: text)!), "\(text)") }
        #expect(throws: BudgetAPIError.rejected("The address must start with http:// or https://.")) { try ModelCheck.address("qwen.local") }
        for text in ["http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:99999", "http://[::1]:70000", "http://127.0.0.1:99999999999999999999/v1"] {
            #expect(throws: BudgetAPIError.rejected("That port isn't a valid one: use a number from 1 to 65535."), "\(text)") { try ModelCheck.address(text) }
        }
        #expect(try ModelCheck.address("http://127.0.0.1:65535/v1").absoluteString == "http://127.0.0.1:65535")
        #expect(try ModelCheck.address("http://qwen.local:1").port == 1)
        #expect(try ModelCheck.address(" https://Switchboard.example/v1/ ").absoluteString == "https://Switchboard.example")
        #expect(ModelCheck.sameServer(URL(string: "https://a.example"), URL(string: "https://A.example:443/v1")))
        #expect(!ModelCheck.sameServer(URL(string: "https://a.example"), URL(string: "http://a.example")))
        #expect(!ModelCheck.sameServer(URL(string: "https://a.example"), URL(string: "https://a.example:8443")))
    }
}
