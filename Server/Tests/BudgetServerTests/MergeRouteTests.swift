import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Testing

/// P1.3 over HTTP: a statement row that might be a synced one waits as a possible duplicate (both surfaces answer it),
/// and the merge log (dashboard) lists what was skipped and brings it back.
@Suite("Possible duplicate and merge routes")
struct MergeRouteTests {
    static func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try RemoteBudgetAPI.decoder.decode(T.self, from: Data(response.body.readableBytesView))
    }

    static let dashWrite: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]

    /// Noon UTC on 2026-09-21, the day statement dates land on.
    static var monday: Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 12))!
    }

    /// A synced checking account (read as SimpleFIN sends it, labelled Plaid): two $15 rows at different places on one
    /// day, and a coffee. Returns the account id.
    static func seed(_ service: BudgetService) async throws -> String {
        let t = Int(monday.timeIntervalSince1970)
        let json = #"{"errors": [], "accounts": [{"id": "acct-1", "name": "Everyday Checking", "org": {"name": "Harbor Bank"}, "currency": "USD", "balance": "2400.00", "balance-date": \#(t), "transactions": [{"id": "deli", "posted": \#(t), "amount": "-15.00", "description": "CORNER DELI"}, {"id": "park", "posted": \#(t), "amount": "-15.00", "description": "HARBOR PARKING"}, {"id": "coffee", "posted": \#(t + 86_400), "amount": "-6.50", "description": "BLUE BOTTLE COFFEE"}]}]}"#
        var snapshot = try SimpleFINSource.parse(Data(json.utf8))
        snapshot.source = .plaid
        _ = try await service.api.ingest(snapshot, batchID: "sync-1")
        return try #require(try await service.api.overview().accounts.first?.id)
    }

    static func statement(_ accountID: String) -> ByteBuffer {
        let csv = "Transaction Date,Post Date,Description,Category,Type,Amount,Memo\\n09/21/2026,09/21/2026,PURCHASE AUTHORIZED ON 09/21,,Sale,-15.00,\\n09/22/2026,09/22/2026,BLUE BOTTLE COFFEE,,Sale,-6.50,\\n"
        return TestServer.body(#"{"content": "\#(csv)", "accountID": "\#(accountID)", "label": "September.csv"}"#)
    }

    static func importStatement(_ accountID: String, _ client: some TestClientProtocol) async throws -> ImportRecord {
        try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth, body: statement(accountID)) { response in
            #expect(response.status == .created)
            return try decode(ImportRecord.self, response)
        }
    }

    @Test("A possible duplicate is listed, Same charge merges it (logged), and the dashboard brings it back")
    func sameChargeAndBringBack() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false)
        let dash = Application(router: buildRouter(service, surface: .dashboard))
        let accountID = try await Self.seed(service)
        let (batch, flaggedID) = try await app.test(.router) { client -> (String, String) in
            let record = try await Self.importStatement(accountID, client)
            #expect(record.report.possibleDuplicates == 1 && record.report.duplicatesSkipped == 1)
            let flagged = try await client.execute(uri: "/v1/duplicates", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                return try #require(try Self.decode([PossibleDuplicate].self, response).first)
            }
            #expect(flagged.candidates.count == 2)
            let path = "/v1/duplicates/\(flagged.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))!)"
            // Not a candidate → 422; an unknown row → 404.
            try await client.execute(uri: path, method: .post, headers: TestServer.auth, body: TestServer.body(#"{"sameAs": "plaid:coffee"}"#)) { response in
                #expect(response.status == .unprocessableContent)
            }
            try await client.execute(uri: "/v1/duplicates/nope", method: .post, headers: TestServer.auth, body: TestServer.body(#"{"sameAs": null}"#)) { response in
                #expect(response.status == .notFound)
            }
            let candidate = flagged.candidates[0].id
            try await client.execute(uri: path, method: .post, headers: TestServer.auth, body: TestServer.body(#"{"sameAs": "\#(candidate)"}"#)) { response in
                #expect(response.status == .ok)
                let merged = try #require(try Self.decode([String: RowMergeRecord].self, response)["merged"])
                #expect(merged.kind == .duplicateResolved && merged.keptID == candidate && merged.droppedID == flagged.id)
            }
            // The merge log is the dashboard's.
            try await client.execute(uri: "/v1/merges", method: .get, headers: TestServer.auth) { #expect($0.status == .notFound) }
            return (record.batchID, flagged.id)
        }
        try await dash.test(.router) { client in
            let merges = try await client.execute(uri: "/v1/merges?batch=\(batch)", method: .get) { response in
                #expect(response.status == .ok)
                return try Self.decode([RowMergeRecord].self, response)
            }
            #expect(Set(merges.map(\.kind)) == [.skippedIncoming, .duplicateResolved])
            let resolved = try #require(merges.first { $0.kind == .duplicateResolved })
            let undo = "/v1/merges/\(resolved.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", ":"]))!)/undo"
            try await client.execute(uri: undo, method: .post, headers: Self.dashWrite) { response in
                #expect(response.status == .ok)
                let result = try Self.decode(MergeUndoResult.self, response)
                #expect(result.restored == 1)
            }
            try await client.execute(uri: undo, method: .post, headers: Self.dashWrite) { #expect($0.status == .unprocessableContent) }
            // "Import the skipped rows anyway": the coffee comes back.
            try await client.execute(uri: "/v1/imports/\(batch)/merges/undo", method: .post, headers: Self.dashWrite) { response in
                let result = try Self.decode(MergeUndoResult.self, response)
                #expect(result.restored == 1)
            }
        }
        let rows = try await service.api.transactions(TransactionFilter())
        #expect(rows.contains { $0.id == flaggedID })
        #expect(rows.filter { $0.batchID == batch }.count == 2)
    }

    @Test("Keep both answers with an explicit null and clears the question")
    func keepBoth() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false)
        let accountID = try await Self.seed(service)
        try await app.test(.router) { client in
            _ = try await Self.importStatement(accountID, client)
            let id = try #require(await service.api.possibleDuplicates().first?.id)
            let path = "/v1/duplicates/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))!)"
            try await client.execute(uri: path, method: .post, headers: TestServer.auth, body: TestServer.body(#"{"sameAs": null}"#)) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains(#""merged":null"#))
            }
            try await client.execute(uri: "/v1/duplicates", method: .get, headers: TestServer.auth) { response in
                let left = try Self.decode([PossibleDuplicate].self, response)
                #expect(left.isEmpty)
            }
        }
    }

    @Test("The sweep reports rows it left because they look like more than one synced row")
    func sweepReportsAmbiguous() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false)
        _ = try await Self.seed(service)
        var state = await service.api.state
        let account = try #require(state.accounts.first?.id)
        // A statement row worded like both $15 rows' shared word, already in the ledger (an older matcher let it in).
        for (id, description) in [("plaid:deli", "HARBOR DELI NORTH"), ("plaid:park", "HARBOR DELI SOUTH")] {
            let i = try #require(state.transactions.firstIndex { $0.id == id })
            state.transactions[i].rawDescription = description
        }
        state.transactions.append(LedgerTransaction(id: "fileImport:\(account):x", accountID: account, postedAt: Self.monday, merchant: "Harbor Deli East",
                                                    rawDescription: "HARBOR DELI EAST", amount: Money(-15), categorization: nil, isPending: false,
                                                    source: .fileImport))
        await service.api.replaceStateWithoutPersisting(state)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports/duplicates", method: .post, headers: TestServer.auth, body: TestServer.body(#"{"apply": true}"#)) { response in
                let sweep = try Self.decode(DuplicateSweep.self, response)
                #expect(sweep.pairs.isEmpty && sweep.removed == 0 && sweep.ambiguous == 1)
            }
        }
    }
}
