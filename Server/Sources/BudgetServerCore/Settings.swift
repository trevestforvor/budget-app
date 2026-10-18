import BudgetKit
import Foundation
import Logging

/// Server settings saved from the dashboard: overrides over the environment (the Olares app's
/// settings), which are themselves over built-in defaults. Values are strings; secrets are sealed.
///
/// The models live in their own row (`StoredModelSettings`). This row still carries the five flat model keys a 0.5.0
/// server reads (modelBaseURL, modelAPIKey, modelName, decisionBaseURL, decisionAPIKey), written as a mirror of the
/// models in use so a rolled-back server runs the same ones.
public struct StoredServerSettings: Codable, Hashable, Sendable, CustomStringConvertible {
    public var values: [String: String]
    public init(values: [String: String] = [:]) { self.values = values }
    /// Names only: some values are sealed keys.
    public var description: String { "StoredServerSettings(\(values.keys.sorted()))" }
}

/// The models saved from the dashboard and which one each job uses: the "models" row of `budget_settings`. A 0.5.0
/// server never reads or writes this row, so rolling back and saving there can't drop the list.
public struct StoredModelSettings: Codable, Hashable, Sendable, CustomStringConvertible {
    public var models: [SavedModel]
    /// Picks. "chat": saved id | "environment" | "off". "decision": saved id | "environment" | "chat".
    /// Missing key = default; an id that no longer exists also means default.
    public var inUse: [String: String]
    /// The five flat model keys exactly as last mirrored into the "server" row (absent key = absent there).
    /// On load, a difference means an older server edited them.
    public var mirrored: [String: String]
    /// The key categorizing sends on the chat model's server. Nil: the default (`sendsDecisionKeyToChatServer`).
    /// "chat": always the chat model's, never DECISION_API_KEY, as imported from a 0.5.0 that had that key turned off.
    public var chatServerKey: String?

    public init(models: [SavedModel] = [], inUse: [String: String] = [:], mirrored: [String: String] = [:], chatServerKey: String? = nil) {
        self.models = models
        self.inUse = inUse
        self.mirrored = mirrored
        self.chatServerKey = chatServerKey
    }

    enum CodingKeys: String, CodingKey { case models, inUse, mirrored, chatServerKey }

    /// Every part is optional, and an entry of a kind this server doesn't know decodes as `.other`, is ignored, and is
    /// written back with the fields this server knows: a row from a later server never fails to load here.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decodeIfPresent([SavedModel].self, forKey: .models) ?? []
        inUse = try c.decodeIfPresent([String: String].self, forKey: .inUse) ?? [:]
        mirrored = try c.decodeIfPresent([String: String].self, forKey: .mirrored) ?? [:]
        chatServerKey = try c.decodeIfPresent(String.self, forKey: .chatServerKey)
    }

    /// Never a key: `mirrored` holds sealed ones.
    public var description: String { "StoredModelSettings(\(models), inUse: \(inUse))" }
}

/// One model saved from the dashboard: a chat model (Ask, planning, the morning summary) or a categorizing server.
public struct SavedModel: Codable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Encodes as a plain string. A kind from a later server round-trips as `.other` and is ignored everywhere else.
    public enum Kind: Codable, Hashable, Sendable {
        case chat, decision, other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "chat": self = .chat
            case "decision": self = .decision
            default: self = .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .chat: "chat"
            case .decision: "decision"
            case let .other(raw): raw
            }
        }

        public init(from decoder: any Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    /// A UUID string for added models; "migrated-chat", "migrated-chat-2", … for imported ones.
    public var id: String
    public var kind: Kind
    public var name: String
    /// `ModelCheck.base(url).absoluteString`; nil only when inherited.
    public var address: String?
    /// `TokenSealer` output; nil = no key (or inherited).
    public var sealedKey: String?
    /// Chat only.
    public var model: String?
    /// Fields that follow the Olares app (environment) at run time instead of a saved value: "address", "key", "model".
    /// Set only by the import; typing a value for a field removes it from this list.
    public var inherit: [String]?

    public init(id: String, kind: Kind, name: String, address: String? = nil, sealedKey: String? = nil, model: String? = nil, inherit: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.address = address
        self.sealedKey = sealedKey
        self.model = model
        self.inherit = inherit
    }

    /// Never the key, sealed or not.
    public var description: String { "SavedModel(\(id), \(kind.rawValue), \(name))" }
    public var debugDescription: String { description }
}

/// A model to add or edit, as the dashboard's drawer sends it. `apiKey` is the plaintext key, so it never prints.
public struct ModelDraft: Decodable, Sendable, CustomStringConvertible {
    /// Nil adds a new model.
    public var id: String?
    /// "chat" or "decision".
    public var kind: String
    public var name: String?
    public var address: String?
    /// Blank keeps the saved key.
    public var apiKey: String?
    public var removeKey: Bool?
    public var model: String?
    /// A chat model on OpenRouter: save a copy of Jev's OpenRouter key as its key, instead of a typed one.
    public var useOpenRouterKey: Bool?

    public var description: String { "ModelDraft(\(id ?? "new"), \(kind))" }
}

/// Where a job's model is, with its opened key: what the routes test and list names with. Never printed with the key.
struct ModelConnection: Sendable, CustomStringConvertible {
    var address: URL?
    var key: String?
    var model: String?
    var description: String { "ModelConnection(\(address?.host() ?? "no address"), \(model ?? "no model"))" }
}

/// The models in force, read in one go so a rebuild never mixes two saves. `generation` grows with every write.
public struct ModelSnapshot: Sendable, CustomStringConvertible {
    public var chatURL: URL?
    public var chatKey: String?
    public var chatName: String
    public var decisionURL: URL?
    public var decisionKey: String?
    public var openRouterKey: String?
    public var zeroRetention: Bool
    public var generation: Int
    public var description: String { "ModelSnapshot(generation \(generation))" }
}

/// What the dashboard's Models card shows: every model per job and which one is in use. Never a key, sealed or opened.
public struct ModelList: Encodable, Sendable {
    public struct Entry: Encodable, Sendable {
        public var id: String
        /// "chat" or "decision".
        public var kind: String
        public var name: String
        /// Resolved; nil when an inherited value is gone.
        public var address: String?
        /// Chat: the resolved model name.
        public var model: String?
        /// The key resolves and opens with this server's BUDGET_TOKEN_KEY.
        public var hasKey: Bool
        /// A sealed key is saved but doesn't open (BUDGET_TOKEN_KEY changed).
        public var keyUnreadable: Bool
        /// "dashboard" or "environment".
        public var origin: String
        /// Fields that follow the Olares app: none for a plain saved entry, all of them for "environment".
        public var inherits: [String]
        /// The host is on this network (or the Olares), so what it's sent doesn't leave.
        public var local: Bool

        enum CodingKeys: String, CodingKey { case id, kind, name, address, model, hasKey, keyUnreadable, origin, inherits, local }
        /// `address` and `model` are always there, null when unknown.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(address, forKey: .address)
            try c.encode(model, forKey: .model)
            try c.encode(hasKey, forKey: .hasKey)
            try c.encode(keyUnreadable, forKey: .keyUnreadable)
            try c.encode(origin, forKey: .origin)
            try c.encode(inherits, forKey: .inherits)
            try c.encode(local, forKey: .local)
        }
    }

    /// What categorizing's "The chat model's server" points at: the chat pick's address.
    public struct ChatServer: Encodable, Sendable {
        public var address: String?
        public var local: Bool
        enum CodingKeys: String, CodingKey { case address, local }
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(address, forKey: .address)
            try c.encode(local, forKey: .local)
        }
    }

    public struct Jev: Encodable, Sendable {
        public var hasKey: Bool
        public var keyUnreadable: Bool
        public var zeroRetention: Bool
        /// "default", "environment" or "dashboard".
        public var keyOrigin: String
    }

    /// "environment" first when the Olares app sets one, then the saved ones in the order they were added.
    public var chat: [Entry]
    public var decision: [Entry]
    /// Effective: saved id | "environment" | "off".
    public var chatInUse: String
    /// Effective: saved id | "environment" | "chat".
    public var decisionInUse: String
    public var chatServer: ChatServer
    public var jev: Jev
    public var sealingAvailable: Bool
    /// The most saved models this server keeps for one job.
    public var limit: Int
}

/// One editable setting as the dashboard shows it. A secret's value is never included.
public struct SettingField: Codable, Sendable {
    /// `choice` takes one of `choices`; a dashboard that doesn't know it shows a text box.
    public enum Kind: String, Codable, Sendable { case url, text, number, secret, bool, timeZone, choice }
    public enum Origin: String, Codable, Sendable { case `default`, environment, dashboard }
    public var key: String
    public var group: String
    public var label: String
    public var kind: Kind
    public var value: String?
    public var isSet: Bool
    public var origin: Origin
    public var defaultValue: String?
    public var environmentVariable: String
    public var help: String
    /// The values a `choice` takes.
    public var choices: [String]? = nil
}

/// The effective server settings, rebuilt whenever the dashboard saves. Applying them swaps the
/// models, calendar and endpoint live (`BudgetServerApp.apply`); sync reads its interval each cycle.
///
/// Every write runs one at a time (a first-come lock), and only once `load()` has read both rows, so two saves can't
/// lose each other's change and nothing is written over rows that haven't been read.
public actor ServerSettings {
    struct Definition: Sendable {
        var key: String
        var group: String
        var label: String
        var kind: SettingField.Kind
        var environmentVariable: String
        var help: String
        /// The value from the environment (or the built-in default) as parsed into `ServerConfig`.
        var configValue: @Sendable (ServerConfig) -> String?
        var builtInDefault: String?
        /// A `choice`'s values.
        var choices: [String]? = nil
        /// A `number`'s bounds, when not the sync interval's 0.25…168.
        var range: ClosedRange<Double>? = nil
    }

    /// The two jobs a saved model can do.
    enum Job: String, Sendable {
        case chat, decision
        var kind: SavedModel.Kind { self == .chat ? .chat : .decision }
    }

    static let definitions: [Definition] = [
        .init(key: "openRouterKey", group: "Jev", label: "OpenRouter API key", kind: .secret, environmentVariable: "OPENROUTER_API_KEY",
              help: "Enables Jev as a decision provider. Only merchant names and category ids are sent. A chat model on OpenRouter can save a copy of it.",
              configValue: { $0.openRouterKey }, builtInDefault: nil),
        .init(key: "openRouterZeroRetention", group: "Jev", label: "Zero data retention only", kind: .bool, environmentVariable: "OPENROUTER_ZDR",
              help: "Ask OpenRouter to route only to providers that keep nothing: Jev's requests, and a chat model's on OpenRouter.",
              configValue: { $0.openRouterZeroRetention ? "true" : "false" }, builtInDefault: "false"),
        .init(key: "syncIntervalHours", group: "Sync", label: "Sync every (hours)", kind: .number, environmentVariable: "BUDGET_SYNC_INTERVAL_HOURS",
              help: "How often linked accounts are pulled: from 0.25 to 24. An account counts as stale after 2 days without a good pull, so a longer gap would mark accounts stale between syncs.",
              configValue: { String($0.syncIntervalHours) }, builtInDefault: "6.0", range: 0.25...Double(maxSyncIntervalHours)),
        .init(key: "cardBills", group: "Sync", label: "Card bills (Plaid Liabilities)", kind: .bool, environmentVariable: "BUDGET_PLAID_LIABILITIES",
              help: "Reads each Plaid-linked credit card's statement balance, minimum payment and due date, about once a day, for Upcoming and the morning summary. Plaid bills Liabilities per bank login once it's used, so it's off until you turn it on. A bank linked before needs one \"Grant card-bill access\" sign-in on Accounts; nothing is relinked or removed.",
              configValue: { $0.plaidLiabilities ? "true" : "false" }, builtInDefault: "false"),
        .init(key: "holdings", group: "Sync", label: "Investment holdings", kind: .choice, environmentVariable: "BUDGET_PLAID_HOLDINGS",
              help: "Positions in investment accounts, once a day per bank login with investments. auto: only for logins Plaid already bills for Investments. on: every login with investments (Plaid bills Investments per login once it's used). off: none.",
              configValue: { $0.plaidHoldings }, builtInDefault: "auto", choices: ["auto", "on", "off"]),
        .init(key: "plaidWebhooks", group: "Sync", label: "Plaid webhooks", kind: .bool, environmentVariable: "BUDGET_PLAID_WEBHOOKS",
              help: "Lets Plaid tell this server when there's news (new transactions, a bank asking for a sign-in), at the server URL for the phone. Does nothing without one.",
              configValue: { $0.plaidWebhooks ? "true" : "false" }, builtInDefault: "true"),
        .init(key: "simplefinDailyPulls", group: "Sync", label: "SimpleFIN pulls a day", kind: .number, environmentVariable: "BUDGET_SIMPLEFIN_DAILY_PULLS",
              help: "How many times a day the server asks SimpleFIN Bridge on its own, up to 12 (SimpleFIN takes about 20 requests a day, and the rest are kept for your own syncs and filling gaps). Its banks update about once a day.",
              configValue: { String(Int($0.simplefinDailyPulls)) }, builtInDefault: "4", range: 1...Double(SimpleFINBudget.maxAutomaticPerDay)),
        .init(key: "timeZone", group: "Sync", label: "Time zone", kind: .timeZone, environmentVariable: "BUDGET_TIMEZONE",
              help: "Where months begin and end (e.g. America/New_York). Without one, the server's own zone.", configValue: { $0.timeZone.identifier }, builtInDefault: TimeZone.current.identifier),
        .init(key: "publicURL", group: "Phone", label: "Server URL for the phone", kind: .url, environmentVariable: "BUDGET_PUBLIC_URL",
              help: "What \"Connect your phone\" shows. Usually set at install (BUDGET_PUBLIC_URL).", configValue: { $0.publicURL }, builtInDefault: nil),
        .init(key: "dashboardURL", group: "Phone", label: "Dashboard URL for the phone", kind: .url, environmentVariable: "BUDGET_DASHBOARD_URL",
              help: "Where the phone's \"Open dashboard\" buttons go, to reconnect a bank or import a statement: this dashboard's address.",
              configValue: { $0.dashboardURL }, builtInDefault: nil),
        .init(key: "apnsKey", group: "Notifications", label: "APNs key (.p8)", kind: .secret, environmentVariable: "APNS_KEY",
              help: "The text of an APNs auth key from developer.apple.com → Keys, for the morning summary. Pasting it on one line is fine.",
              configValue: { $0.apnsKey }, builtInDefault: nil),
        .init(key: "apnsKeyID", group: "Notifications", label: "APNs key ID", kind: .text, environmentVariable: "APNS_KEY_ID",
              help: "The 10-character Key ID shown beside the key.", configValue: { $0.apnsKeyID }, builtInDefault: nil),
        .init(key: "apnsTeamID", group: "Notifications", label: "Team ID", kind: .text, environmentVariable: "APNS_TEAM_ID",
              help: "Your Apple Developer team: the one that signs the app.", configValue: { $0.apnsTeamID }, builtInDefault: nil),
        .init(key: "apnsTopic", group: "Notifications", label: "App bundle ID", kind: .text, environmentVariable: "APNS_TOPIC",
              help: "Where the notifications go: the Budget app's bundle ID (your prefix + .budget).", configValue: { $0.apnsTopic }, builtInDefault: nil),
    ]

    /// The flat model keys of the "server" row: what a 0.5.0 server reads, mirrored from the picks here.
    static let chatKeys = ["modelBaseURL", "modelAPIKey", "modelName"]
    static let decisionKeys = ["decisionBaseURL", "decisionAPIKey"]
    /// The most saved models kept for one job.
    static let modelLimit = 20
    /// The entries no one saved: they come from the Olares app, or stand for "none" / "the chat model's server".
    static let virtualIDs: Set<String> = ["environment", "off", "chat"]

    private let config: ServerConfig
    private let store: any ServerStore
    private let sealer: TokenSealer?
    private let logger: Logger
    private var saved = StoredServerSettings()
    private var models = StoredModelSettings()
    /// Both rows were read (and the models imported). Until then every write is refused.
    private var loaded = false
    /// `load()` has run, whether or not it worked: a write refused before then is early, not failed.
    private var loadAttempted = false
    /// Grows with every successful write, so an older snapshot is never applied over a newer one.
    private var generation = 0
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(config: ServerConfig, store: any ServerStore, sealer: TokenSealer?, logger: Logger = Logger(label: "budget-api")) {
        self.config = config
        self.store = store
        self.sealer = sealer
        self.logger = logger
    }

    /// Reads both rows; on first boot of this version (no "models" row), or after an older server edited the flat model
    /// keys, imports those into saved models. A row that reads is used even when the other doesn't, but a failure in
    /// either leaves the settings unloaded, so writes stay refused.
    public func load() async throws {
        try await exclusive {
            defer {
                loadAttempted = true
                generation += 1
            }
            // Read apart, so a models row that doesn't decode doesn't take the time zone, sync and keys with it.
            let serverRow = await attempt { try await store.serverSettings() ?? StoredServerSettings() }
            let modelsRow = await attempt { try await store.modelSettings() }
            if case let .success(server) = serverRow { saved = server }
            switch (serverRow, modelsRow) {
            case let (_, .success(existing?)):
                models = existing  // as stored, until the import below
            case let (.success(server), .failure):
                // Run what the readable server row mirrors, in memory only: writes stay refused.
                var next = StoredModelSettings()
                importChat(Self.flatModelValues(server.values), into: &next)
                importDecision(Self.flatModelValues(server.values), into: &next)
                models = next
            case let (.failure, .failure(error)):
                logger.error("the saved models didn't load either: \(error)")  // the server row's error is thrown below
            default:
                break
            }
            let server = try serverRow.get(), existing = try modelsRow.get()
            var next = existing ?? StoredModelSettings()
            var changed = false
            let flat = Self.flatModelValues(server.values)
            if existing == nil || flat != next.mirrored {
                // Only the job whose keys an older server changed is imported again; everything else stays as it was.
                // Categorizing is read again after a chat change too: 0.5.0's key on the chat model's server hangs on both.
                let chatChanged = existing == nil || Self.chatKeys.contains { flat[$0] != next.mirrored[$0] }
                let decisionChanged = chatChanged || Self.decisionKeys.contains { flat[$0] != next.mirrored[$0] }
                if chatChanged { importChat(flat, into: &next) }
                if decisionChanged { importDecision(flat, into: &next) }
                next.mirrored = flat
                changed = true
            }
            models = next  // what runs, even if a save below fails
            // The Olares app's settings can change between restarts, and the mirror depends on them: 0.5.0 must still
            // run what this server runs. Written like persist(): the server row first.
            let values = mirror(next, onto: server.values)
            if values != server.values {
                let rewritten = StoredServerSettings(values: values)
                try await store.saveServerSettings(rewritten)
                saved = rewritten
                next.mirrored = Self.flatModelValues(values)
                changed = true
            }
            if changed { try await store.saveModelSettings(next) }
            models = next
            loaded = true
        }
    }

    /// What `read` returns, or how it failed.
    private func attempt<T>(_ read: () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await read()) } catch { return .failure(error) }
    }

    // MARK: Effective values

    /// The value in force: dashboard, then environment, then default. Secrets come back opened.
    public func value(_ key: String) -> String? { value(key, in: saved) }

    private func value(_ key: String, in settings: StoredServerSettings) -> String? {
        guard let definition = Self.definitions.first(where: { $0.key == key }) else { return nil }
        if let stored = settings.values[key] {
            if stored.isEmpty { return nil }  // explicitly off
            if definition.kind == .secret { return open(stored) }
            return stored
        }
        return origin(definition, in: settings) == .environment ? definition.configValue(config) : definition.builtInDefault
    }

    /// The chat model in use (none when it's off).
    public var modelBaseURL: URL? { chatConnection.address }
    public var modelAPIKey: String? { chatConnection.key }
    public var modelName: String { chatConnection.model ?? config.modelName }
    /// Categorizing's local decision server in use; "the chat model's server" is the chat model's address.
    public var decisionBaseURL: URL? { decisionConnection.address }
    public var decisionAPIKey: String? { decisionConnection.key }
    public var openRouterKey: String? { value("openRouterKey") }
    public var openRouterZeroRetention: Bool { value("openRouterZeroRetention") == "true" }
    /// Between 15 minutes and a day, wherever it was set: an account is stale after 2 days without a good pull
    /// (`AccountHealth`), so a scheduled gap of 2 days or more would mark accounts stale between syncs. A value saved
    /// above 24 (0.5.x allowed a week) reads as 24.
    public var syncIntervalHours: Double { min(max(Double(value("syncIntervalHours") ?? "") ?? 6, 0.25), Double(Self.maxSyncIntervalHours)) }
    public static let maxSyncIntervalHours = 24
    public var timeZone: TimeZone { value("timeZone").flatMap(TimeZone.init(identifier:)) ?? config.timeZone }
    public var publicURL: String? { value("publicURL") }
    public var dashboardURL: String? { value("dashboardURL") }
    /// Whether to read card bills from Plaid Liabilities (billed per Item once used): off unless turned on.
    public var cardBillsEnabled: Bool { value("cardBills") == "true" }
    /// Which Items get holdings: `auto` (only those already billed for Investments), `on` or `off`.
    public var holdingsMode: HoldingsMode { HoldingsMode(setting: value("holdings")) }
    /// Whether to register Plaid webhooks; they also need the public URL.
    public var plaidWebhooksEnabled: Bool { value("plaidWebhooks") != "false" }
    /// SimpleFIN pulls a day on the server's own initiative (the hard stop stays in code).
    public var simplefinDailyPulls: Int { Int(min(max(Double(value("simplefinDailyPulls") ?? "") ?? 4, 1), Double(SimpleFINBudget.maxAutomaticPerDay))) }

    /// The public URL a provider calls back (webhooks, the phone's OAuth return): without a trailing slash, and only
    /// https — plain http only for a Plaid sandbox test server. Nil when there's none to use.
    public func providerCallbackBase(sandbox: Bool) -> String? {
        ServerConfig.normalizedPublicURL(publicURL, allowHTTP: sandbox)
    }

    /// Where a bank app returns the phone after an OAuth sign-in (`PLAID_MOBILE_REDIRECT_URI`): that value, or
    /// `<public URL>/plaid/oauth-return`; nil when it's `off` or there's no public URL. In production the default is a
    /// Universal Link only once `BUDGET_IOS_APP_ID` is set (without it the AASA file is a 404 and an app-to-app OAuth
    /// bank returns to a page in Safari, stranding the sign-in), so it's nil until then (`missingAppLinks`). An explicit
    /// `PLAID_MOBILE_REDIRECT_URI` is the operator's choice and is trusted as given.
    public func plaidMobileRedirectURI(sandbox: Bool) -> String? {
        if let raw = config.plaidMobileRedirectURI { return raw.lowercased() == "off" ? nil : raw }
        if missingAppLinks(sandbox: sandbox) { return nil }
        return providerCallbackBase(sandbox: sandbox).map { $0 + "/plaid/oauth-return" }
    }

    /// Production with the default mobile redirect but no `BUDGET_IOS_APP_ID`: the redirect wouldn't open the app.
    public func missingAppLinks(sandbox: Bool) -> Bool {
        guard !sandbox, config.plaidMobileRedirectURI == nil else { return false }
        return (config.iosAppID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Every model the app builds, from one read.
    public func modelSnapshot() -> ModelSnapshot {
        let chat = chatConnection, decision = decisionConnection
        return ModelSnapshot(chatURL: chat.address, chatKey: chat.key, chatName: chat.model ?? config.modelName,
                             decisionURL: decision.address, decisionKey: decision.key,
                             openRouterKey: openRouterKey, zeroRetention: openRouterZeroRetention, generation: generation)
    }

    private func origin(_ definition: Definition, in settings: StoredServerSettings) -> SettingField.Origin {
        if settings.values[definition.key] != nil { return .dashboard }
        // Set in the environment, or (for configs built in code) different from the built-in default.
        if config.environmentKeys.contains(definition.environmentVariable) { return .environment }
        let value = definition.configValue(config)
        return value != nil && value != definition.builtInDefault ? .environment : .default
    }

    public func fields() -> [SettingField] {
        Self.definitions.map { d in
            let current = value(d.key)
            return SettingField(key: d.key, group: d.group, label: d.label, kind: d.kind,
                                value: d.kind == .secret ? nil : current, isSet: current != nil, origin: origin(d, in: saved),
                                defaultValue: d.builtInDefault, environmentVariable: d.environmentVariable, help: d.help, choices: d.choices)
        }
    }

    // MARK: Editing

    /// Sets each key to its new value; `nil` resets it to the environment or default. With the ledger's `policy`, refuses
    /// to leave Jev without a key while it categorizes or is asked when the local model is unsure.
    public func update(_ changes: [String: String?], policy: DecisionPolicy? = nil) async throws {
        try await exclusive {
            try requireLoaded()
            var next = saved
            for (key, newValue) in changes {
                guard let definition = Self.definitions.first(where: { $0.key == key }) else {
                    throw BudgetAPIError.rejected("Unknown setting “\(key)”.")
                }
                guard let raw = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    next.values[key] = nil
                    continue
                }
                next.values[key] = try validated(raw, for: definition)
            }
            if let policy, policy.usesJev, changes.keys.contains("openRouterKey"), value("openRouterKey", in: next) == nil {
                throw BudgetAPIError.rejected(policy.provider == .jev ? "Jev is categorizing now. Pick another one and save first."
                                                                      : "Jev is asked when the local model is unsure. Turn that off and save first.")
            }
            try await store.saveServerSettings(next)
            saved = next
            generation += 1
        }
    }

    private func validated(_ raw: String, for d: Definition) throws -> String {
        switch d.kind {
        case .url:
            // Empty means "off", distinct from resetting to the environment.
            if raw.isEmpty { return "" }
            guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
                throw BudgetAPIError.rejected("\(d.label) must be an http(s) URL.")
            }
            return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        case .text:
            guard !raw.isEmpty else { throw BudgetAPIError.rejected("\(d.label) can't be empty.") }
            return raw
        case .number:
            let range = d.range ?? 0.25...(24 * 7)
            guard let number = Double(raw), range.contains(number) else {
                // Plain digits, not `formatted()`: the server's locale mustn't change the message ("0.25", never "0,25").
                let plain = { (n: Double) in n == n.rounded() ? String(Int(n)) : String(n) }
                throw BudgetAPIError.rejected("\(d.label) must be a number between \(plain(range.lowerBound)) and \(plain(range.upperBound)).")
            }
            return String(number)
        case .choice:
            let choice = HoldingsMode.synonym(raw.lowercased())
            guard d.choices?.contains(choice) == true else {
                throw BudgetAPIError.rejected("\(d.label) must be one of \((d.choices ?? []).joined(separator: ", ")).")
            }
            return choice
        case .bool:
            guard ["true", "false"].contains(raw) else { throw BudgetAPIError.rejected("\(d.label) must be true or false.") }
            return raw
        case .timeZone:
            guard TimeZone(identifier: raw) != nil else { throw BudgetAPIError.rejected("“\(raw)” isn't a time zone (try America/Los_Angeles).") }
            return raw
        case .secret:
            if raw.isEmpty { return "" }  // off, even if the environment sets one
            return try seal(raw)
        }
    }

    private func seal(_ key: String) throws -> String {
        guard let sealer else {
            throw BudgetAPIError.rejected("Add an encryption key (BUDGET_TOKEN_KEY) to the server's install settings (budget.env on a Mac, the app's settings on an Olares), then restart it, before saving keys.")
        }
        return try sealer.seal(key)
    }

    private func open(_ sealed: String?) -> String? {
        guard let sealed, !sealed.isEmpty, let sealer else { return nil }
        return try? sealer.open(sealed)
    }

    // MARK: Saved models

    /// Adds a model (`draft.id` nil) or edits a saved one. A new chat model is put in use only on a server with no chat
    /// model at all, and never when that would also move a live categorizer (`policy` localDecide on the chat model's
    /// server). Categorizing servers are never picked here: that's the person's call.
    public func saveModel(_ draft: ModelDraft, policy: DecisionProvider) async throws -> (id: String, autoSelected: Bool) {
        try await exclusive {
            try requireLoaded()
            guard let job = Job(rawValue: draft.kind) else { throw BudgetAPIError.rejected("A model is either a chat model or a categorizing server.") }
            var next = models
            var entry: SavedModel
            var index: Int?
            if let id = draft.id {
                if Self.virtualIDs.contains(id) { throw Self.notSaved(id) }
                guard let i = next.models.firstIndex(where: { $0.id == id && $0.kind == job.kind }) else { throw BudgetAPIError.rejected("No such model.") }
                index = i
                entry = next.models[i]
            } else {
                guard next.models.count(where: { $0.kind == job.kind }) < Self.modelLimit else {
                    throw BudgetAPIError.rejected("That's the most this server keeps for one job.")
                }
                entry = SavedModel(id: UUID().uuidString.lowercased(), kind: job.kind, name: "")
            }
            let before = index.map { _ in resolve(entry) }
            var inherit = entry.inherit ?? []
            func typed(_ text: String?) -> String? { text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }

            // Address: required unless it follows the Olares app and none is typed. Left out of an edit, it stays.
            if let text = typed(draft.address) {
                entry.address = try ModelCheck.address(text).absoluteString
                inherit.removeAll { $0 == "address" }
            } else if !(inherit.contains("address") || (draft.address == nil && entry.address != nil)) {
                throw BudgetAPIError.rejected("Add the server's address.")
            }

            if job == .chat {
                if let text = typed(draft.model) {
                    guard text.count <= 200 else { throw BudgetAPIError.rejected("That model name is too long.") }
                    entry.model = text
                    inherit.removeAll { $0 == "model" }
                } else if !(inherit.contains("model") || (draft.model == nil && entry.model != nil)) {
                    throw BudgetAPIError.rejected("Add the model's name, as the server knows it.")
                }
            } else {
                entry.model = nil
                inherit.removeAll { $0 == "model" }
            }

            if let key = typed(draft.apiKey) {
                guard key.utf8.count <= 8 * 1024 else { throw BudgetAPIError.rejected("That key is too long.") }
                entry.sealedKey = try seal(key)
                inherit.removeAll { $0 == "key" }
            } else if draft.useOpenRouterKey == true {
                // A copy, sealed again: the rollback mirror carries it like any typed key, and a later change to Jev's key
                // leaves this one as it is. It only ever goes to OpenRouter.
                var probe = entry
                probe.inherit = inherit
                guard job == .chat, let address = resolve(probe).address, ModelCheck.isOpenRouter(address) else {
                    throw BudgetAPIError.rejected("Jev's OpenRouter key only goes to OpenRouter: use the address https://openrouter.ai/api/v1.")
                }
                guard let key = openRouterKey else { throw BudgetAPIError.rejected("No OpenRouter key is saved. Add one on Jev first.") }
                entry.sealedKey = try seal(key)
                inherit.removeAll { $0 == "key" }
            } else if draft.removeKey == true {
                entry.sealedKey = nil
                inherit.removeAll { $0 == "key" }
            } else if let before {
                // A key stays with the server it was saved for: on another server it has to be typed again or removed.
                var moved = entry
                moved.inherit = inherit
                let after = resolve(moved).address
                if !(before.address == nil && after == nil), !ModelCheck.sameServer(before.address, after) {
                    if entry.sealedKey != nil || (inherit.contains("key") && before.key != nil) {
                        throw BudgetAPIError.rejected("The address is on another server now: type its API key, or remove the key.")
                    }
                    inherit.removeAll { $0 == "key" }  // no key now, and none to follow there later
                }
            }
            entry.inherit = inherit.isEmpty ? nil : inherit

            if let text = typed(draft.name) {
                guard text.count <= 60 else { throw BudgetAPIError.rejected("Keep the name to 60 characters or fewer.") }
                entry.name = text
            } else if draft.name != nil || index == nil || entry.name.isEmpty {
                let resolved = resolve(entry)
                entry.name = job == .chat ? resolved.model ?? config.modelName : resolved.address?.host() ?? "Categorizing server"
            }

            var autoSelected = false
            if let index {
                next.models[index] = entry
            } else {
                next.models.append(entry)
                if job == .chat, !exists(models.inUse["chat"], .chat, in: models), config.modelBaseURL == nil,
                   !models.models.contains(where: { $0.kind == .chat }),
                   !(pick(.decision, in: models) == "chat" && policy == .localDecide) {
                    next.inUse["chat"] = entry.id
                    autoSelected = true
                }
            }
            try await persist(next)
            return (entry.id, autoSelected)
        }
    }

    /// Removes a saved model. The one a job uses can't go (a categorizing server only counts while categorizing runs on
    /// it, `policy` localDecide); a categorizing server picked while categorizing is off or elsewhere goes, and the pick
    /// goes back to the default.
    public func removeModel(id: String, policy: DecisionProvider) async throws {
        try await exclusive {
            try requireLoaded()
            if Self.virtualIDs.contains(id) { throw Self.notSaved(id) }
            var next = models
            guard let index = next.models.firstIndex(where: { $0.id == id && ($0.kind == .chat || $0.kind == .decision) }) else {
                throw BudgetAPIError.rejected("No such model.")
            }
            let job: Job = next.models[index].kind == .chat ? .chat : .decision
            if pick(job, in: next) == id, job == .chat || policy == .localDecide {
                throw BudgetAPIError.rejected("In use. Pick another one and save first.")
            }
            next.models.remove(at: index)
            if next.inUse[job.rawValue] == id { next.inUse[job.rawValue] = nil }
            try await persist(next)
        }
    }

    /// Picks the model each given job uses.
    public func use(chat: String?, decision: String?) async throws {
        try await exclusive {
            try requireLoaded()
            var next = models
            for (job, id) in [(Job.chat, chat), (Job.decision, decision)] {
                guard let id else { continue }
                guard exists(id, job, in: next) else { throw BudgetAPIError.rejected("No such model.") }
                next.inUse[job.rawValue] = id
            }
            try await persist(next)
        }
    }

    private static func notSaved(_ id: String) -> BudgetAPIError {
        .rejected(id == "environment" ? "That one comes from the server's install settings; change it there." : "No such model.")
    }

    /// Writes the mirror into the "server" row (only when it changed), then the models row: a crash between the two is
    /// put right by the import on the next load.
    private func persist(_ proposed: StoredModelSettings) async throws {
        var next = proposed
        let values = mirror(next, onto: saved.values)
        if values != saved.values {
            let server = StoredServerSettings(values: values)
            try await store.saveServerSettings(server)
            saved = server
        }
        next.mirrored = Self.flatModelValues(values)
        try await store.saveModelSettings(next)
        models = next
        generation += 1
    }

    // MARK: The models in force

    /// The model `id` stands for in `job`: a saved one, "environment", "off" (no address) or, for categorizing, "chat"
    /// (`/v1/systemone` on the chat model's server). Nil when there's no such model.
    func connection(_ job: Job, id: String) -> ModelConnection? { connection(job, id: id, in: models) }

    private var chatConnection: ModelConnection { connection(.chat, id: pick(.chat, in: models), in: models) ?? ModelConnection() }
    private var decisionConnection: ModelConnection { connection(.decision, id: pick(.decision, in: models), in: models) ?? ModelConnection() }

    private func connection(_ job: Job, id: String, in m: StoredModelSettings) -> ModelConnection? {
        switch (job, id) {
        case (.chat, "off"):
            return ModelConnection()
        case (.chat, "environment"):
            guard let url = config.modelBaseURL else { return nil }
            return ModelConnection(address: ModelCheck.base(url), key: config.modelAPIKey, model: config.modelName)
        case (.decision, "environment"):
            return environmentDecisionURL.map { ModelConnection(address: ModelCheck.base($0), key: config.decisionAPIKey) }
        case (.decision, "chat"):
            let chat = connection(.chat, id: pick(.chat, in: m), in: m) ?? ModelConnection()
            return ModelConnection(address: chat.address, key: sendsDecisionKeyToChatServer(in: m) ? config.decisionAPIKey : chat.key)
        default:
            return m.models.first { $0.id == id && $0.kind == job.kind }.map(resolve)
        }
    }

    /// Whether categorizing on the chat model's server sends DECISION_API_KEY instead of the chat model's key: 0.5.0's
    /// pairing, kept only where that key can be meant for that server. It is when the chat model's address comes from
    /// the Olares app, DECISION_BASE_URL isn't a server of its own, and a 0.5.0 "Turn off" of the key wasn't imported.
    private func sendsDecisionKeyToChatServer(in m: StoredModelSettings) -> Bool {
        guard environmentDecisionURL == nil, config.decisionAPIKey != nil, m.chatServerKey != "chat" else { return false }
        let chatID = pick(.chat, in: m)
        return chatID == "environment" || m.models.first { $0.id == chatID && $0.kind == .chat }?.inherit?.contains("address") == true
    }

    /// A saved model with what it inherits filled in from the Olares app as it is now.
    private func resolve(_ entry: SavedModel) -> ModelConnection {
        let inherits = Set(entry.inherit ?? [])
        let chat = entry.kind == .chat
        let address = inherits.contains("address") ? (chat ? config.modelBaseURL : environmentDecisionURL).map(ModelCheck.base)
                                                   : entry.address.flatMap(URL.init(string:))
        let key = inherits.contains("key") ? (chat ? config.modelAPIKey : config.decisionAPIKey) : open(entry.sealedKey)
        let model = chat ? (inherits.contains("model") ? config.modelName : entry.model) : nil
        return ModelConnection(address: address, key: key, model: model)
    }

    /// The Olares app's own categorizing server: DECISION_BASE_URL, when it isn't just the chat model's.
    private var environmentDecisionURL: URL? {
        config.decisionBaseURL != nil && config.decisionBaseURL != config.modelBaseURL ? config.decisionBaseURL : nil
    }

    private func exists(_ id: String?, _ job: Job, in m: StoredModelSettings) -> Bool {
        guard let id else { return false }
        switch (job, id) {
        case (.chat, "off"), (.decision, "chat"): return true
        case (.chat, "environment"): return config.modelBaseURL != nil
        case (.decision, "environment"): return environmentDecisionURL != nil
        default: return m.models.contains { $0.id == id && $0.kind == job.kind }
        }
    }

    /// The pick in force: the saved one if it still exists, else the Olares app's, else off / the chat model's server.
    private func pick(_ job: Job, in m: StoredModelSettings) -> String {
        if let id = m.inUse[job.rawValue], exists(id, job, in: m) { return id }
        return exists("environment", job, in: m) ? "environment" : (job == .chat ? "off" : "chat")
    }

    // MARK: The list

    public func modelList() -> ModelList {
        let m = models
        func entry(_ s: SavedModel) -> ModelList.Entry {
            let resolved = resolve(s)
            let inherits = s.inherit ?? []
            let unreadable = !inherits.contains("key") && s.sealedKey != nil && resolved.key == nil
            return ModelList.Entry(id: s.id, kind: s.kind.rawValue, name: s.name, address: resolved.address?.absoluteString, model: resolved.model,
                                   hasKey: resolved.key != nil, keyUnreadable: unreadable, origin: "dashboard", inherits: inherits,
                                   local: resolved.address.map(ModelCheck.isLocal) ?? true)
        }
        func environment(_ job: Job) -> [ModelList.Entry] {
            guard let c = connection(job, id: "environment", in: m) else { return [] }
            let name = job == .chat ? config.modelName : c.address?.host() ?? "Categorizing server"
            return [ModelList.Entry(id: "environment", kind: job.rawValue, name: name, address: c.address?.absoluteString, model: c.model,
                                    hasKey: c.key != nil, keyUnreadable: false, origin: "environment",
                                    inherits: job == .chat ? ["address", "key", "model"] : ["address", "key"],
                                    local: c.address.map(ModelCheck.isLocal) ?? true)]
        }
        let chatServer = chatConnection.address
        let jevKey = Self.definitions.first { $0.key == "openRouterKey" }!
        let savedJevKey = saved.values["openRouterKey"] ?? ""
        return ModelList(
            chat: environment(.chat) + m.models.filter { $0.kind == .chat }.map(entry),
            decision: environment(.decision) + m.models.filter { $0.kind == .decision }.map(entry),
            chatInUse: pick(.chat, in: m), decisionInUse: pick(.decision, in: m),
            chatServer: .init(address: chatServer?.absoluteString, local: chatServer.map(ModelCheck.isLocal) ?? true),
            jev: .init(hasKey: openRouterKey != nil, keyUnreadable: !savedJevKey.isEmpty && open(savedJevKey) == nil,
                       zeroRetention: openRouterZeroRetention, keyOrigin: origin(jevKey, in: saved).rawValue),
            sealingAvailable: sealer != nil, limit: Self.modelLimit)
    }

    // MARK: Import and the rollback mirror

    /// The five flat model keys of a "server" row's values.
    static func flatModelValues(_ values: [String: String]) -> [String: String] {
        values.filter { (chatKeys + decisionKeys).contains($0.key) }
    }

    /// The chat model an older server set up, as a saved model in use: each (address, key, model) exactly as it paired
    /// them. Values that came from the environment are inherited, never copied; a sealed key is copied as it is.
    private func importChat(_ v: [String: String], into next: inout StoredModelSettings) {
        guard Self.chatKeys.contains(where: { v[$0] != nil }) else {
            next.inUse["chat"] = nil
            return
        }
        if v["modelBaseURL"] == "" {
            next.inUse["chat"] = "off"
            if !(v["modelAPIKey"] ?? "").isEmpty || v["modelName"] != nil {
                logger.notice("models: the chat model was turned off, so its leftover key or model name wasn't kept")
            }
            return
        }
        var entry = SavedModel(id: "", kind: .chat, name: "")
        var inherit: [String] = []
        if let text = v["modelBaseURL"] {
            entry.address = URL(string: text).map(ModelCheck.base)?.absoluteString ?? text
        } else if config.modelBaseURL != nil {
            inherit.append("address")
        } else {
            next.inUse["chat"] = nil
            logger.notice("models: a saved chat key or model name had no address to go with, so it wasn't kept")
            return
        }
        switch v["modelAPIKey"] {
        case let key? where !key.isEmpty: entry.sealedKey = key
        case .some: break
        case nil: if config.modelAPIKey != nil { inherit.append("key") }
        }
        if let model = v["modelName"], !model.isEmpty { entry.model = model } else { inherit.append("model") }
        entry.inherit = inherit.isEmpty ? nil : inherit
        entry.name = resolve(entry).model ?? config.modelName
        next.inUse["chat"] = adopt(entry, prefix: "migrated-chat", into: &next)
    }

    /// The categorizing server an older server set up. Only a pairing it really used is kept: a key alone goes with the
    /// Olares app's own decision server, or nowhere. A key turned off ("") on the chat model's server stays off there:
    /// the chat model's key goes instead, never DECISION_API_KEY.
    private func importDecision(_ v: [String: String], into next: inout StoredModelSettings) {
        next.chatServerKey = nil
        guard Self.decisionKeys.contains(where: { v[$0] != nil }) else {
            next.inUse["decision"] = nil
            return
        }
        if v["decisionBaseURL"] == "" {
            next.inUse["decision"] = "chat"
            if v["decisionAPIKey"] == "" {
                next.chatServerKey = "chat"
            } else if v["decisionAPIKey"] != nil {
                logger.notice("models: categorizing used the chat model's server, so its own leftover key wasn't kept")
            }
            return
        }
        var entry = SavedModel(id: "", kind: .decision, name: "")
        var inherit: [String] = []
        if let text = v["decisionBaseURL"] {
            entry.address = URL(string: text).map(ModelCheck.base)?.absoluteString ?? text
            switch v["decisionAPIKey"] {
            case let key? where !key.isEmpty: entry.sealedKey = key
            case .some: break
            case nil: if config.decisionAPIKey != nil { inherit.append("key") }
            }
        } else if environmentDecisionURL != nil {
            inherit.append("address")
            if let key = v["decisionAPIKey"], !key.isEmpty { entry.sealedKey = key }
        } else {
            // Only a key, and no server of its own: categorizing stays on its default, the chat model's server.
            next.inUse["decision"] = nil
            if v["decisionAPIKey"] == "" {
                next.chatServerKey = "chat"
            } else {
                logger.notice("models: a saved categorizing key had no server of its own to go with, so it wasn't kept")
            }
            return
        }
        entry.inherit = inherit.isEmpty ? nil : inherit
        entry.name = resolve(entry).address?.host() ?? "Categorizing server"
        next.inUse["decision"] = adopt(entry, prefix: "migrated-decision", into: &next)
    }

    /// The id of a saved model identical to `entry` (same address, key, model and inheritance), or of `entry` added
    /// under the next free "<prefix>", "<prefix>-2", ….
    private func adopt(_ entry: SavedModel, prefix: String, into next: inout StoredModelSettings) -> String {
        if let same = next.models.first(where: {
            $0.kind == entry.kind && $0.address == entry.address && $0.sealedKey == entry.sealedKey && $0.model == entry.model
                && Set($0.inherit ?? []) == Set(entry.inherit ?? [])
        }) {
            return same.id
        }
        var id = prefix, n = 1
        while next.models.contains(where: { $0.id == id }) {
            n += 1
            id = "\(prefix)-\(n)"
        }
        var added = entry
        added.id = id
        next.models.append(added)
        return id
    }

    /// The flat model keys a 0.5.0 server needs to run the models this one runs: absent follows the Olares app, "" is
    /// off (or, for categorizing, the chat model's server). Ask mirrors the stored pick, so 0.5.0's own default stays the
    /// same. Categorizing mirrors the pick in force, because 0.5.0's default sends DECISION_API_KEY to whatever chat
    /// server there is, and this one doesn't.
    private func mirror(_ m: StoredModelSettings, onto values: [String: String]) -> [String: String] {
        var values = values
        for key in Self.chatKeys + Self.decisionKeys { values[key] = nil }
        let chat = m.inUse["chat"].flatMap { exists($0, .chat, in: m) ? $0 : nil }
        switch chat {
        case nil, "environment": break
        case "off": values["modelBaseURL"] = ""
        case let id?:
            if let e = m.models.first(where: { $0.id == id }) {
                let inherits = Set(e.inherit ?? [])
                if !inherits.contains("address") { values["modelBaseURL"] = e.address }
                if !inherits.contains("key") { values["modelAPIKey"] = e.sealedKey ?? "" }
                if !inherits.contains("model") { values["modelName"] = e.model }
            }
        }
        switch pick(.decision, in: m) {
        case "environment": break
        case "chat":
            // Picked: an empty address. By default (no Olares app server of its own then), none: 0.5.0's default too.
            if m.inUse["decision"] == "chat" { values["decisionBaseURL"] = "" }
            // 0.5.0 sends DECISION_API_KEY there whenever it's set; an empty one makes it send the chat model's key.
            if config.decisionAPIKey != nil, !sendsDecisionKeyToChatServer(in: m) { values["decisionAPIKey"] = "" }
        case let id:
            guard let e = m.models.first(where: { $0.id == id && $0.kind == .decision }) else { break }
            if resolve(e).address == nil {
                // Its inherited address is gone, so nothing categorizes here. 0.5.0 can't say that and falls back to the
                // chat model's server: send that server's own key, never this entry's.
                values["decisionAPIKey"] = ""
            } else {
                let inherits = Set(e.inherit ?? [])
                if !inherits.contains("address") { values["decisionBaseURL"] = e.address }
                if !inherits.contains("key") { values["decisionAPIKey"] = e.sealedKey ?? "" }
            }
        }
        return values
    }

    // MARK: One writer at a time

    /// First come, first served; a release hands the lock straight to the next waiter, so a newcomer can't barge in.
    /// Waiting isn't cancellable, so a handed-over lock is never dropped.
    private func acquire() async {
        if locked {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            locked = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()  // still locked: it's the next writer's now
        }
    }

    /// `body` with the lock held. Nothing inside calls another method that takes it.
    private func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    /// A write that comes before `load()` has run is early: the dashboard listens while the server is still starting.
    private func requireLoaded() throws {
        guard loaded else {
            throw BudgetAPIError.server(status: 503, message: loadAttempted
                ? "Server settings didn't load, so nothing was changed. Restart the server; its log says why."
                : "The server is still starting. Try again in a moment.")
        }
    }
}

/// Which Plaid Items get investment holdings.
public enum HoldingsMode: String, Sendable {
    /// Only Items Plaid already bills for Investments: no new cost.
    case auto
    case on
    case off

    init(setting: String?) { self = Self(rawValue: Self.synonym(setting?.lowercased() ?? "")) ?? .auto }

    /// `1`/`true`/`yes` read as on, `0`/`false`/`no` as off; anything else as given.
    static func synonym(_ raw: String) -> String {
        switch raw {
        case "1", "true", "yes": "on"
        case "0", "false", "no": "off"
        default: raw
        }
    }
}
