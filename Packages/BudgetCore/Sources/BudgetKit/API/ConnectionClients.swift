import Foundation

/// Signing in to a bank again from the phone (server 0.6.0, Plaid links only): start an update-mode session, then
/// poll it until it's done, exited, failed or expired. The demo ledger doesn't conform; the app checks
/// `api as? any LinkRepairAPI` and `InstitutionLink.reconnect == .phone`.
public protocol LinkRepairAPI: Sendable {
    func startReconnect(linkID: String) async throws -> ReconnectSession
    func reconnectStatus(linkID: String, session: String) async throws -> ReconnectSession
}

extension RemoteBudgetAPI: LinkRepairAPI {
    public func startReconnect(linkID: String) async throws -> ReconnectSession {
        struct Empty: Encodable {}
        return try await send("POST", "v1/links", id: linkID, then: "reconnect", body: Empty())
    }

    public func reconnectStatus(linkID: String, session: String) async throws -> ReconnectSession {
        try await get("v1/links", id: linkID, then: "reconnect/\(session)")
    }
}

/// A session is live state: never from the saved copy.
extension CachingBudgetAPI: LinkRepairAPI {
    public func startReconnect(linkID: String) async throws -> ReconnectSession {
        guard let api = upstream as? any LinkRepairAPI else { throw BudgetAPIError.notFound }
        return try await api.startReconnect(linkID: linkID)
    }

    public func reconnectStatus(linkID: String, session: String) async throws -> ReconnectSession {
        guard let api = upstream as? any LinkRepairAPI else { throw BudgetAPIError.notFound }
        return try await api.reconnectStatus(linkID: linkID, session: session)
    }
}
