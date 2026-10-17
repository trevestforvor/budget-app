import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Testing

/// P0.4 over HTTP: Undo is refused on a Plaid sync batch (hide instead), needs a yes on a SimpleFIN one whose rows come
/// back, and is unchanged for files.
@Suite("Safe Undo routes")
struct ImportUndoRouteTests {
    static func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try RemoteBudgetAPI.decoder.decode(T.self, from: Data(response.body.readableBytesView))
    }

    static func daysAgo(_ days: Int) -> Date { Date().addingTimeInterval(-Double(days) * 86_400) }

    /// Rows of one checking account, read as SimpleFIN sends them (BudgetKit keeps the snapshot initializers internal),
    /// then labelled as `source` so the ledger stores them as that provider's.
    static func snapshot(_ source: SourceKind, rowsDaysAgo: [Int]) throws -> SourceSnapshot {
        let rows = rowsDaysAgo.enumerated().map { i, days in
            #"{"id": "row-\#(i)", "posted": \#(Int(daysAgo(days).timeIntervalSince1970)), "amount": "-\#(12 + i).00", "description": "CORNER MARKET \#(i)"}"#
        }
        let json = #"{"errors": [], "accounts": [{"id": "acct-1", "name": "Everyday Checking", "org": {"name": "Harbor Bank"}, "currency": "USD", "balance": "2400.00", "balance-date": \#(Int(Date().timeIntervalSince1970)), "transactions": [\#(rows.joined(separator: ", "))]}]}"#
        var snapshot = try SimpleFINSource.parse(Data(json.utf8))
        snapshot.source = source
        return snapshot
    }

    /// A link that synced just now, and one sync batch of it in the ledger and the import history, as a real sync leaves them.
    static func synced(_ source: SourceKind, rowsDaysAgo: [Int], into service: BudgetService) async throws -> ImportRecord {
        let linkID = "\(source.rawValue)-link-1", batchID = "\(source.rawValue)-link-1-1"
        try await service.store.upsertLink(StoredLink(id: linkID, provider: source, institution: "Harbor Bank", externalID: nil, sealedToken: "sealed",
                                                      cursor: nil, status: .connected, lastSync: Date(), lastError: nil, createdAt: Date()))
        let report = try await service.api.ingest(try snapshot(source, rowsDaysAgo: rowsDaysAgo), batchID: batchID)
        let record = ImportRecord(batchID: batchID, kind: .sync, linkID: linkID, label: "Harbor Bank sync", report: report, createdAt: Date(), rolledBack: false)
        try await service.store.upsertImport(record)
        return record
    }

    static func record(_ batchID: String, _ client: some TestClientProtocol) async throws -> ImportRecord {
        try await client.execute(uri: "/v1/imports", method: .get, headers: TestServer.dash) { response in
            try #require(try decode([ImportRecord].self, response).first { $0.batchID == batchID })
        }
    }

    @Test("DELETE on a Plaid sync batch is 409; GET …/undo explains; POST …/hide hides; the record isn't marked undone")
    func plaidRefusedThenHidden() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        let record = try await Self.synced(.plaid, rowsDaysAgo: [1, 3], into: service)
        let batch = record.batchID
        try await app.test(.router) { client in
            #expect(try await Self.record(batch, client).undo?.mode == .refused)
            try await client.execute(uri: "/v1/imports/\(batch)/undo", method: .get, headers: TestServer.dash) { response in
                #expect(response.status == .ok)
                let plan = try Self.decode(RollbackPlan.self, response)
                #expect(plan.verdict == .refuse && plan.rows == 2 && plan.bySource == ["plaid": 2])
                #expect(plan.message.contains("Plaid won't send these rows again"))
            }
            // Refused even with the acknowledgement, and nothing changes.
            for uri in ["/v1/imports/\(batch)", "/v1/imports/\(batch)?acknowledge=returning"] {
                try await client.execute(uri: uri, method: .delete, headers: TestServer.dash) { response in
                    #expect(response.status == .conflict)
                    #expect(String(buffer: response.body).contains("Hide them instead"))
                }
            }
            #expect(try await service.api.transactions(TransactionFilter()).count == 2)
            #expect(try await Self.record(batch, client).rolledBack == false)

            try await client.execute(uri: "/v1/imports/\(batch)/hide", method: .post, headers: TestServer.dash) { response in
                #expect(response.status == .ok)
                let result = try Self.decode(ActionResult.self, response)
                #expect(result.affectedTransactions == 2 && result.undo != nil)
            }
            #expect(try await service.api.transactions(TransactionFilter()).allSatisfy(\.isHidden))
            let hidden = try await Self.record(batch, client)
            #expect(hidden.hiddenAt != nil && hidden.rolledBack == false)

            try await client.execute(uri: "/v1/imports/nope/undo", method: .get, headers: TestServer.dash) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/imports/nope/hide", method: .post, headers: TestServer.dash) { #expect($0.status == .notFound) }
        }
    }

    @Test("A Plaid sync record is refused even when none of its rows say Plaid")
    func plaidRecordRefusedWithoutRows() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        var report = IngestReport(batchID: "plaid-link-9-1", source: .plaid)
        report.rowsAdded = 0
        try await service.store.upsertImport(ImportRecord(batchID: "plaid-link-9-1", kind: .sync, linkID: "plaid-link-9", label: "Harbor Bank sync",
                                                          report: report, createdAt: Date(), rolledBack: false))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports/plaid-link-9-1", method: .delete, headers: TestServer.dash) { #expect($0.status == .conflict) }
            try await client.execute(uri: "/v1/imports/plaid-link-9-1/undo", method: .get, headers: TestServer.dash) { response in
                let plan = try Self.decode(RollbackPlan.self, response)
                #expect(plan.verdict == .refuse)
            }
        }
    }

    @Test("DELETE on a SimpleFIN batch whose rows come back needs ?acknowledge=returning, then removes them all")
    func simplefinNeedsYes() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        // The next sync reaches back 10 days before the last one (just now): two of the three rows come back.
        let record = try await Self.synced(.simplefin, rowsDaysAgo: [1, 5, 30], into: service)
        let batch = record.batchID
        try await app.test(.router) { client in
            #expect(try await Self.record(batch, client).undo?.mode == .warn)
            try await client.execute(uri: "/v1/imports/\(batch)/undo", method: .get, headers: TestServer.dash) { response in
                let plan = try Self.decode(RollbackPlan.self, response)
                #expect(plan.verdict == .undoReturns && plan.rows == 3 && plan.returning == 2)
            }
            try await client.execute(uri: "/v1/imports/\(batch)", method: .delete, headers: TestServer.dash) { response in
                #expect(response.status == .conflict)
                #expect(String(buffer: response.body).contains("2 of them come back"))
            }
            #expect(try await service.api.transactions(TransactionFilter()).count == 3)
            #expect(try await Self.record(batch, client).rolledBack == false)

            try await client.execute(uri: "/v1/imports/\(batch)?acknowledge=returning", method: .delete, headers: TestServer.dash) { response in
                let removed = try Self.decode([String: Int].self, response)
                #expect(response.status == .ok && removed == ["removed": 3])
            }
            #expect(try await service.api.transactions(TransactionFilter()).isEmpty)
            let undone = try await Self.record(batch, client)
            #expect(undone.rolledBack && undone.undo?.mode == .refused)
            try await client.execute(uri: "/v1/imports/\(batch)?acknowledge=returning", method: .delete, headers: TestServer.dash) {
                #expect($0.status == .conflict)
            }
        }
    }

    @Test("A failed sync record is refused: 409, a refuse plan, and its rows stay")
    func failedRecordRefused() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        var record = try await Self.synced(.simplefin, rowsDaysAgo: [1, 5], into: service)
        record.outcome = .failed
        record.error = "Harbor Bank didn't answer."
        try await service.store.upsertImport(record)
        let batch = record.batchID
        try await app.test(.router) { client in
            #expect(try await Self.record(batch, client).undo?.mode == .refused)
            try await client.execute(uri: "/v1/imports/\(batch)/undo", method: .get, headers: TestServer.dash) { response in
                let plan = try Self.decode(RollbackPlan.self, response)
                #expect(plan.verdict == .refuse && plan.message.contains("failed"))
            }
            try await client.execute(uri: "/v1/imports/\(batch)?acknowledge=returning", method: .delete, headers: TestServer.dash) {
                #expect($0.status == .conflict)
            }
            #expect(try await service.api.transactions(TransactionFilter()).count == 2)
            #expect(try await Self.record(batch, client).rolledBack == false)
        }
    }

    @Test("A SimpleFIN batch whose link is gone still needs the yes: nothing comes back at a sync, but a new link would")
    func simplefinLinkGoneNeedsYes() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        let record = try await Self.synced(.simplefin, rowsDaysAgo: [1, 5, 30], into: service)
        try await service.store.deleteLink(try #require(record.linkID))
        let batch = record.batchID
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports/\(batch)/undo", method: .get, headers: TestServer.dash) { response in
                let plan = try Self.decode(RollbackPlan.self, response)
                #expect(plan.verdict == .undoReturns && plan.rows == 3 && plan.returning == 0)
                #expect(plan.message.contains("link it again"))
            }
            try await client.execute(uri: "/v1/imports/\(batch)", method: .delete, headers: TestServer.dash) { #expect($0.status == .conflict) }
            #expect(try await service.api.transactions(TransactionFilter()).count == 3)
            try await client.execute(uri: "/v1/imports/\(batch)?acknowledge=returning", method: .delete, headers: TestServer.dash) { response in
                let removed = try Self.decode([String: Int].self, response)
                #expect(response.status == .ok && removed == ["removed": 3])
            }
            #expect(try await Self.record(batch, client).rolledBack)
        }
    }

    @Test("Hidden is read from the rows: shown again drops the tag and Hide works again; a hide that finds nothing to hide still marks an all-hidden batch")
    func hiddenFollowsRows() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        let record = try await Self.synced(.plaid, rowsDaysAgo: [1, 3], into: service)
        let batch = record.batchID
        try await app.test(.router) { client in
            var undo: AppAction?
            try await client.execute(uri: "/v1/imports/\(batch)/hide", method: .post, headers: TestServer.dash) { response in
                undo = try Self.decode(ActionResult.self, response).undo
            }
            #expect(try await Self.record(batch, client).hiddenAt != nil)

            // Shown again through the hide's undo: history no longer says Hidden, and Hide hides them again.
            _ = try await service.api.perform(try #require(undo))
            #expect(try await Self.record(batch, client).hiddenAt == nil)
            try await client.execute(uri: "/v1/imports/\(batch)/hide", method: .post, headers: TestServer.dash) { response in
                let result = try Self.decode(ActionResult.self, response)
                #expect(result.affectedTransactions == 2 && result.undo != nil)
            }
            #expect(try await Self.record(batch, client).hiddenAt != nil)

            // Rows hidden some other way (the record was never marked): a hide hides nothing, offers no undo, and marks it.
            var stored = try #require(try await service.store.imports().first { $0.batchID == batch })
            stored.hiddenAt = nil
            try await service.store.upsertImport(stored)
            try await client.execute(uri: "/v1/imports/\(batch)/hide", method: .post, headers: TestServer.dash) { response in
                let result = try Self.decode(ActionResult.self, response)
                #expect(response.status == .ok && result.affectedTransactions == 0 && result.undo == nil)
            }
            #expect(try await Self.record(batch, client).hiddenAt != nil)
        }
    }

    @Test("Hide on a batch with no rows left hides nothing and leaves the record unmarked")
    func hideNothingLeft() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        var report = IngestReport(batchID: "plaid-link-9-1", source: .plaid)
        report.rowsAdded = 0
        try await service.store.upsertImport(ImportRecord(batchID: "plaid-link-9-1", kind: .sync, linkID: "plaid-link-9", label: "Harbor Bank sync",
                                                          report: report, createdAt: Date(), rolledBack: false))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports/plaid-link-9-1/hide", method: .post, headers: TestServer.dash) { response in
                let result = try Self.decode(ActionResult.self, response)
                #expect(response.status == .ok && result.affectedTransactions == 0 && result.undo == nil)
            }
            #expect(try await Self.record("plaid-link-9-1", client).hiddenAt == nil)
            #expect(try await service.store.imports().first?.hiddenAt == nil)
        }
    }

    @Test("DELETE on a file batch removes its rows")
    func fileRollsBack() async throws {
        let (app, service) = try await TestServer.app(surface: .dashboard)
        let accountID = try #require(try await service.api.overview().accounts.first { $0.kind == .credit }?.id)
        try await app.test(.router) { client in
            let csv = "Date,Description,Amount\\n09/10/2026,UNITED AIRLINES,486.20\\n09/11/2026,HOTEL NIKKO,312.00\\n"
            let body = #"{"content":"\#(csv)","accountID":"\#(accountID)","options":{"format":"csv","sign":"positiveIsOut","institution":"Summit"}}"#
            var batch = ""
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.dash, body: TestServer.body(body)) { response in
                let record = try Self.decode(ImportRecord.self, response)
                #expect(record.undo?.mode == .allowed)
                batch = record.batchID
            }
            try await client.execute(uri: "/v1/imports/\(batch)/undo", method: .get, headers: TestServer.dash) { response in
                let plan = try Self.decode(RollbackPlan.self, response)
                #expect(plan.verdict == .undo && plan.rows == 2 && plan.bySource == ["fileImport": 2])
            }
            try await client.execute(uri: "/v1/imports/\(batch)", method: .delete, headers: TestServer.dash) { response in
                let removed = try Self.decode([String: Int].self, response)
                #expect(response.status == .ok && removed == ["removed": 2])
            }
            #expect(try await service.api.transactions(TransactionFilter(search: "Hotel Nikko")).isEmpty)
            #expect(try await Self.record(batch, client).rolledBack)
        }
    }
}
