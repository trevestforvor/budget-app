import BudgetKit
import Foundation
import Hummingbird

/// `POST /v1/links/:id/reconnect` and `GET /v1/links/:id/reconnect/:session`. Nothing yet.
func addReconnectRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {}

extension ReconnectMethod {
    /// How the person repairs `link`: SimpleFIN at the Bridge; everything else on the dashboard for now.
    static func `for`(_ link: StoredLink, phoneCapable: Bool) -> ReconnectMethod {
        link.provider == .simplefin ? .providerSite : .dashboard
    }

    /// Whether this install can repair a Plaid link from the phone at all: Plaid set up and a public URL, plus a mobile
    /// redirect in production (`PLAID_MOBILE_REDIRECT_URI` not `off`; the sandbox falls back to the dashboard one).
    static func phoneCapable(settings: ServerSettings, providers: Providers) async -> Bool {
        guard let plaid = try? await providers.plaid() else { return false }
        let sandbox = plaid.environment == .sandbox
        guard await settings.providerCallbackBase(sandbox: sandbox) != nil else { return false }
        if sandbox { return true }
        return await settings.plaidMobileRedirectURI(sandbox: sandbox) != nil
    }
}
