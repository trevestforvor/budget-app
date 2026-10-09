import BudgetKit
@testable import BudgetServerCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Testing

@Suite("Tags, filing similar rows and the CSV export over HTTP")
struct TransactionToolsTests {
    /// The app's own client against the running server.
    @Test("Tags round-trip: tag rows, list and read a tag, filter by it, export it; filing similar reaches the merchant's other rows")
    func parity() async throws {
        let (app, service) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)

            let tags = try await remote.tags(period: nil)
            #expect(tags.map(\.tag).sorted() == ["Austin trip", "Reimbursable"])
            #expect(tags == (try await service.api.tags(period: nil)))
            let trip = try await remote.tag("austin trip", period: nil)
            #expect(trip.tag == "Austin trip" && trip.byCategory?.isEmpty == false)
            await #expect(throws: BudgetAPIError.notFound) { try await remote.tag("Paris", period: nil) }
            await #expect(throws: BudgetAPIError.rejected("Unknown period “someday”.")) { try await remote.tags(period: "someday") }

            let rows = try await remote.transactions(TransactionFilter(search: "Olive Grill", limit: 2))
            let tagged = try await remote.perform(.editTransactions(EditTransactions(transactionIDs: rows.map(\.id), addTags: ["Date night"])))
            #expect(tagged.message == "Tagged 2 transactions “Date night”.")
            #expect(try await remote.transactions(TransactionFilter(tags: ["date NIGHT"])).map(\.id) == rows.map(\.id))
            #expect(try await remote.transactionSummary(TransactionFilter(tags: ["Date night"])).count == 2)
            #expect(try await remote.tag("Date night", period: nil).count == 2)
            let csv = String(decoding: try await remote.exportCSV(TransactionFilter(tags: ["Date night"])), as: UTF8.self)
            #expect(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == 3)
            _ = try await remote.perform(try #require(tagged.undo))
            #expect(try await remote.transactions(TransactionFilter(tags: ["Date night"])).isEmpty)

            let coffee = try #require(try await remote.transactions(TransactionFilter(search: "Blue Bottle", limit: 1)).first)
            let similar = AppAction.editTransactions(EditTransactions(transactionIDs: [coffee.id], categoryID: "groceries", fileSimilar: true))
            let preview = try await remote.preview(similar)
            #expect((preview.matchCount ?? 0) > 1)
            let filed = try await remote.perform(similar)
            #expect(filed.affectedTransactions == preview.matchCount)
            #expect(try await remote.transactions(TransactionFilter(search: "Blue Bottle", limit: 500)).allSatisfy { $0.categorization?.categoryID == "groceries" })
            _ = try await remote.perform(try #require(filed.undo))
            #expect(try await remote.transactions(TransactionFilter(search: "Blue Bottle", limit: 500)).allSatisfy { $0.categorization?.categoryID == "dining" })
        }
    }

    @Test("The export is a CSV download honoring the filter; export.csv is never read as a row id; bad filters say why")
    func exportRoute() async throws {
        let (app, service) = try await TestServer.app()
        let dining = try await service.api.transactions(TransactionFilter(categoryIDs: ["dining"], period: "this_month", limit: 5000)).count
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/transactions/export.csv?category=dining&period=this_month", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "text/csv; charset=utf-8; header=present")
                #expect(response.headers[.contentDisposition]?.hasPrefix("attachment; filename=\"budget-transactions-") == true)
                let body = String(buffer: response.body)
                #expect(body.hasPrefix("Date,Merchant,Description,Amount,Category,Bucket,Account,Tags,Note,Status,Hidden\r\n"))
                #expect(body.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == dining + 1)
                #expect(!body.replacingOccurrences(of: "\r\n", with: "").contains("\n")) // no bare line feeds outside quoted fields here
            }
            try await client.execute(uri: "/v1/transactions/export.csv", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/v1/transactions/export.csv?min=lots", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("min must be an amount"))
            }
            try await client.execute(uri: "/v1/transactions/export.csv?period=someday", method: .get, headers: TestServer.auth) {
                #expect($0.status == .unprocessableContent)
            }
            try await client.execute(uri: "/v1/tags/Austin%20trip?period=all", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let tag = try RemoteBudgetAPI.decoder.decode(TagSummary.self, from: Data(response.body.readableBytesView))
                #expect(tag.tag == "Austin trip" && tag.count > 1)
            }
            try await client.execute(uri: "/v1/tags/Nope", method: .get, headers: TestServer.auth) { #expect($0.status == .notFound) }
        }
    }

    @Test("The dashboard listener serves tags and the export without a token, for its download button")
    func dashboard() async throws {
        let (app, _) = try await TestServer.app(surface: .dashboard)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/transactions/export.csv?tag=Reimbursable", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == 3)
            }
            try await client.execute(uri: "/v1/tags", method: .get) { #expect($0.status == .ok) }
        }
    }
}
