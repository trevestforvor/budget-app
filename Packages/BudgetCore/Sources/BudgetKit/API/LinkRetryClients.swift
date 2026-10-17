import Foundation

/// "Try again" for one link (`POST /v1/links/:id/sync`): after the person fixed a bank's sign-in at the provider's own
/// site (SimpleFIN Bridge). The demo ledger doesn't conform; the app checks `api as? any LinkRetryAPI`.
public protocol LinkRetryAPI: Sendable {
    func syncLink(id: String) async throws -> LinkSyncResult
}

extension RemoteBudgetAPI: LinkRetryAPI {
    public func syncLink(id: String) async throws -> LinkSyncResult {
        struct Empty: Encodable {}
        return try await send("POST", "v1/links", id: id, then: "sync", body: Empty())
    }
}

/// A sync is live: never from the saved copy.
extension CachingBudgetAPI: LinkRetryAPI {
    public func syncLink(id: String) async throws -> LinkSyncResult {
        guard let api = upstream as? any LinkRetryAPI else { throw BudgetAPIError.notFound }
        return try await api.syncLink(id: id)
    }
}

extension InstitutionLink {
    /// The only host the app opens a provider's sign-in page on.
    public static let simplefinBridgeHost = "beta-bridge.simplefin.org"

    /// Where this row's bank is signed in again, for a row that says so (`reconnect == .providerSite`): only an https
    /// address on SimpleFIN Bridge, so a tampered answer can't open some other page inside the app.
    public var providerSiteURL: URL? {
        guard reconnect == .providerSite, let text = reconnectURL, let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https", components.host?.lowercased() == Self.simplefinBridgeHost,
              components.user == nil, components.password == nil, components.port == nil || components.port == 443 else { return nil }
        return components.url
    }

    /// The link a "Try again" syncs: the whole link when this row is one bank of it.
    public var retryLinkID: String { syncLinkID ?? id }
}
