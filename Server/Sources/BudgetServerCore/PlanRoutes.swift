import BudgetKit
import Foundation
import Hummingbird

/// Plan scenarios and the month's cash flow (docs/API.md §Plan scenarios, §Cash flow). Every write is the matching
/// `AppAction`, so a change made here has the same checks and undo as one made on the phone.
func addPlanRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    let api = service.api

    /// `?horizonMonths=12` (the default), 1 to 36.
    router.get("/v1/scenarios") { request, _ in
        let horizon = try request.uri.queryParameters.get("horizonMonths").map { raw in
            guard let n = Int(raw), (1...36).contains(n) else { throw BudgetAPIError.decoding("horizonMonths must be a whole number from 1 to 36, got “\(raw)”") }
            return n
        } ?? 12
        return try HTTP.json(try await api.scenarios(horizonMonths: horizon))
    }
    router.get("/v1/scenarios/:id") { _, context in try HTTP.json(try await api.scenario(id: try HTTP.rowID(context))) }
    /// A new scenario: the body is `SavePlanScenario`; an id given must be new.
    router.post("/v1/scenarios") { request, _ in
        var body = try await HTTP.body(SavePlanScenario.self, request)
        let id = body.scenarioID ?? PlanScenario.newID()
        if (try? await api.scenario(id: id)) != nil { throw BudgetAPIError.rejected("There's already a scenario \(id); change it with PUT.") }
        body.scenarioID = id
        _ = try await api.perform(.savePlanScenario(body))
        return try HTTP.json(try await api.scenario(id: id), status: .created)
    }
    /// Replaces a scenario's name and changes whole (or creates it with this id).
    router.put("/v1/scenarios/:id") { request, context in
        let id = try HTTP.rowID(context)
        var body = try await HTTP.body(SavePlanScenario.self, request)
        body.scenarioID = id
        _ = try await api.perform(.savePlanScenario(body))
        return try HTTP.json(try await api.scenario(id: id))
    }
    router.delete("/v1/scenarios/:id") { _, context in
        try HTTP.json(try await api.perform(.deletePlanScenario(DeletePlanScenario(scenarioID: try HTTP.rowID(context)))))
    }

    /// `?month=2026-09`; without one, this month so far.
    router.get("/v1/flow") { request, _ in try HTTP.json(try await api.cashFlowSankey(month: request.uri.queryParameters.get("month"))) }
}
