import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Testing

/// P1.3 review fixes over HTTP: the dashboard can tell which imports have rows to bring back, and Bring back says what
/// it filed.
@Suite("Merge counts and Bring back results")
struct MergeCountsRouteTests {
    typealias Base = MergeRouteTests

    @Test("Open merge-log entries are counted per batch on the dashboard only, and Bring back reports what it filed")
    func countsAndResults() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false)
        let dash = Application(router: buildRouter(service, surface: .dashboard))
        let accountID = try await Base.seed(service)
        let batch = try await app.test(.router) { client -> String in
            let record = try await Base.importStatement(accountID, client)
            try await client.execute(uri: "/v1/merges/by-batch", method: .get, headers: TestServer.auth) { #expect($0.status == .notFound) }
            return record.batchID
        }
        let flagged = try #require(await service.api.possibleDuplicates().first)
        _ = try await service.api.resolveDuplicate(rowID: flagged.id, sameAs: flagged.candidates[0].id)
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/merges/by-batch", method: .get) { response in
                #expect(response.status == .ok)
                let counts = try Base.decode([String: Int].self, response)
                #expect(counts == [batch: 2])
            }
            try await client.execute(uri: "/v1/imports/\(batch)/merges/undo", method: .post, headers: Base.dashWrite) { response in
                #expect(response.status == .ok)
                let result = try Base.decode(MergeUndoResult.self, response)
                #expect(result.restored == 1 && result.filed + result.toReview + result.waiting == 1)
            }
            try await client.execute(uri: "/v1/merges/by-batch", method: .get) { response in
                let counts = try Base.decode([String: Int].self, response)
                #expect(counts == [batch: 1])
            }
        }
    }
}
