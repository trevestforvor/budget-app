import BudgetKit
import Foundation
import Hummingbird
import HTTPTypes
import NIOCore

/// `POST /v1/links/:id/reconnect` and `GET /v1/links/:id/reconnect/:session`: signing in to a bank again from the phone
/// (`ReconnectSessions`). Both answer `Cache-Control: no-store`: the start carries Plaid's hosted URL, which no cache keeps.
/// The routes build their errors themselves, so nothing about a session reaches `ErrorMiddleware`'s log.
func addReconnectRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    router.post("/v1/links/:id/reconnect") { _, context in
        let linkID = try HTTP.rowID(context)
        return try await reconnectResponse(status: .created) { try await service.reconnects.start(linkID: linkID) }
    }
    router.get("/v1/links/:id/reconnect/:session") { _, context in
        let linkID = try HTTP.rowID(context)
        let session = try context.parameters.require("session")
        return try await reconnectResponse(status: .ok) { try await service.reconnects.status(linkID: linkID, session: session) }
    }
}

/// The session as JSON, or the refusal as `{"error", "errorKind"}` with its status; either way never stored by a cache.
private func reconnectResponse(status: HTTPResponse.Status, _ work: () async throws -> ReconnectSession) async throws -> Response {
    var response: Response
    do {
        response = try HTTP.json(try await work(), status: status)
    } catch let refused as ReconnectError {
        var body = ["error": refused.message]
        if let kind = refused.kind { body["errorKind"] = kind.rawValue }
        let data = (try? JSONEncoder().encode(body)) ?? Data()
        response = Response(status: HTTPResponse.Status(code: refused.status), headers: [.contentType: "application/json"],
                            body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
    response.headers[.cacheControl] = "no-store"
    return response
}

extension ReconnectMethod {
    /// How the person repairs `link`. A Plaid link with a live Item signs in again from the phone (`.phone`) when this
    /// install can, else on the dashboard; one whose Item Plaid deleted, or whose access was withdrawn, can only be
    /// linked again (`.newLink`). SimpleFIN at the Bridge; everything else on the dashboard.
    static func `for`(_ link: StoredLink, phoneCapable: Bool) -> ReconnectMethod {
        switch link.provider {
        case .simplefin: return .providerSite
        case .plaid:
            // Withdrawn access (USER_PERMISSION_REVOKED keeps the token) isn't update mode's to repair: Plaid's answer
            // is removing the Item and linking again, and the reconnect route refuses it.
            if !link.hasLiveItem || link.errorKind == .revoked { return .newLink }
            return phoneCapable ? .phone : .dashboard
        default: return .dashboard
        }
    }

    /// Whether this install can repair a Plaid link from the phone at all: Plaid set up, a public URL and a
    /// `BUDGET_TOKEN_KEY` to open the saved sign-in, plus a redirect for the link token: the mobile one
    /// (`PLAID_MOBILE_REDIRECT_URI` not `off`), or in the sandbox the dashboard's (`PLAID_REDIRECT_URI`).
    static func phoneCapable(settings: ServerSettings, providers: Providers, sealer: TokenSealer?) async -> Bool {
        guard sealer != nil, let plaid = try? await providers.plaid() else { return false }
        let sandbox = plaid.environment == .sandbox
        guard await settings.providerCallbackBase(sandbox: sandbox) != nil else { return false }
        if await settings.plaidMobileRedirectURI(sandbox: sandbox) != nil { return true }
        return sandbox && !(plaid.redirectURI ?? "").isEmpty
    }
}
