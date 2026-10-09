import BudgetKit
import Foundation

/// Server settings saved from the dashboard: overrides over the environment (the Olares app's
/// settings), which are themselves over built-in defaults. Values are strings; secrets are sealed.
public struct StoredServerSettings: Codable, Hashable, Sendable {
    public var values: [String: String]
    public init(values: [String: String] = [:]) { self.values = values }
}

/// One editable setting as the dashboard shows it. A secret's value is never included.
public struct SettingField: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case url, text, number, secret, bool, timeZone }
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
}

/// The effective server settings, rebuilt whenever the dashboard saves. Applying them swaps the
/// models, calendar and endpoint live (`BudgetServerApp.apply`); sync reads its interval each cycle.
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
    }

    static let definitions: [Definition] = [
        .init(key: "modelBaseURL", group: "Models", label: "Chat model endpoint", kind: .url, environmentVariable: "MODEL_BASE_URL",
              help: "OpenAI-compatible server for Ask (Qwen on your Olares). Empty = templated answers only.",
              configValue: { $0.modelBaseURL?.absoluteString }, builtInDefault: nil),
        .init(key: "modelAPIKey", group: "Models", label: "Chat model API key", kind: .secret, environmentVariable: "MODEL_API_KEY",
              help: "Sent as a bearer token to the chat endpoint, when it asks for one.",
              configValue: { $0.modelAPIKey }, builtInDefault: nil),
        .init(key: "modelName", group: "Models", label: "Model name", kind: .text, environmentVariable: "MODEL_NAME",
              help: "Sent as `model` to the chat endpoint.", configValue: { $0.modelName }, builtInDefault: "qwen3.8-27b"),
        .init(key: "decisionBaseURL", group: "Models", label: "Decision endpoint", kind: .url, environmentVariable: "DECISION_BASE_URL",
              help: "Server with /v1/systemone for categorizing. Empty = the chat endpoint.",
              configValue: { $0.decisionBaseURL == $0.modelBaseURL ? nil : $0.decisionBaseURL?.absoluteString }, builtInDefault: nil),
        .init(key: "decisionAPIKey", group: "Models", label: "Decision endpoint API key", kind: .secret, environmentVariable: "DECISION_API_KEY",
              help: "Sent as a bearer token to the decision endpoint. Empty with no decision endpoint of its own = the chat model's key.",
              configValue: { $0.decisionAPIKey }, builtInDefault: nil),
        .init(key: "openRouterKey", group: "Jev", label: "OpenRouter API key", kind: .secret, environmentVariable: "OPENROUTER_API_KEY",
              help: "Enables Jev as a decision provider. Only merchant names and category ids are sent.",
              configValue: { $0.openRouterKey }, builtInDefault: nil),
        .init(key: "openRouterZeroRetention", group: "Jev", label: "Zero data retention only", kind: .bool, environmentVariable: "OPENROUTER_ZDR",
              help: "Ask OpenRouter to route only to providers that keep nothing.",
              configValue: { $0.openRouterZeroRetention ? "true" : "false" }, builtInDefault: "false"),
        .init(key: "syncIntervalHours", group: "Sync", label: "Sync every (hours)", kind: .number, environmentVariable: "BUDGET_SYNC_INTERVAL_HOURS",
              help: "How often linked accounts are pulled. At least 0.25.", configValue: { String($0.syncIntervalHours) }, builtInDefault: "6.0"),
        .init(key: "cardBills", group: "Sync", label: "Card bills (Plaid Liabilities)", kind: .bool, environmentVariable: "BUDGET_PLAID_LIABILITIES",
              help: "Reads each Plaid-linked credit card's statement balance, minimum payment and due date, about once a day, for Upcoming and the morning summary. Plaid bills Liabilities per bank login once it's used, so it's off until you turn it on. A bank linked before needs one \"Grant card-bill access\" sign-in on Accounts; nothing is relinked or removed.",
              configValue: { $0.plaidLiabilities ? "true" : "false" }, builtInDefault: "false"),
        .init(key: "timeZone", group: "Sync", label: "Time zone", kind: .timeZone, environmentVariable: "BUDGET_TIMEZONE",
              help: "Where months begin and end (e.g. America/Los_Angeles).", configValue: { $0.timeZone.identifier }, builtInDefault: "America/Los_Angeles"),
        .init(key: "publicURL", group: "Phone", label: "Server URL for the phone", kind: .url, environmentVariable: "BUDGET_PUBLIC_URL",
              help: "What \"Connect your phone\" shows. The Olares chart fills it in.", configValue: { $0.publicURL }, builtInDefault: nil),
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

    private let config: ServerConfig
    private let store: any ServerStore
    private let sealer: TokenSealer?
    private var saved = StoredServerSettings()

    public init(config: ServerConfig, store: any ServerStore, sealer: TokenSealer?) {
        self.config = config
        self.store = store
        self.sealer = sealer
    }

    public func load() async throws {
        saved = try await store.serverSettings() ?? StoredServerSettings()
    }

    // MARK: Effective values

    /// The value in force: dashboard, then environment, then default. Secrets come back opened.
    public func value(_ key: String) -> String? {
        guard let definition = Self.definitions.first(where: { $0.key == key }) else { return nil }
        if let stored = saved.values[key] {
            if stored.isEmpty { return nil }  // explicitly off
            if definition.kind == .secret { return sealer.flatMap { try? $0.open(stored) } }
            return stored
        }
        return origin(definition) == .environment ? definition.configValue(config) : definition.builtInDefault
    }

    public var modelBaseURL: URL? { value("modelBaseURL").flatMap(URL.init(string:)).map(ModelCheck.base) }
    public var modelAPIKey: String? { value("modelAPIKey") }
    public var decisionBaseURL: URL? { value("decisionBaseURL").flatMap(URL.init(string:)).map(ModelCheck.base) ?? modelBaseURL }
    /// The decision endpoint's own key; with no endpoint of its own, the chat model's.
    public var decisionAPIKey: String? { value("decisionAPIKey") ?? (value("decisionBaseURL") == nil ? modelAPIKey : nil) }
    public var modelName: String { value("modelName") ?? "qwen3.8-27b" }
    public var openRouterKey: String? { value("openRouterKey") }
    public var openRouterZeroRetention: Bool { value("openRouterZeroRetention") == "true" }
    public var syncIntervalHours: Double { max(Double(value("syncIntervalHours") ?? "") ?? 6, 0.25) }
    public var timeZone: TimeZone { value("timeZone").flatMap(TimeZone.init(identifier:)) ?? config.timeZone }
    public var publicURL: String? { value("publicURL") }
    public var dashboardURL: String? { value("dashboardURL") }
    /// Whether to read card bills from Plaid Liabilities (billed per Item once used): off unless turned on.
    public var cardBillsEnabled: Bool { value("cardBills") == "true" }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func origin(_ definition: Definition) -> SettingField.Origin {
        if saved.values[definition.key] != nil { return .dashboard }
        // Set in the environment, or (for configs built in code) different from the built-in default.
        if config.environmentKeys.contains(definition.environmentVariable) { return .environment }
        let value = definition.configValue(config)
        return value != nil && value != definition.builtInDefault ? .environment : .default
    }

    public func fields() -> [SettingField] {
        Self.definitions.map { d in
            let current = value(d.key)
            return SettingField(key: d.key, group: d.group, label: d.label, kind: d.kind,
                                value: d.kind == .secret ? nil : current, isSet: current != nil, origin: origin(d),
                                defaultValue: d.builtInDefault, environmentVariable: d.environmentVariable, help: d.help)
        }
    }

    // MARK: Editing

    /// Sets each key to its new value; `nil` resets it to the environment or default.
    public func update(_ changes: [String: String?]) async throws {
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
        try await store.saveServerSettings(next)
        saved = next
    }

    private func validated(_ raw: String, for d: Definition) throws -> String {
        switch d.kind {
        case .url:
            // Empty means "off" (e.g. no chat model), distinct from resetting to the environment.
            if raw.isEmpty { return "" }
            guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
                throw BudgetAPIError.rejected("\(d.label) must be an http(s) URL.")
            }
            // A model server is saved as its base: "…/v1" and "…/v1/chat/completions" mean the same server.
            if ["modelBaseURL", "decisionBaseURL"].contains(d.key) { return ModelCheck.base(url).absoluteString }
            return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        case .text:
            guard !raw.isEmpty else { throw BudgetAPIError.rejected("\(d.label) can't be empty.") }
            return raw
        case .number:
            guard let number = Double(raw), number >= 0.25, number <= 24 * 7 else { throw BudgetAPIError.rejected("\(d.label) must be a number between 0.25 and 168.") }
            return String(number)
        case .bool:
            guard ["true", "false"].contains(raw) else { throw BudgetAPIError.rejected("\(d.label) must be true or false.") }
            return raw
        case .timeZone:
            guard TimeZone(identifier: raw) != nil else { throw BudgetAPIError.rejected("“\(raw)” isn't a time zone (try America/Los_Angeles).") }
            return raw
        case .secret:
            if raw.isEmpty { return "" }  // off, even if the environment sets one
            guard let sealer else { throw BudgetAPIError.rejected("Set BUDGET_TOKEN_KEY on the server before saving keys.") }
            return try sealer.seal(raw)
        }
    }
}
