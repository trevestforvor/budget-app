import BudgetKit
import Foundation

/// Everything the server needs, read from the environment (the Olares chart sets these).
public struct ServerConfig: Sendable {
    public struct Database: Sendable {
        public var host: String
        public var port: Int
        public var username: String
        public var password: String?
        public var database: String
    }

    public struct Plaid: Sendable {
        public var clientID: String
        public var secret: String
        public var environment: PlaidSource.Environment
        public var redirectURI: String?
    }

    public struct Teller: Sendable {
        public var certificatePath: String
        public var keyPath: String
    }

    /// Loopback unless told otherwise; the Olares chart sets HOST=0.0.0.0 inside its pod.
    public var host = "127.0.0.1"
    public var port = 8080
    /// A second listener for the browser dashboard. On the Olares it sits behind a `private`
    /// entrance (Olares login), so it takes no bearer token. Nil = no dashboard.
    public var dashboardPort: Int?
    /// Required on every /v1 request as `Authorization: Bearer <token>`. Unset only for local dev.
    public var apiToken: String?
    /// Browser origins allowed to make state-changing requests (the iPhone app sends no Origin).
    public var allowedOrigins: [String] = []
    /// Nil: in-memory store (dev and tests).
    public var database: Database?
    /// Base64 of 32 random bytes; seals provider access tokens at rest.
    public var tokenKey: String?
    public var modelBaseURL: URL?
    /// Sent as a bearer token to the chat model (a router like LiteLLM or switchboard asks for one).
    public var modelAPIKey: String?
    public var modelName = "qwen3.8-27b"
    public var decisionBaseURL: URL?
    public var decisionAPIKey: String?
    public var openRouterKey: String?
    public var openRouterZeroRetention = false
    public var plaid: Plaid?
    public var teller: Teller?
    public var tellerApplicationID: String?
    public var tellerEnvironment = "development"
    public var syncIntervalHours = 6.0
    public var timeZone = TimeZone(identifier: "America/Los_Angeles")!
    /// Seed the demo ledger when the database is empty — for testing the app against a real server.
    public var seedDemo = false
    /// Whether the demo ledger may be loaded at all (BUDGET_ALLOW_DEMO). Off on a real server: the demo
    /// belongs to the simulator and to local test servers, never next to real accounts.
    public var allowDemo = false
    public var publicURL: String?
    /// The dashboard's address as the phone should open it (BUDGET_DASHBOARD_URL).
    public var dashboardURL: String?
    /// APNs token auth for the morning summary: the .p8 key's text, its key id, the team and the app's bundle id.
    public var apnsKey: String?
    public var apnsKeyID: String?
    public var apnsTeamID: String?
    public var apnsTopic: String?
    /// Card bills from Plaid Liabilities (BUDGET_PLAID_LIABILITIES). Off unless set: Plaid bills each Item once it's used.
    public var plaidLiabilities = false
    /// Investment holdings (BUDGET_PLAID_HOLDINGS): auto, on or off; 1/true read as on, 0/false as off.
    public var plaidHoldings = "auto"
    /// Plaid webhooks (BUDGET_PLAID_WEBHOOKS), on unless set to 0/false/no. They also need `publicURL`.
    public var plaidWebhooks = true
    /// SimpleFIN pulls a day on the server's own initiative (BUDGET_SIMPLEFIN_DAILY_PULLS).
    public var simplefinDailyPulls = 4.0
    /// Where a bank app returns the phone after OAuth (PLAID_MOBILE_REDIRECT_URI); nil means `<publicURL>/plaid/oauth-return`,
    /// "off" means none.
    public var plaidMobileRedirectURI: String?
    /// The app's id for Universal Links, `<TEAMID>.<bundle id>` (BUDGET_IOS_APP_ID).
    public var iosAppID: String?

    /// Which variables were actually set (so the dashboard can tell "environment" from "default").
    public var environmentKeys: Set<String> = []

    public init() {}

    public enum ConfigError: Error, CustomStringConvertible {
        case invalid(String)
        public var description: String { switch self { case let .invalid(m): m } }
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> ServerConfig {
        func value(_ key: String) -> String? { env[key].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        var c = ServerConfig()
        c.environmentKeys = Set(env.keys.filter { value($0) != nil })
        c.host = value("HOST") ?? c.host
        if let p = value("PORT") { guard let port = Int(p) else { throw ConfigError.invalid("PORT must be a number") }; c.port = port }
        if let p = value("DASHBOARD_PORT") {
            guard let port = Int(p) else { throw ConfigError.invalid("DASHBOARD_PORT must be a number") }
            c.dashboardPort = port
        }
        c.apiToken = value("BUDGET_API_TOKEN")
        c.allowedOrigins = value("BUDGET_ALLOWED_ORIGINS")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        if let host = value("POSTGRES_HOST") {
            c.database = Database(host: host, port: Int(value("POSTGRES_PORT") ?? "5432") ?? 5432,
                                  username: value("POSTGRES_USER") ?? "budget", password: value("POSTGRES_PASSWORD"),
                                  database: value("POSTGRES_DB") ?? "budget")
        }
        c.tokenKey = value("BUDGET_TOKEN_KEY")
        c.modelBaseURL = value("MODEL_BASE_URL").flatMap(URL.init(string:))
        c.modelAPIKey = value("MODEL_API_KEY")
        c.modelName = value("MODEL_NAME") ?? c.modelName
        c.decisionBaseURL = value("DECISION_BASE_URL").flatMap(URL.init(string:)) ?? c.modelBaseURL
        c.decisionAPIKey = value("DECISION_API_KEY")
        c.openRouterKey = value("OPENROUTER_API_KEY")
        c.openRouterZeroRetention = value("OPENROUTER_ZDR") == "1"
        if let id = value("PLAID_CLIENT_ID"), let secret = value("PLAID_SECRET") {
            guard let environment = PlaidSource.Environment(rawValue: value("PLAID_ENV") ?? "sandbox") else {
                throw ConfigError.invalid("PLAID_ENV must be sandbox or production")
            }
            c.plaid = Plaid(clientID: id, secret: secret, environment: environment, redirectURI: value("PLAID_REDIRECT_URI"))
        }
        if let cert = value("TELLER_CERT_PATH"), let key = value("TELLER_KEY_PATH") {
            c.teller = Teller(certificatePath: cert, keyPath: key)
        }
        c.tellerApplicationID = value("TELLER_APPLICATION_ID")
        c.tellerEnvironment = value("TELLER_ENV") ?? c.tellerEnvironment
        if let h = value("BUDGET_SYNC_INTERVAL_HOURS") { c.syncIntervalHours = Double(h) ?? c.syncIntervalHours }
        if let tz = value("BUDGET_TIMEZONE") {
            guard let zone = TimeZone(identifier: tz) else { throw ConfigError.invalid("Unknown BUDGET_TIMEZONE \(tz)") }
            c.timeZone = zone
        }
        c.allowDemo = ["1", "true", "yes"].contains(value("BUDGET_ALLOW_DEMO")?.lowercased() ?? "")
        // Seeding needs the allowance too, so the Olares app setting can't put demo money on the real server.
        c.seedDemo = c.allowDemo && ["1", "true", "yes"].contains(value("BUDGET_SEED_DEMO")?.lowercased() ?? "")
        c.publicURL = value("BUDGET_PUBLIC_URL").map(Self.withoutTrailingSlash)
        c.dashboardURL = value("BUDGET_DASHBOARD_URL")
        c.apnsKey = value("APNS_KEY")
        c.apnsKeyID = value("APNS_KEY_ID")
        c.apnsTeamID = value("APNS_TEAM_ID")
        c.apnsTopic = value("APNS_TOPIC")
        c.plaidLiabilities = ["1", "true", "yes"].contains(value("BUDGET_PLAID_LIABILITIES")?.lowercased() ?? "")
        if let holdings = value("BUDGET_PLAID_HOLDINGS") {
            let mode = HoldingsMode.synonym(holdings.lowercased())
            guard HoldingsMode(rawValue: mode) != nil else { throw ConfigError.invalid("BUDGET_PLAID_HOLDINGS must be auto, on or off") }
            c.plaidHoldings = mode
        }
        c.plaidWebhooks = !["0", "false", "no"].contains(value("BUDGET_PLAID_WEBHOOKS")?.lowercased() ?? "")
        if let pulls = value("BUDGET_SIMPLEFIN_DAILY_PULLS") {
            guard let n = Double(pulls), (1...20).contains(n) else { throw ConfigError.invalid("BUDGET_SIMPLEFIN_DAILY_PULLS must be a number from 1 to 20") }
            c.simplefinDailyPulls = n
        }
        c.plaidMobileRedirectURI = value("PLAID_MOBILE_REDIRECT_URI")
        c.iosAppID = value("BUDGET_IOS_APP_ID")
        return c
    }

    static func withoutTrailingSlash(_ url: String) -> String {
        var url = url
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// `url` as a base providers call back: no trailing slash, https only (http too when `allowHTTP`, for a sandbox
    /// test server). Nil when it isn't one.
    static func normalizedPublicURL(_ url: String?, allowHTTP: Bool) -> String? {
        guard let url, !url.isEmpty else { return nil }
        let base = withoutTrailingSlash(url)
        guard let parsed = URL(string: base), parsed.host != nil,
              parsed.scheme == "https" || (allowHTTP && parsed.scheme == "http") else { return nil }
        return base
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
