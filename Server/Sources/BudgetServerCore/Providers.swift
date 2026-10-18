import BudgetKit
import Foundation

/// Provider credentials saved from the dashboard. Plaid's secret is sealed with BUDGET_TOKEN_KEY like access tokens.
/// Settings saved before 0.6.0 may also hold a `teller` entry; decoding skips it (Teller is gone, SPEC §10), and the next
/// save drops it.
public struct StoredProviderSettings: Codable, Hashable, Sendable {
    public struct Plaid: Codable, Hashable, Sendable {
        public var clientID: String
        public var sealedSecret: String
        /// `PlaidSource.Environment` raw value.
        public var environment: String
        public var redirectURI: String?
    }
    public var plaid: Plaid?
    public var updatedAt: Date

    public init(plaid: Plaid? = nil, updatedAt: Date = Date()) {
        self.plaid = plaid
        self.updatedAt = updatedAt
    }
}

/// What the dashboard may show about providers — never a secret.
public struct ProviderSummary: Codable, Sendable {
    public enum Origin: String, Codable, Sendable { case none, environment, dashboard }
    public struct Plaid: Codable, Sendable {
        public var origin: Origin
        /// Plaid's client_id identifies the app, it isn't a credential (the secret is).
        public var clientID: String?
        public var clientIDHint: String?
        public var environment: String?
        public var redirectURI: String?
    }
    public var plaid: Plaid
    public var sealingAvailable: Bool
}

/// Plaid's return address for banks that sign in on their own site (OAuth) in the dashboard's web Link: the Keys form's
/// field, or `PLAID_REDIRECT_URI`. It's optional. Desktop web Link opens the bank's sign-in in a pop-up whether or not a
/// redirect_uri is sent (https://plaid.com/docs/link/oauth/), so a computer install (a plain http dashboard on this
/// machine) sends none. Only a dashboard with an https address and a real name (Olares, a tunnel) can take a bank back,
/// and then Plaid must list the exact address under Allowed redirect URIs (https://dashboard.plaid.com/developers/api).
public enum PlaidRedirect {
    /// Where the person registers return addresses with Plaid.
    public static let plaidPage = "https://dashboard.plaid.com/developers/api"

    /// Whether a host (a bare name, or an authority with a port) is this computer's own: `localhost`, `*.localhost`,
    /// 127.x, `::1` or `0.0.0.0`. No bank can be sent back to one.
    public static func isLocalHost(_ host: String) -> Bool {
        var name = host.lowercased().trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("[") {
            name = String(name.dropFirst().prefix { $0 != "]" })
        } else if name.filter({ $0 == ":" }).count == 1 {
            name = String(name.prefix { $0 != ":" })
        }
        if name.hasSuffix(".") { name.removeLast() }
        return name == "localhost" || name.hasSuffix(".localhost") || name.hasPrefix("127.") || name == "::1" || name == "0.0.0.0"
    }

    /// The address as one Plaid can send a bank back to, or nil: empty, not https, or on this computer's own name. A value
    /// saved before 0.6.2 (the dashboard used to pre-fill `https://budget.localhost:8081/`) is dropped here, so Link opens
    /// without it instead of Plaid refusing every link token.
    public static func usable(_ uri: String?) -> String? {
        guard let uri = uri?.trimmingCharacters(in: .whitespacesAndNewlines), !uri.isEmpty, uri.lowercased().hasPrefix("https://"),
              let host = URL(string: uri)?.host(), !isLocalHost(host) else { return nil }
        return uri
    }

    /// What the dashboard suggests for the field: its own address, only when the browser reached it at a real name over
    /// https. A proxy's `X-Forwarded-Proto` decides when it's sent; without one, a name (not an IP address) that isn't
    /// this computer's counts, since the dashboard itself listens only on loopback and a real name means a proxy in
    /// front (the Olares entrance). A computer install's dashboard is plain http on this machine: nil, and the field
    /// stays empty.
    public static func suggestion(forwardedProto: String?, forwardedHost: String?, host: String?) -> String? {
        let proto = forwardedProto?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let name = (forwardedHost ?? host)?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !isLocalHost(name) else { return nil }
        switch proto {
        case "https": return "https://\(name)/"
        case nil: return isAddressLiteral(name) ? nil : "https://\(name)/"
        default: return nil
        }
    }

    /// Whether Plaid turned a link token down over its return address: INVALID_FIELD naming the redirect (or naming no
    /// field at all). Branches on Plaid's code; the message only narrows which field.
    static func refusedReturnAddress(_ error: any Error) -> Bool {
        guard let plaid = PlaidErrors.plaidError(error), plaid.errorCode == "INVALID_FIELD" else { return false }
        guard let message = plaid.errorMessage?.lowercased() else { return true }
        return message.contains("redirect")
    }

    /// The dashboard's sentence for that refusal, said in place of "Plaid turned the keys down".
    static func unknownAddress(_ redirect: String) -> BudgetAPIError {
        .rejected("Plaid doesn't know the return address \(redirect). Add it under Allowed redirect URIs at \(plaidPage), or clear the field.")
    }

    /// An IPv4 or IPv6 literal, with or without a port.
    static func isAddressLiteral(_ authority: String) -> Bool {
        if authority.hasPrefix("[") || authority.filter({ $0 == ":" }).count > 1 { return true }
        let name = authority.prefix { $0 != ":" }
        return !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." }
    }
}

/// The providers the server can use right now: dashboard settings over environment ones, rebuilt
/// whenever the dashboard saves. Routes and sync ask this instead of reading startup config.
public actor Providers {
    private let store: any ServerStore
    private let sealer: TokenSealer?
    private let envPlaid: ServerConfig.Plaid?
    /// HTTPS for providers; injectable for tests.
    public nonisolated let transport: any HTTPTransport
    private var saved: StoredProviderSettings?

    public init(config: ServerConfig, store: any ServerStore, sealer: TokenSealer?, transport: any HTTPTransport) {
        self.store = store
        self.sealer = sealer
        self.transport = transport
        envPlaid = config.plaid
    }

    public func load() async throws {
        saved = try await store.providerSettings()
    }

    // MARK: What routes and sync use

    public func plaid() throws -> ServerConfig.Plaid? {
        if let p = saved?.plaid {
            guard let sealer else { throw BudgetAPIError.rejected("BUDGET_TOKEN_KEY isn't set; can't open the saved Plaid secret.") }
            return ServerConfig.Plaid(clientID: p.clientID, secret: try sealer.open(p.sealedSecret),
                                      environment: PlaidSource.Environment(rawValue: p.environment) ?? .sandbox, redirectURI: PlaidRedirect.usable(p.redirectURI))
        }
        guard var env = envPlaid else { return nil }
        env.redirectURI = PlaidRedirect.usable(env.redirectURI)
        return env
    }

    public func sources() -> [SourceKind] {
        [(try? plaid()) != nil ? .plaid : nil, .simplefin, .fileImport].compactMap { $0 }
    }

    public func summary() -> ProviderSummary {
        let plaidOrigin: ProviderSummary.Origin = saved?.plaid != nil ? .dashboard : envPlaid != nil ? .environment : .none
        let clientID = saved?.plaid?.clientID ?? envPlaid?.clientID
        return ProviderSummary(
            plaid: .init(origin: plaidOrigin, clientID: clientID, clientIDHint: clientID.map { "…" + $0.suffix(4) },
                         environment: saved?.plaid?.environment ?? envPlaid?.environment.rawValue,
                         redirectURI: PlaidRedirect.usable(saved?.plaid != nil ? saved?.plaid?.redirectURI : envPlaid?.redirectURI)),
            sealingAvailable: sealer != nil)
    }

    // MARK: Saving from the dashboard

    /// `secret` nil keeps the saved one (so the environment or redirect can change alone).
    public func savePlaid(clientID: String, secret: String?, environment: PlaidSource.Environment, redirectURI: String?) async throws {
        let sealer = try requireSealer()
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw BudgetAPIError.rejected("Enter Plaid's client_id.") }
        // Plaid's ids are hex: client_id is 24 characters, secrets 30. Catch password-manager fills and
        // swapped fields here rather than as Plaid's terse INVALID_FIELD later.
        guard clientID.count == 24, clientID.allSatisfy(\.isHexDigit) else {
            throw BudgetAPIError.rejected("That isn't a Plaid client_id. It's 24 characters of 0–9 and a–f, at https://dashboard.plaid.com/developers/keys. (\(clientID.count) characters were entered; a password manager may have filled the field.)")
        }
        let sealed: String
        if let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            guard (20...64).contains(secret.count), secret.allSatisfy(\.isHexDigit) else {
                throw BudgetAPIError.rejected("That isn't a Plaid secret. It's about 30 characters of 0–9 and a–f, next to the client_id (use the one for \(environment.rawValue)). (\(secret.count) characters were entered.)")
            }
            sealed = try sealer.seal(secret)
        } else if let existing = saved?.plaid?.sealedSecret {
            sealed = existing
        } else {
            throw BudgetAPIError.rejected("Enter Plaid's secret for the \(environment.rawValue) environment.")
        }
        let redirect = redirectURI?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let redirect, !redirect.isEmpty {
            guard redirect.lowercased().hasPrefix("https://"), let host = URL(string: redirect)?.host(), !host.isEmpty else {
                throw BudgetAPIError.rejected("Plaid only accepts an https:// return address. Leave the field empty unless this dashboard has an https address.")
            }
            guard !PlaidRedirect.isLocalHost(host) else {
                throw BudgetAPIError.rejected("\(host) is this computer's own name, so a bank can't come back to it. Leave the return address empty: on a computer install, banks like Chase open their sign-in in a pop-up.")
            }
        }
        var next = saved ?? StoredProviderSettings()
        next.plaid = .init(clientID: clientID, sealedSecret: sealed, environment: environment.rawValue, redirectURI: redirect?.isEmpty == false ? redirect : nil)
        try await persist(next)
    }

    public func clearPlaid() async throws {
        guard var next = saved else { return }
        next.plaid = nil
        try await persist(next)
    }

    // MARK: Internals

    private func persist(_ next: StoredProviderSettings) async throws {
        var next = next
        next.updatedAt = Date()
        try await store.saveProviderSettings(next)
        saved = next
    }

    private func requireSealer() throws -> TokenSealer {
        guard let sealer else { throw BudgetAPIError.rejected("Set BUDGET_TOKEN_KEY on the server before saving provider keys.") }
        return sealer
    }
}
