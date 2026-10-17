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
}
