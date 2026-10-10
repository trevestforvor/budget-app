import BudgetKit
@testable import BudgetServerCore
import Foundation
import Logging
import Testing

/// 0.5.0's model settings, ported line for line from its `ServerSettings`
/// (`git show 2c7fa72:Server/Sources/BudgetServerCore/Settings.swift`): `value()` and `origin()` over the five flat keys
/// of the "server" row, and the five accessors it built the models from.
struct Server050Models {
    struct Definition: Sendable {
        var key: String
        var secret: Bool
        var environmentVariable: String
        var configValue: @Sendable (ServerConfig) -> String?
        var builtInDefault: String?
    }

    static let definitions: [Definition] = [
        .init(key: "modelBaseURL", secret: false, environmentVariable: "MODEL_BASE_URL", configValue: { $0.modelBaseURL?.absoluteString }, builtInDefault: nil),
        .init(key: "modelAPIKey", secret: true, environmentVariable: "MODEL_API_KEY", configValue: { $0.modelAPIKey }, builtInDefault: nil),
        .init(key: "modelName", secret: false, environmentVariable: "MODEL_NAME", configValue: { $0.modelName }, builtInDefault: "qwen3.8-27b"),
        .init(key: "decisionBaseURL", secret: false, environmentVariable: "DECISION_BASE_URL",
              configValue: { $0.decisionBaseURL == $0.modelBaseURL ? nil : $0.decisionBaseURL?.absoluteString }, builtInDefault: nil),
        .init(key: "decisionAPIKey", secret: true, environmentVariable: "DECISION_API_KEY", configValue: { $0.decisionAPIKey }, builtInDefault: nil),
    ]

    var config: ServerConfig
    var sealer: TokenSealer?
    /// The "server" row's values.
    var values: [String: String]

    func value(_ key: String) -> String? {
        guard let definition = Self.definitions.first(where: { $0.key == key }) else { return nil }
        if let stored = values[key] {
            if stored.isEmpty { return nil }  // explicitly off
            if definition.secret { return sealer.flatMap { try? $0.open(stored) } }
            return stored
        }
        return origin(definition) == .environment ? definition.configValue(config) : definition.builtInDefault
    }

    private func origin(_ definition: Definition) -> SettingField.Origin {
        if values[definition.key] != nil { return .dashboard }
        if config.environmentKeys.contains(definition.environmentVariable) { return .environment }
        let value = definition.configValue(config)
        return value != nil && value != definition.builtInDefault ? .environment : .default
    }

    var modelBaseURL: URL? { value("modelBaseURL").flatMap(URL.init(string:)).map(ModelCheck.base) }
    var modelAPIKey: String? { value("modelAPIKey") }
    var decisionBaseURL: URL? { value("decisionBaseURL").flatMap(URL.init(string:)).map(ModelCheck.base) ?? modelBaseURL }
    var decisionAPIKey: String? { value("decisionAPIKey") ?? (value("decisionBaseURL") == nil ? modelAPIKey : nil) }
    var modelName: String { value("modelName") ?? "qwen3.8-27b" }
}

/// What a server sends where. A key or model name counts only when there's an address to send it to.
struct ModelsSent: Equatable, CustomStringConvertible {
    var chatURL: String?
    var chatKey: String?
    var chatName: String?
    var decisionURL: String?
    var decisionKey: String?

    init(chatURL: URL?, chatKey: String?, chatName: String, decisionURL: URL?, decisionKey: String?) {
        self.chatURL = chatURL?.absoluteString
        self.chatKey = chatURL == nil ? nil : chatKey
        self.chatName = chatURL == nil ? nil : chatName
        self.decisionURL = decisionURL?.absoluteString
        self.decisionKey = decisionURL == nil ? nil : decisionKey
    }

    init(_ old: Server050Models) {
        self.init(chatURL: old.modelBaseURL, chatKey: old.modelAPIKey, chatName: old.modelName, decisionURL: old.decisionBaseURL, decisionKey: old.decisionAPIKey)
    }

    init(_ snapshot: ModelSnapshot) {
        self.init(chatURL: snapshot.chatURL, chatKey: snapshot.chatKey, chatName: snapshot.chatName, decisionURL: snapshot.decisionURL, decisionKey: snapshot.decisionKey)
    }

    var description: String {
        "chat \(chatURL ?? "off") key \(chatKey ?? "none") model \(chatName ?? "-"); categorizing \(decisionURL ?? "none") key \(decisionKey ?? "none")"
    }
}

/// Where 0.5.1 deliberately doesn't send what 0.5.0 sent from the same row. Each is about categorizing's key on the chat
/// model's server; everything else runs exactly as it did.
enum Divergence: String, CaseIterable {
    /// A non-empty decisionAPIKey beside decisionBaseURL "", or with no categorizing server of its own, isn't kept.
    case leftoverDecisionKeyDropped
    /// DECISION_BASE_URL is a server of its own, so DECISION_API_KEY isn't sent to the chat model's server.
    case decisionKeyStaysWithItsOwnServer
    /// The chat model's address was typed on the dashboard, so DECISION_API_KEY isn't sent there.
    case decisionKeyNotToTypedChatServer
}

enum Migration {
    static let sealer = ModelFixtures.sealer
    static let chatEnvironment = "http://olares-chat.local:8000/v1"
    static let decisionEnvironment = "http://clef-env.local:9000"

    /// Every way the Olares app can set the five variables: each unset or set, and DECISION_BASE_URL also the chat
    /// model's own address. Parsed as the server parses its environment.
    static func environments() throws -> [(label: String, config: ServerConfig)] {
        var out: [(label: String, config: ServerConfig)] = []
        for chatURL in [nil, chatEnvironment] as [String?] {
            for chatKey in [nil, "mk-env"] as [String?] {
                for name in [nil, "env-model"] as [String?] {
                    for decisionURL in ["unset", "same", "own"] where !(decisionURL == "same" && chatURL == nil) {
                        for decisionKey in [nil, "dk-env"] as [String?] {
                            var env: [String: String] = [:]
                            env["MODEL_BASE_URL"] = chatURL
                            env["MODEL_API_KEY"] = chatKey
                            env["MODEL_NAME"] = name
                            env["DECISION_BASE_URL"] = decisionURL == "same" ? chatURL : decisionURL == "own" ? decisionEnvironment : nil
                            env["DECISION_API_KEY"] = decisionKey
                            let label = "MODEL_BASE_URL \(chatURL == nil ? "unset" : "set"), MODEL_API_KEY \(chatKey == nil ? "unset" : "set"), "
                                + "MODEL_NAME \(name == nil ? "unset" : "set"), DECISION_BASE_URL \(decisionURL), DECISION_API_KEY \(decisionKey == nil ? "unset" : "set")"
                            out.append((label, try ServerConfig.fromEnvironment(env)))
                        }
                    }
                }
            }
        }
        return out
    }

    static func settings(_ config: ServerConfig, store: any ServerStore) -> ServerSettings {
        var logger = Logger(label: "test")
        logger.logLevel = .error  // the import's notices, thousands of times over
        return ServerSettings(config: config, store: store, sealer: sealer, logger: logger)
    }

    static func ownDecisionServer(_ config: ServerConfig) -> Bool {
        config.decisionBaseURL != nil && config.decisionBaseURL != config.modelBaseURL
    }

    /// The divergence a 0.5.0 row meets on upgrade, if any, with the categorizing key 0.5.1 sends instead.
    static func divergence(row v: [String: String], config: ServerConfig, before: Server050Models) -> (Divergence, key: String?)? {
        let own = ownDecisionServer(config)
        // 0.5.0 categorized on the chat model's server: no decision address of its own on the dashboard or in the app.
        guard v["decisionBaseURL"] == "" || (v["decisionBaseURL"] == nil && !own), before.decisionBaseURL != nil else { return nil }
        let typedChat = v["modelBaseURL"] != nil  // "" is off, and then there's no server to categorize on
        if let leftover = v["decisionAPIKey"], !leftover.isEmpty {
            // Dropped: the chat model's server gets what it gets by default.
            let sendsDecisionKey = !own && config.decisionAPIKey != nil && !typedChat
            return (.leftoverDecisionKeyDropped, sendsDecisionKey ? config.decisionAPIKey : before.modelAPIKey)
        }
        guard v["decisionAPIKey"] == nil, config.decisionAPIKey != nil else { return nil }
        if own { return (.decisionKeyStaysWithItsOwnServer, before.modelAPIKey) }
        if typedChat { return (.decisionKeyNotToTypedChatServer, before.modelAPIKey) }
        return nil
    }

    /// The models a server in this environment can hold: imported from 0.5.0 rows (each with what it inherits there) and
    /// added on the dashboard, with and without a key.
    static func savedModels(_ config: ServerConfig) async throws -> [SavedModel] {
        let store = MemoryStore()
        let settings = settings(config, store: store)
        let rows: [[String: String]] = [
            ["modelName": "dash-model"],
            ["modelAPIKey": try sealer.seal("sk-dash")],
            ["modelBaseURL": "https://dash-chat.example/v1", "modelName": "dash-model"],
            ["decisionAPIKey": try sealer.seal("dk-dash")],
            ["decisionBaseURL": "http://dash-clef.local:9100"],
        ]
        for row in rows {
            try await store.saveServerSettings(StoredServerSettings(values: row))
            try await settings.load()  // 0.5.0 edited the five keys: imported again
        }
        for draft in [ModelDraft(kind: "chat", address: "https://typed-chat.example/v1", apiKey: "sk-typed", model: "typed-model"),
                      ModelDraft(kind: "chat", address: "http://typed-local.lan:8000", model: "local-model"),
                      ModelDraft(kind: "decision", address: "http://typed-clef.lan:9200", apiKey: "dk-typed"),
                      ModelDraft(kind: "decision", address: "http://typed-clef2.lan")] {
            _ = try await settings.saveModel(draft, policy: .off)
        }
        return try #require(try await store.modelSettings()).models
    }

    static func show(_ values: [String: String]) -> String {
        ServerSettings.flatModelValues(values).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.isEmpty ? "\"\"" : $0.value.count > 40 ? "<sealed>" : $0.value)" }.joined(separator: " ")
    }
}

@Suite("0.5.0 and 0.5.1 run the same models: on upgrade, and after a rollback")
struct ModelMigrationTests {
    @Test("Upgrading: every 0.5.0 row runs what 0.5.0 ran, but for three named changes; the row mirrored back runs it on 0.5.0")
    func upgradeRunsWhat050Ran() async throws {
        let chatKey = try Migration.sealer.seal("sk-dash"), decisionKey = try Migration.sealer.seal("dk-dash")
        var failures: [String] = []
        var seen: [Divergence: Int] = [:]
        var cases = 0
        for (label, config) in try Migration.environments() {
            for mb in [nil, "", "https://dash-chat.example/v1"] as [String?] {
                for mk in [nil, "", chatKey] as [String?] {
                    for mn in [nil, "dash-model"] as [String?] {
                        for db in [nil, "", "http://dash-clef.local:9100/v1/decision"] as [String?] {
                            for dk in [nil, "", decisionKey] as [String?] {
                                cases += 1
                                var row: [String: String] = [:]
                                row["modelBaseURL"] = mb
                                row["modelAPIKey"] = mk
                                row["modelName"] = mn
                                row["decisionBaseURL"] = db
                                row["decisionAPIKey"] = dk
                                let store = MemoryStore()
                                try await store.saveServerSettings(StoredServerSettings(values: row))
                                let settings = Migration.settings(config, store: store)
                                try await settings.load()

                                let before = Server050Models(config: config, sealer: Migration.sealer, values: row)
                                var expected = ModelsSent(before)
                                if let (divergence, key) = Migration.divergence(row: row, config: config, before: before) {
                                    seen[divergence, default: 0] += 1
                                    expected.decisionKey = key
                                }
                                let now = ModelsSent(await settings.modelSnapshot())
                                if now != expected {
                                    failures.append("\(label) | \(Migration.show(row)) | 0.5.0 \(ModelsSent(before)) | expected \(expected) | 0.5.1 \(now)")
                                }

                                // One models write mirrors the row back; a rollback then runs what 0.5.1 runs, no exceptions.
                                try await settings.use(chat: nil, decision: nil)
                                let mirrored = try await store.serverSettings()?.values ?? [:]
                                let rolledBack = ModelsSent(Server050Models(config: config, sealer: Migration.sealer, values: mirrored))
                                if rolledBack != now {
                                    failures.append("ROLLBACK \(label) | \(Migration.show(row)) → \(Migration.show(mirrored)) | 0.5.1 \(now) | 0.5.0 \(rolledBack)")
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(cases == 40 * 162)
        #expect(failures.isEmpty, "\(failures.count) of \(cases) differ, e.g.:\n\(failures.prefix(10).joined(separator: "\n"))")
        // Each named change happens, and nothing else is let through as one.
        #expect(Set(seen.keys) == Set(Divergence.allCases), "\(seen)")
    }

    @Test("Rolling back: whatever is picked and saved, the row mirrored for 0.5.0 runs the same models there")
    func mirrorRunsWhat051Runs() async throws {
        var failures: [String] = []
        var cases = 0
        for (label, config) in try Migration.environments() {
            let models = try await Migration.savedModels(config)
            let chatIDs = models.filter { $0.kind == .chat }.map(\.id), decisionIDs = models.filter { $0.kind == .decision }.map(\.id)
            #expect(chatIDs.count >= 2 && decisionIDs.count >= 2, "\(label)")
            for chat in [nil, "environment", "off", "gone"] + chatIDs as [String?] {
                for decision in [nil, "environment", "chat", "gone"] + decisionIDs as [String?] {
                    for chatServerKey in [nil, "chat"] as [String?] {
                        cases += 1
                        // What use() can't pick (nothing yet, a removed model, the Olares app's entry when it sets none)
                        // is stored as a server would find it; use() then picks the rest and writes the mirror.
                        let store = MemoryStore()
                        var inUse: [String: String] = [:]
                        inUse["chat"] = chat
                        inUse["decision"] = decision
                        try await store.saveModelSettings(StoredModelSettings(models: models, inUse: inUse, chatServerKey: chatServerKey))
                        let settings = Migration.settings(config, store: store)
                        try await settings.load()
                        let chatPickable = chat.map { $0 == "off" || ($0 == "environment" ? config.modelBaseURL != nil : chatIDs.contains($0)) } ?? false
                        let decisionPickable = decision.map { $0 == "chat" || ($0 == "environment" ? Migration.ownDecisionServer(config) : decisionIDs.contains($0)) } ?? false
                        try await settings.use(chat: chatPickable ? chat : nil, decision: decisionPickable ? decision : nil)

                        let now = ModelsSent(await settings.modelSnapshot())
                        let mirrored = try await store.serverSettings()?.values ?? [:]  // no row: nothing to mirror
                        let rolledBack = ModelsSent(Server050Models(config: config, sealer: Migration.sealer, values: mirrored))
                        if rolledBack != now {
                            failures.append("\(label) | chat \(chat ?? "nil") decision \(decision ?? "nil") chatServerKey \(chatServerKey ?? "nil") | mirror \(Migration.show(mirrored)) | 0.5.1 \(now) | 0.5.0 \(rolledBack)")
                        }
                    }
                }
            }
        }
        #expect(cases > 40 * 100)
        #expect(failures.isEmpty, "\(failures.count) of \(cases) differ, e.g.:\n\(failures.prefix(10).joined(separator: "\n"))")
    }

    @Test("The Olares app's settings change between restarts: the load mirrors again, so a rollback still runs what 0.5.1 runs")
    func mirrorFollowsTheEnvironment() async throws {
        let environments = try Migration.environments()
        var failures: [String] = []
        var cases = 0, addressGone = 0
        for (labelA, configA) in environments {
            let models = try await Migration.savedModels(configA)
            let chats = ["off"] + (configA.modelBaseURL == nil ? [] : ["environment"]) + models.filter { $0.kind == .chat }.map(\.id)
            let decisions = ["chat"] + (Migration.ownDecisionServer(configA) ? ["environment"] : []) + models.filter { $0.kind == .decision }.map(\.id)
            for chat in chats {
                for decision in decisions {
                    // Picked and mirrored under one environment...
                    let first = MemoryStore()
                    try await first.saveModelSettings(StoredModelSettings(models: models))
                    let a = Migration.settings(configA, store: first)
                    try await a.load()
                    try await a.use(chat: chat, decision: decision)
                    let server = try await first.serverSettings() ?? StoredServerSettings()
                    let stored = try #require(try await first.modelSettings())
                    // ...then restarted under each environment, with no models write.
                    for (labelB, configB) in environments {
                        cases += 1
                        let store = MemoryStore()
                        try await store.saveServerSettings(server)
                        try await store.saveModelSettings(stored)
                        let b = Migration.settings(configB, store: store)
                        try await b.load()
                        let now = ModelsSent(await b.modelSnapshot())
                        let mirrored = try await store.serverSettings()?.values ?? [:]
                        var rolledBack = ModelsSent(Server050Models(config: configB, sealer: Migration.sealer, values: mirrored))
                        // A categorizing server whose address came from the Olares app, which no longer sets one: nothing
                        // categorizes on 0.5.1, and 0.5.0 can't say so. It falls back to the chat model's server, sending
                        // that server's own key and never the entry's.
                        if now.decisionURL == nil, rolledBack.decisionURL != nil, rolledBack.decisionKey == rolledBack.chatKey,
                           !Migration.ownDecisionServer(configB), models.first(where: { $0.id == decision })?.inherit?.contains("address") == true {
                            addressGone += 1
                            rolledBack.decisionURL = nil
                            rolledBack.decisionKey = nil
                        }
                        if rolledBack != now {
                            failures.append("\(labelA) → \(labelB) | chat \(chat) decision \(decision) | mirror \(Migration.show(mirrored)) | 0.5.1 \(now) | 0.5.0 \(rolledBack)")
                        }
                    }
                }
            }
        }
        #expect(cases > 40 * 40 * 10)
        #expect(addressGone > 0)
        #expect(failures.isEmpty, "\(failures.count) of \(cases) differ, e.g.:\n\(failures.prefix(10).joined(separator: "\n"))")
    }

    @Test("Upgraded, rolled back, edited on 0.5.0, upgraded again: what 0.5.0 ran from the edited row runs, but for the named changes")
    func reimportRunsWhat050Ran() async throws {
        let chatKey = try Migration.sealer.seal("sk-dash"), decisionKey = try Migration.sealer.seal("dk-dash")
        var failures: [String] = []
        var cases = 0
        for (label, config) in try Migration.environments() {
            let models = try await Migration.savedModels(config)
            let typedChat = try #require(models.first { $0.kind == .chat && $0.inherit == nil }).id
            let typedDecision = try #require(models.first { $0.kind == .decision && $0.inherit == nil }).id
            for (chat, decision) in [(nil, nil), ("off", "chat"), (typedChat, nil), (typedChat, typedDecision)] as [(String?, String?)] {
                for chatServerKey in [nil, "chat"] as [String?] {
                    let first = MemoryStore()
                    try await first.saveModelSettings(StoredModelSettings(models: models, chatServerKey: chatServerKey))
                    let a = Migration.settings(config, store: first)
                    try await a.load()
                    try await a.use(chat: chat, decision: decision)
                    let server = try await first.serverSettings() ?? StoredServerSettings()
                    let stored = try #require(try await first.modelSettings())
                    for mb in [nil, "", "https://dash-chat.example/v1"] as [String?] {
                        for mk in [nil, "", chatKey] as [String?] {
                            for mn in [nil, "dash-model"] as [String?] {
                                for db in [nil, "", "http://dash-clef.local:9100/v1/decision"] as [String?] {
                                    for dk in [nil, "", decisionKey] as [String?] {
                                        cases += 1
                                        // 0.5.0 rewrites its five keys and keeps the rest of the row.
                                        var values = server.values
                                        for key in ServerSettings.chatKeys + ServerSettings.decisionKeys { values[key] = nil }
                                        values["modelBaseURL"] = mb
                                        values["modelAPIKey"] = mk
                                        values["modelName"] = mn
                                        values["decisionBaseURL"] = db
                                        values["decisionAPIKey"] = dk
                                        let store = MemoryStore()
                                        try await store.saveServerSettings(StoredServerSettings(values: values))
                                        try await store.saveModelSettings(stored)
                                        let settings = Migration.settings(config, store: store)
                                        try await settings.load()

                                        let before = Server050Models(config: config, sealer: Migration.sealer, values: values)
                                        var expected = ModelsSent(before)
                                        if let (_, key) = Migration.divergence(row: values, config: config, before: before) { expected.decisionKey = key }
                                        let now = ModelsSent(await settings.modelSnapshot())
                                        if now != expected {
                                            failures.append("\(label) | from chat \(chat ?? "nil") decision \(decision ?? "nil") chatServerKey \(chatServerKey ?? "nil") | \(Migration.show(values)) | expected \(expected) | 0.5.1 \(now)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(cases == 40 * 8 * 162)
        #expect(failures.isEmpty, "\(failures.count) of \(cases) differ, e.g.:\n\(failures.prefix(10).joined(separator: "\n"))")
    }
}
