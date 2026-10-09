import BudgetKit
@testable import BudgetServerCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Testing

@Suite("Plan scenarios and cash flow over HTTP")
struct PlanRouteTests {
    static func decode<T: Decodable>(_ type: T.Type, _ buffer: ByteBuffer) throws -> T {
        try RemoteBudgetAPI.decoder.decode(T.self, from: Data(buffer.readableBytesView))
    }

    @Test("The app's client reads scenarios, projects against one, and reads the month's flow; its writes are actions")
    func parity() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let list = try await remote.scenarios(horizonMonths: 6)
            #expect(list.horizonMonths == 6 && list.scenarios.map(\.id) == ["scn-car", "scn-bonus", "scn-move"])
            let plain = try await remote.projection(horizonMonths: 6, goal: nil)
            #expect(list.baselineEnd == plain.endBalance)

            let car = try await remote.projection(horizonMonths: 6, goal: nil, scenarioID: "scn-car")
            #expect(car.scenarioName == "New car" && car.baselineEndBalance == plain.endBalance)
            #expect(car.endBalance == list.outcome(for: "scn-car")?.endBalance)
            await #expect(throws: BudgetAPIError.notFound) { try await remote.projection(horizonMonths: 6, goal: nil, scenarioID: "missing") }

            let added = try await remote.perform(.savePlanScenario(SavePlanScenario(scenarioID: "trip", name: "Trip", events: [
                .init(name: "Flights", kind: .expense, amount: DecimalAmount(string: "900")!, startMonth: PlanMonth.adding(2, to: PlanMonth.key(for: Date()))!, cadence: .once),
            ])))
            #expect(added.message == "Added “Trip”.")
            #expect(try await remote.scenarios(horizonMonths: 6).outcome(for: "trip")?.effect == Money(-900))
            _ = try await remote.perform(try #require(added.undo))
            #expect(try await remote.scenarios(horizonMonths: 6).scenarios.count == 3)

            let flow = try await remote.cashFlowSankey(month: nil)
            #expect(flow.isPartial && flow.nodes.contains { $0.kind == .bucket })
            let budget = try await remote.budget(month: nil)
            for group in budget.groups where group.spent.minorUnits > 0 {
                #expect(flow.node("bucket-\(group.group.rawValue)")?.value == group.spent)
            }
            await #expect(throws: BudgetAPIError.rejected("A month is written like 2026-09.")) { try await remote.cashFlowSankey(month: "soon") }
        }
    }

    @Test("Scenarios are a CRUD resource: create, read, replace, delete")
    func crud() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.router) { client in
            let body = #"{"name":"Side job","events":[{"name":"Weekend shifts","kind":"income","amount":"400","startMonth":"2030-01","cadence":"monthly"}]}"#
            var id = ""
            try await client.execute(uri: "/v1/scenarios", method: .post, headers: TestServer.auth, body: TestServer.body(body)) { response in
                #expect(response.status == .created)
                let scenario = try Self.decode(PlanScenario.self, response.body)
                #expect(scenario.name == "Side job" && scenario.events.first?.amount == Money(400) && scenario.id.hasPrefix("scn-"))
                id = scenario.id
            }
            try await client.execute(uri: "/v1/scenarios/\(id)", method: .get, headers: TestServer.auth) { response in
                let scenario = try Self.decode(PlanScenario.self, response.body)
                #expect(scenario.events.count == 1)
            }
            // Creating one with an id that's there is refused; PUT changes it.
            try await client.execute(uri: "/v1/scenarios", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"scenarioID":"\#(id)","name":"Again"}"#)) { #expect($0.status == .unprocessableContent) }
            try await client.execute(uri: "/v1/scenarios/\(id)", method: .put, headers: TestServer.auth,
                                     body: TestServer.body(#"{"name":"Side job, less","events":[]}"#)) { response in
                #expect(response.status == .ok)
                let scenario = try Self.decode(PlanScenario.self, response.body)
                #expect(scenario.id == id && scenario.name == "Side job, less" && scenario.events.isEmpty)
            }
            try await client.execute(uri: "/v1/scenarios/\(id)", method: .put, headers: TestServer.auth,
                                     body: TestServer.body(#"{"name":"Bad","events":[{"name":"X","kind":"income","amount":"0","startMonth":"2030-01","cadence":"once"}]}"#)) {
                #expect($0.status == .unprocessableContent)
            }
            try await client.execute(uri: "/v1/scenarios?horizonMonths=40", method: .get, headers: TestServer.auth) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/v1/scenarios/\(id)", method: .delete, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let result = try Self.decode(ActionResult.self, response.body)
                #expect(result.message == "Deleted “Side job, less”.")
            }
            try await client.execute(uri: "/v1/scenarios/\(id)", method: .get, headers: TestServer.auth) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/scenarios/\(id)", method: .delete, headers: TestServer.auth) { #expect($0.status == .notFound) }
            // A cross-site page can't write.
            var evil = TestServer.auth
            evil[.origin] = "https://evil.example"
            try await client.execute(uri: "/v1/scenarios", method: .post, headers: evil, body: TestServer.body(body)) { #expect($0.status == .forbidden) }
        }
    }

    @Test("The dashboard reads the month's flow without a token")
    func dashboardFlow() async throws {
        let (app, _) = try await TestServer.app(surface: .dashboard)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/flow", method: .get) { response in
                #expect(response.status == .ok)
                let flow = try Self.decode(CashFlowSankey.self, response.body)
                let total = flow.income + flow.drawnFromCash
                #expect(flow.nodes.filter { $0.column == 1 }.map(\.value).sum() == total)
            }
        }
    }
}
