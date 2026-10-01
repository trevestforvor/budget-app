import BudgetKit
import Foundation
import NIOSSL

/// Provider credentials saved from the dashboard. Secrets (Plaid's secret, Teller's private key) are
/// sealed with BUDGET_TOKEN_KEY like access tokens; Teller's certificate is public and kept plain.
public struct StoredProviderSettings: Codable, Hashable, Sendable {
    public struct Plaid: Codable, Hashable, Sendable {
        public var clientID: String
        public var sealedSecret: String
        /// `PlaidSource.Environment` raw value.
        public var environment: String
        public var redirectURI: String?
    }
    public struct Teller: Codable, Hashable, Sendable {
        public var applicationID: String
        public var environment: String
        public var certificatePEM: String?
        public var sealedKeyPEM: String?
    }
    public var plaid: Plaid?
    public var teller: Teller?
    public var updatedAt: Date

    public init(plaid: Plaid? = nil, teller: Teller? = nil, updatedAt: Date = Date()) {
        self.plaid = plaid
        self.teller = teller
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
    public struct Teller: Codable, Sendable {
        public var origin: Origin
        public var applicationID: String?
        public var environment: String?
        public var hasCertificate: Bool
    }
    public var plaid: Plaid
    public var teller: Teller
    public var sealingAvailable: Bool
}

/// The providers the server can use right now: dashboard settings over environment ones, rebuilt
/// whenever the dashboard saves. Routes and sync ask this instead of reading startup config.
public actor Providers {
    public struct TellerAccess: Sendable {
        public var transport: any HTTPTransport
        public var applicationID: String?
        public var environment: String
        public var hasCertificate: Bool
    }

    private let store: any ServerStore
    private let sealer: TokenSealer?
    private let envPlaid: ServerConfig.Plaid?
    private let envTeller: (transport: any HTTPTransport, applicationID: String?, environment: String)?
    /// Plain HTTPS for providers (Plaid, Teller sandbox); injectable for tests.
    public nonisolated let transport: any HTTPTransport
    private var saved: StoredProviderSettings?
    private var dashboardTellerTransport: (any HTTPTransport)?
    /// HTTP clients from replaced certificates. AsyncHTTPClient must not deinit a running client, and
    /// credentials change rarely, so old ones are kept rather than shut down under an in-flight sync.
    private var retired: [any HTTPTransport] = []

    public init(config: ServerConfig, store: any ServerStore, sealer: TokenSealer?, transport: any HTTPTransport,
                envTellerTransport: (any HTTPTransport)?) {
        self.store = store
        self.sealer = sealer
        self.transport = transport
        envPlaid = config.plaid
        envTeller = envTellerTransport.map { ($0, config.tellerApplicationID, config.tellerEnvironment) }
    }

    public func load() async throws {
        saved = try await store.providerSettings()
        try rebuildTeller()
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

    /// Teller without a certificate is the sandbox: its tokens work over plain HTTPS.
    public func teller() -> TellerAccess? {
        if let t = saved?.teller {
            return TellerAccess(transport: dashboardTellerTransport ?? transport, applicationID: t.applicationID, environment: t.environment,
                                hasCertificate: dashboardTellerTransport != nil)
        }
        if let envTeller { return TellerAccess(transport: envTeller.transport, applicationID: envTeller.applicationID, environment: envTeller.environment, hasCertificate: true) }
        return nil
    }

    public func sources() -> [SourceKind] {
        [(try? plaid()) != nil ? .plaid : nil, teller() != nil ? .teller : nil, .simplefin, .fileImport].compactMap { $0 }
    }

    public func summary() -> ProviderSummary {
        let plaidOrigin: ProviderSummary.Origin = saved?.plaid != nil ? .dashboard : envPlaid != nil ? .environment : .none
        let clientID = saved?.plaid?.clientID ?? envPlaid?.clientID
        let tellerOrigin: ProviderSummary.Origin = saved?.teller != nil ? .dashboard : envTeller != nil ? .environment : .none
        let access = teller()
        return ProviderSummary(
            plaid: .init(origin: plaidOrigin, clientID: clientID, clientIDHint: clientID.map { "…" + $0.suffix(4) },
                         environment: saved?.plaid?.environment ?? envPlaid?.environment.rawValue,
                         redirectURI: saved?.plaid?.redirectURI ?? envPlaid?.redirectURI),
            teller: .init(origin: tellerOrigin, applicationID: access?.applicationID, environment: access?.environment,
                          hasCertificate: access?.hasCertificate ?? false),
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

    /// Certificate and key are both needed for development/production; sandbox runs without them.
    /// `keyPEM` nil with a certificate keeps the saved key.
    public func saveTeller(applicationID: String, environment: String, certificatePEM: String?, keyPEM: String?) async throws {
        let sealer = try requireSealer()
        let applicationID = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !applicationID.isEmpty else { throw BudgetAPIError.rejected("Enter Teller's application ID (it starts with app_).") }
        guard ["sandbox", "development", "production"].contains(environment) else { throw BudgetAPIError.rejected("Teller's environment is sandbox, development or production.") }
        let certificate = certificatePEM?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? saved?.teller?.certificatePEM
        var sealedKey = saved?.teller?.sealedKeyPEM
        if let key = keyPEM?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty { sealedKey = try sealer.seal(key) }
        if environment != "sandbox", certificate == nil || sealedKey == nil {
            throw BudgetAPIError.rejected("Teller's \(environment) environment needs the certificate.pem and private_key.pem from teller.zip.")
        }
        if let certificate, let sealedKey {
            _ = try Self.tlsTransport(certificatePEM: certificate, keyPEM: try sealer.open(sealedKey)) // validate before saving
        }
        var next = saved ?? StoredProviderSettings()
        next.teller = .init(applicationID: applicationID, environment: environment, certificatePEM: certificate, sealedKeyPEM: sealedKey)
        try await persist(next)
    }

    public func clearPlaid() async throws {
        guard var next = saved else { return }
        next.plaid = nil
        try await persist(next)
    }

    public func clearTeller() async throws {
        guard var next = saved else { return }
        next.teller = nil
        try await persist(next)
    }

    // MARK: Internals

    private func persist(_ next: StoredProviderSettings) async throws {
        var next = next
        next.updatedAt = Date()
        try await store.saveProviderSettings(next)
        saved = next
        try rebuildTeller()
    }

    private func rebuildTeller() throws {
        if let old = dashboardTellerTransport { retired.append(old) }
        dashboardTellerTransport = nil
        guard let t = saved?.teller, let certificate = t.certificatePEM, let sealedKey = t.sealedKeyPEM, let sealer else { return }
        dashboardTellerTransport = try Self.tlsTransport(certificatePEM: certificate, keyPEM: try sealer.open(sealedKey))
    }

    private func requireSealer() throws -> TokenSealer {
        guard let sealer else { throw BudgetAPIError.rejected("Set BUDGET_TOKEN_KEY on the server before saving provider keys.") }
        return sealer
    }

    static func tlsTransport(certificatePEM: String, keyPEM: String) throws -> AHCTransport {
        do {
            return try AHCTransport.mutualTLS(certificatePEM: certificatePEM, keyPEM: keyPEM)
        } catch {
            throw BudgetAPIError.rejected("Teller's certificate or key didn't parse as PEM: \(error)")
        }
    }

}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
