import BudgetKit
import Foundation
import Hummingbird

// MARK: - Recurring review and monthly recap (docs/API.md)

func addRecapRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    let api = service.api
    /// "Is this recurring?" and "Did this stop?". Answers go through `POST /v1/actions` (`setRecurring`, `reviewRecurring`).
    router.get("/v1/recurring/review") { _, _ in try HTTP.json(try await api.recurringReview()) }
    /// `?month=2026-08`; without one, last month. Only a finished month.
    router.get("/v1/recap/month") { request, _ in
        try HTTP.json(try await api.monthlyRecap(month: request.uri.queryParameters.get("month")))
    }
}
