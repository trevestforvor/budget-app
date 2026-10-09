import Foundation

// Plan scenarios and the month's cash flow over HTTP (docs/API.md §Plan scenarios, §Cash flow), and through the
// phone's offline copy.

extension RemoteBudgetAPI: PlanScenariosAPI, CashFlowSankeyAPI {
    public func scenarios(horizonMonths: Int) async throws -> ScenarioList {
        try await get("v1/scenarios", query: [URLQueryItem(name: "horizonMonths", value: String(horizonMonths))])
    }

    public func projection(horizonMonths: Int, goal: GoalQuery?, scenarioID: String?) async throws -> Projection {
        struct Body: Encodable { let horizonMonths: Int; let goal: GoalQuery?; let scenarioID: String? }
        return try await send("POST", "v1/projection", body: Body(horizonMonths: horizonMonths, goal: goal, scenarioID: scenarioID))
    }

    public func cashFlowSankey(month: String?) async throws -> CashFlowSankey {
        try await get("v1/flow", query: month.map { [URLQueryItem(name: "month", value: $0)] } ?? [])
    }
}

/// Scenario lists and the flow keep an offline copy; a projection against a scenario is worked out fresh (the plain
/// one is kept by `projection(horizonMonths:goal:)`).
extension CachingBudgetAPI: PlanScenariosAPI, CashFlowSankeyAPI {
    public func scenarios(horizonMonths: Int) async throws -> ScenarioList {
        let api = try plan()
        return try await read(.scenarios(horizonMonths: horizonMonths)) { try await api.scenarios(horizonMonths: horizonMonths) }
    }

    public func projection(horizonMonths: Int, goal: GoalQuery?, scenarioID: String?) async throws -> Projection {
        guard let scenarioID else { return try await projection(horizonMonths: horizonMonths, goal: goal) }
        return try await plan().projection(horizonMonths: horizonMonths, goal: goal, scenarioID: scenarioID)
    }

    public func cashFlowSankey(month: String?) async throws -> CashFlowSankey {
        guard let api = upstream as? any CashFlowSankeyAPI else { throw BudgetAPIError.notFound }
        return try await read(.cashFlowSankey(month: month)) { try await api.cashFlowSankey(month: month) }
    }

    private func plan() throws -> any PlanScenariosAPI {
        guard let api = upstream as? any PlanScenariosAPI else { throw BudgetAPIError.notFound }
        return api
    }
}
