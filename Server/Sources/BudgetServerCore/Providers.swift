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
                                      environment: PlaidSource.Environment(rawValue: p.environment) ?? .sandbox, redirectURI: p.redirectURI)
        }
        return envPlaid
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
                         redirectURI: saved?.plaid?.redirectURI ?? envPlaid?.redirectURI),
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
            throw BudgetAPIError.rejected("That isn't a Plaid client_id — it's 24 characters of 0–9 and a–f, on dashboard.plaid.com → Developers → Keys. (\(clientID.count) characters were entered; a password manager may have filled the field.)")
        }
        let sealed: String
        if let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty {
            guard (20...64).contains(secret.count), secret.allSatisfy(\.isHexDigit) else {
                throw BudgetAPIError.rejected("That isn't a Plaid secret — it's about 30 characters of 0–9 and a–f, next to the client_id (use the one for \(environment.rawValue)). (\(secret.count) characters were entered.)")
            }
            sealed = try sealer.seal(secret)
        } else if let existing = saved?.plaid?.sealedSecret {
            sealed = existing
        } else {
            throw BudgetAPIError.rejected("Enter Plaid's secret for the \(environment.rawValue) environment.")
        }
        let redirect = redirectURI?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let redirect, !redirect.isEmpty, !redirect.hasPrefix("https://") {
            throw BudgetAPIError.rejected("Plaid only accepts an https:// redirect URI.")
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
