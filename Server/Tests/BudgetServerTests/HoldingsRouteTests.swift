import BudgetKit
@testable import BudgetServerCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

/// Keeps every log line, to check what a holdings check says (and never says).
final class LinesLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? { get { metadata[key] } set { metadata[key] = newValue } }
    func log(event: LogEvent) { lock.withLock { kept.append(event.message.description) } }
    var lines: [String] { lock.withLock { kept } }
}

/// Plaid answers for a brokerage Item, and a ledger that already holds its accounts. Nothing reaches Plaid.
enum HoldingsScript {
    static let token = "access-sandbox-holdings"
    static let ok = (200, #"""
    {"accounts": [{"account_id": "inv", "balances": {"current": 20000}, "name": "Brokerage", "type": "investment", "subtype": "brokerage"}],
     "holdings": [
       {"account_id": "inv", "security_id": "sec-vti", "quantity": 50, "cost_basis": 10000, "institution_price": 250,
        "institution_price_as_of": "2026-10-16", "institution_value": 12500, "iso_currency_code": "USD"},
       {"account_id": "inv", "security_id": "sec-cash", "quantity": 6000, "institution_price": 1, "institution_value": 6000, "iso_currency_code": "USD"}
     ],
     "securities": [
       {"security_id": "sec-vti", "name": "Vanguard Total Stock Market ETF", "ticker_symbol": "VTI", "type": "etf", "is_cash_equivalent": false},
       {"security_id": "sec-cash", "name": "U S Dollar", "type": "cash", "is_cash_equivalent": true}
     ],
     "request_id": "req-hold-ok"}
    """#)

    static func error(_ code: String) -> (Int, String) {
        (400, #"{"error_type": "ITEM_ERROR", "error_code": "\#(code)", "error_message": "said its own way", "display_message": null, "request_id": "req-\#(code)"}"#)
    }

    /// A server with no demo, holding `kinds` of accounts at Northwind from Plaid (the investment one is "inv").
    static func service(_ kinds: [AccountKind] = [.investment, .checking]) async throws -> BudgetService {
        var state = LedgerState.empty
        state.accounts = kinds.enumerated().map { index, kind in
            Account(id: kind == .investment ? "plaid:inv" : "plaid:acct-\(index)", name: kind == .investment ? "Brokerage" : "Checking",
                    institution: "Northwind", kind: kind, balance: Money(kind == .investment ? 20_000 : 900), source: .plaid)
        }
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: MemoryStore(ledger: state), logger: Logger(label: "test"),
                                                                 plaidTransport: nil)
        try await BudgetServerApp.prepare(service)
        return service
    }

    static func source(_ plaid: ScriptedProvider, institution: String = "Northwind") -> PlaidSource {
        PlaidSource(environment: .sandbox, credentials: .init(clientID: "cid", secret: "sec"), accessToken: token, institution: institution, transport: plaid)
    }

    /// One holdings check, as the Item check and webhooks call it.
    /// `institution` is the name for logs; `sourceInstitution` is the Item's bank, which picks the ledger's accounts.
    static func refresh(_ service: BudgetService, _ plaid: ScriptedProvider, previous: HoldingsCheck?, enabled: Bool = true, person: Bool = false,
                        webhook: Bool = false, now: Date = Date(), institution: String = "Northwind", sourceInstitution: String? = nil,
                        log: LinesLogHandler? = nil) async -> HoldingsCheck? {
        let logger = log.map { handler in Logger(label: "test") { _ in handler } } ?? Logger(label: "test")
        return await HoldingsSync.refresh(enabled: enabled, source: source(plaid, institution: sourceInstitution ?? institution), previous: previous,
                                          requestedByPerson: person,
                                          webhookDue: webhook, api: service.api, now: now, institution: institution, logger: logger)
    }

    static let path = "/investments/holdings/get"
}

@Suite("Investment holdings on the server")
struct HoldingsRouteTests {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    @Test("GET /v1/holdings: the demo's two brokerages, the same through the app's client; the token is required")
    func getHoldingsRoute() async throws {
        let (app, service) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let report = try await remote.holdings()
            // The same report, to the second (dates go over the wire as ISO 8601, without fractions).
            let local = try await service.api.holdings()
            #expect(report.accounts.map(\.holdings).map { $0.map(\.id) } == local.accounts.map(\.holdings).map { $0.map(\.id) })
            #expect(report.accounts.map(\.total) == local.accounts.map(\.total) && report.accounts.map(\.unitemized) == local.accounts.map(\.unitemized))
            #expect(report.accounts.flatMap(\.holdings).map(\.value) == local.accounts.flatMap(\.holdings).map(\.value))
            #expect(abs(try #require(report.asOf).timeIntervalSince(try #require(local.asOf))) < 1)
            #expect(report.accounts.map(\.id) == ["northwind", "meadow-inv"] && report.asOf != nil)
            #expect(report.accounts[1].unitemized == Money(2_099.17))
        }
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/holdings", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/v1/holdings", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let report = try RemoteBudgetAPI.decoder.decode(HoldingsReport.self, from: Data(response.body.readableBytesView))
                #expect(report.accounts.first?.holdings.first?.ticker == "VTI")
                // No provider id leaves the server: the demo's security ids aren't in the body.
                #expect(!String(buffer: response.body).contains("demo-VTI"))
            }
        }
    }

    @Test("A check stores the positions, logs Plaid's request_id and never the token, and isn't made again the same day")
    func storesAndOnceADay() async throws {
        let service = try await HoldingsScript.service()
        let plaid = ScriptedProvider([HoldingsScript.path: [HoldingsScript.ok]])
        let log = LinesLogHandler()
        let first = try #require(await HoldingsScript.refresh(service, plaid, previous: nil, log: log))
        #expect(first.access == .ok && first.accounts == 1 && first.requestID == "req-hold-ok" && first.due == nil)
        #expect(plaid.count(HoldingsScript.path) == 1)
        let stored = try #require(try await service.api.holdings().accounts.first)
        #expect(stored.id == "plaid:inv" && stored.total == Money(18_500) && stored.unitemized == Money(1_500))
        #expect(stored.holdings.map(\.ticker) == ["VTI", nil] && stored.holdings[1].isCash)
        #expect(log.lines.contains { $0.contains("req-hold-ok") })
        #expect(!log.lines.contains { $0.contains(HoldingsScript.token) || $0.contains("VTI") || $0.contains("12500") })

        // The same day: no call, the check unchanged. A person's sync of a link that's fine doesn't ask either.
        #expect(await HoldingsScript.refresh(service, plaid, previous: first) == first)
        #expect(await HoldingsScript.refresh(service, plaid, previous: first, person: true) == first)
        #expect(plaid.count(HoldingsScript.path) == 1)
        // A day on, it's asked again.
        var old = first
        old.checkedAt = Date().addingTimeInterval(-25 * 3600)
        #expect(await HoldingsScript.refresh(service, plaid, previous: old)?.checkedAt != old.checkedAt)
        #expect(plaid.count(HoldingsScript.path) == 2)
    }

    @Test("A HOLDINGS webhook makes the next chance ask at once, whether it comes now or was marked on the check")
    func webhookMakesItDue() async throws {
        let service = try await HoldingsScript.service()
        let plaid = ScriptedProvider([HoldingsScript.path: [HoldingsScript.ok]])
        let first = try #require(await HoldingsScript.refresh(service, plaid, previous: nil))
        _ = await HoldingsScript.refresh(service, plaid, previous: first, webhook: true)
        #expect(plaid.count(HoldingsScript.path) == 2)
        var marked = first
        marked.due = true
        let after = try #require(await HoldingsScript.refresh(service, plaid, previous: marked))
        #expect(plaid.count(HoldingsScript.path) == 3 && after.due == nil && after.access == .ok)
    }

    @Test("An Item with no investment account is never asked, and says so")
    func noInvestmentAccountsNeverCalls() async throws {
        let service = try await HoldingsScript.service([.checking, .savings])
        let plaid = ScriptedProvider([HoldingsScript.path: [HoldingsScript.ok]])
        let check = try #require(await HoldingsScript.refresh(service, plaid, previous: nil, webhook: true))
        #expect(check.access == .noInvestmentAccounts)
        // Asked again (even by a webhook or the person), it stays the same check without a call.
        #expect(await HoldingsScript.refresh(service, plaid, previous: check, person: true, webhook: true) == check)
        // Another bank's brokerage doesn't count for this Item: the Item's own bank decides, not the name it's logged by.
        let other = try await HoldingsScript.service()
        #expect(await HoldingsScript.refresh(other, plaid, previous: nil, institution: "Northwind", sourceInstitution: "Harbor")?.access
            == .noInvestmentAccounts)
        #expect(plaid.count(HoldingsScript.path) == 0)
        #expect(await HoldingsScript.refresh(other, plaid, previous: nil, institution: "Harbor", sourceInstitution: "Northwind")?.access == .ok)
        #expect(plaid.count(HoldingsScript.path) == 1)
    }

    @Test("Plaid not ready yet: recorded, not retried by schedule the same day, retried when the person asks")
    func productNotReadyRecordedAndRetriedOnPersonSync() async throws {
        let service = try await HoldingsScript.service()
        let plaid = ScriptedProvider([HoldingsScript.path: [HoldingsScript.error("PRODUCT_NOT_READY"), HoldingsScript.ok]])
        let waiting = try #require(await HoldingsScript.refresh(service, plaid, previous: nil))
        #expect(waiting.access == .notReady && waiting.requestID == "req-PRODUCT_NOT_READY" && waiting.message == nil)
        #expect(try await service.api.holdings().accounts.isEmpty)
        #expect(await HoldingsScript.refresh(service, plaid, previous: waiting) == waiting)
        #expect(plaid.count(HoldingsScript.path) == 1)
        let ready = try #require(await HoldingsScript.refresh(service, plaid, previous: waiting, person: true))
        #expect(ready.access == .ok && plaid.count(HoldingsScript.path) == 2)
        #expect(try await service.api.holdings().accounts.count == 1)
    }

    @Test("Each Plaid answer maps to what the dashboard says; a failure keeps the last positions")
    func errorsMapped() async throws {
        let service = try await HoldingsScript.service()
        let seed = ScriptedProvider([HoldingsScript.path: [HoldingsScript.ok]])
        _ = await HoldingsScript.refresh(service, seed, previous: nil)
        for (code, access) in [("ADDITIONAL_CONSENT_REQUIRED", HoldingsAccess.needsConsent), ("PRODUCTS_NOT_SUPPORTED", .notSupported),
                               ("INVALID_PRODUCT", .notSupported), ("NO_INVESTMENT_ACCOUNTS", .noInvestmentAccounts),
                               ("INTERNAL_SERVER_ERROR", .failed)] {
            let plaid = ScriptedProvider([HoldingsScript.path: [HoldingsScript.error(code)]])
            let check = try #require(await HoldingsScript.refresh(service, plaid, previous: nil))
            #expect(check.access == access, "\(code)")
            #expect(check.message == (access == .failed ? "said its own way" : nil))
        }
        // Not Plaid's error at all (a 502 page from a proxy): failed, with a message, and the person may retry.
        let proxy = ScriptedProvider([HoldingsScript.path: [(502, "<html>Bad gateway</html>")]])
        let failed = try #require(await HoldingsScript.refresh(service, proxy, previous: nil))
        #expect(failed.access == .failed && failed.message != nil)
        #expect(HoldingsSync.isDue(failed, now: Date(), requestedByPerson: true, webhookDue: false))
        #expect(!HoldingsSync.isDue(failed, now: Date(), requestedByPerson: false, webhookDue: false))
        #expect(try await service.api.holdings().accounts.first?.total == Money(18_500))
    }

    @Test("Off: nothing asked, the last check kept")
    func offKeepsPrevious() async throws {
        let service = try await HoldingsScript.service()
        let plaid = ScriptedProvider([HoldingsScript.path: [HoldingsScript.ok]])
        let earlier = HoldingsCheck(access: .ok, checkedAt: Date().addingTimeInterval(-90 * 3600), accounts: 1)
        #expect(await HoldingsScript.refresh(service, plaid, previous: earlier, enabled: false, webhook: true) == earlier)
        #expect(await HoldingsScript.refresh(service, plaid, previous: nil, enabled: false) == nil)
        #expect(plaid.count(HoldingsScript.path) == 0)
    }

    @Test("A stored check reads back, and an access a newer server added reads as failed")
    func checkDecodes() throws {
        let check = HoldingsCheck(access: .notReady, checkedAt: Date(timeIntervalSince1970: 1_800_000_000), requestID: "req-1", due: true)
        let decoded = try RemoteBudgetAPI.decoder.decode(HoldingsCheck.self, from: try Self.encoder.encode(check))
        #expect(decoded == check)
        let future = #"{"access": "rateLimited", "checkedAt": "2027-01-01T00:00:00Z"}"#
        #expect(try RemoteBudgetAPI.decoder.decode(HoldingsCheck.self, from: Data(future.utf8)).access == .failed)
    }
}
