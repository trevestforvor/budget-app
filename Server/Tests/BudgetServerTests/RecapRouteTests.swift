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

/// The recurring review and the monthly recap, through the app's own client against the running server.
@Suite("Recurring review and monthly recap over HTTP")
struct RecapRouteTests {
    @Test("The review asks about the demo's two series; answers go through /v1/actions, with undo")
    func recurringReview() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let review = try await remote.recurringReview()
            #expect(review.candidates.map(\.merchant) == ["Pocket Yoga"])
            #expect(review.maybeStopped.map(\.merchant) == ["StreamBox"])

            let stop = AppAction.reviewRecurring(ReviewRecurring(merchant: "StreamBox", answer: .stopped))
            #expect(try await remote.preview(stop).title == "StreamBox stopped")
            let result = try await remote.perform(stop)
            #expect(!(try await remote.subscriptions()).items.contains { $0.merchant == "StreamBox" })
            #expect(try await remote.recurringReview().ended == ["StreamBox"])
            _ = try await remote.perform(try #require(result.undo))
            #expect(try await remote.recurringReview().maybeStopped.map(\.merchant) == ["StreamBox"])

            _ = try await remote.perform(.setRecurring(SetRecurring(merchant: "Pocket Yoga", isRecurring: true, cadence: .monthly)))
            #expect(try await remote.recurringReview().candidates.isEmpty)
            await #expect(throws: BudgetAPIError.rejected("Netflix Max isn't on your recurring list.")) {
                try await remote.perform(.reviewRecurring(ReviewRecurring(merchant: "Netflix Max", answer: .stopped)))
            }
        }
    }

    @Test("Last month's recap by default, a named month on request; a misspelled or unheld month is refused")
    func monthlyRecap() async throws {
        let (app, service) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let calendar = await service.settings.calendar
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: calendar.dateInterval(of: .month, for: Date())!.start)!
            let key = String(format: "%04d-%02d", calendar.component(.year, from: lastMonth), calendar.component(.month, from: lastMonth))
            let recap = try await remote.monthlyRecap(month: nil)
            #expect(recap.month == key)
            #expect(recap.saved == recap.income - recap.spending)
            #expect(recap.buckets.count == 3)
            #expect(recap.netWorthChange == nil)
            let named = try await remote.monthlyRecap(month: key)
            #expect(named.month == key && named.income == recap.income && named.spending == recap.spending)
            await #expect(throws: BudgetAPIError.self) { try await remote.monthlyRecap(month: "1999-01") }
        }
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/recap/month?month=2026-13", method: .get, headers: TestServer.auth) {
                #expect($0.status == .unprocessableContent)
            }
        }
    }

    @Test("The dashboard reads both without a token")
    func dashboard() async throws {
        let (app, _) = try await TestServer.app(surface: .dashboard)
        try await app.test(.router) { client in
            for uri in ["/v1/recurring/review", "/v1/recap/month"] {
                try await client.execute(uri: uri, method: .get, headers: [HTTPField.Name("X-Budget-Dashboard")!: "1"]) {
                    #expect($0.status == .ok, "\(uri)")
                }
            }
        }
    }
}
