import BudgetKit
import Foundation
import Hummingbird

/// `POST /v1/plaid/webhook`, on the API surface only. Public (no bearer token): Plaid's signed JWT is its auth. Not
/// built yet, so it answers 503 and does nothing.
func addPlaidWebhookRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    router.post("/v1/plaid/webhook") { _, _ in
        HTTP.error(.serviceUnavailable, "Plaid webhooks aren't built on this server yet.")
    }
}
