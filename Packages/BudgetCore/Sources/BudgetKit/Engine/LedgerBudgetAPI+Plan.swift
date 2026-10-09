import Foundation

// Plan scenarios and the month's cash flow over the ledger: the server's routes and the demo both answer from here.
extension LedgerBudgetAPI: PlanScenariosAPI, CashFlowSankeyAPI {
    public func scenarios(horizonMonths: Int) async throws -> ScenarioList {
        tick(); await pause(0.4)
        return ledger.scenarioList(horizonMonths: horizonMonths)
    }

    /// One scenario as stored.
    public func scenario(id: String) async throws -> PlanScenario {
        tick()
        return try ledger.planScenario(id)
    }

    public func projection(horizonMonths: Int, goal: GoalQuery?, scenarioID: String?) async throws -> Projection {
        tick(); await pause()
        let scenario = try scenarioID.map { try ledger.planScenario($0) }
        return ledger.projection(horizonMonths: horizonMonths, goal: goal, scenario: scenario)
    }

    public func cashFlowSankey(month: String?) async throws -> CashFlowSankey {
        tick(); await pause(0.5)
        return try ledger.cashFlowSankey(month: month)
    }
}
