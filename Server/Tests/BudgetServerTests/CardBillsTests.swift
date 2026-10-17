import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

/// Plaid answers for an Item with a checking account and a credit card. Everything is scripted: nothing reaches Plaid.
enum LiabilitiesScript {
    static let balances = (200, #"""
    {"accounts": [
      {"account_id": "chk", "balances": {"current": 5000, "iso_currency_code": "USD"}, "name": "Checking", "type": "depository", "subtype": "checking"},
      {"account_id": "card", "balances": {"current": 812.4, "iso_currency_code": "USD"}, "mask": "1008", "name": "Gold Card", "type": "credit", "subtype": "credit card"}
    ]}
    """#)

    /// A plain Plaid date `days` from today.
    static func day(_ days: Int) -> String {
        let date = Date().addingTimeInterval(Double(days) * 86_400)
        return date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!).year().month().day())
    }

    static var bills: (Int, String) {
        (200, #"""
        {"accounts": [], "liabilities": {"credit": [
          {"account_id": "card", "aprs": [{"apr_percentage": 22.99, "apr_type": "purchase_apr"}], "is_overdue": false,
           "last_payment_amount": null, "last_payment_date": null, "last_statement_issue_date": "\#(day(-10))",
           "last_statement_balance": 640.25, "minimum_payment_amount": 35, "next_payment_due_date": "\#(day(5))"}
        ], "mortgage": null, "student": null}, "request_id": "req-liab-ok"}
        """#)
    }

    static func error(_ code: String) -> (Int, String) {
        (400, #"{"error_type": "ITEM_ERROR", "error_code": "\#(code)", "error_message": "said its own way", "display_message": null, "request_id": "req-\#(code)"}"#)
    }

    static func provider(liabilities: [(Int, String)], balances: (Int, String) = balances) -> ScriptedProvider {
        ScriptedProvider([
            "/item/public_token/exchange": [PlaidScript.exchange],
            "/transactions/sync": [PlaidScript.page("cursor-1")],
            "/accounts/get": [balances], "/accounts/balance/get": [balances],
            "/liabilities/get": liabilities,
            "/link/token/create": [(200, #"{"link_token": "link-grant-1"}"#)],
        ])
    }

    static func link(_ service: BudgetService) async throws {
        guard let sealer = service.sealer else { throw BudgetAPIError.rejected("no sealer") }
        try await service.store.upsertLink(StoredLink(id: "plaid-item-1", provider: .plaid, institution: "Summit Card", externalID: "item-1",
                                                      sealedToken: try sealer.seal("access-sandbox-9"), cursor: nil,
                                                      status: .connected, lastSync: nil, lastError: nil, createdAt: Date()))
    }

    /// The last request to `path`, as JSON.
    static func body(_ plaid: ScriptedProvider, _ path: String) -> [String: JSONValue] {
        guard let request = plaid.requests.last(where: { $0.path == path }), case let .object(o)? = try? JSONValue.parse(Data(request.body.utf8)) else { return [:] }
        return o
    }

    static func turnOn(_ service: BudgetService) async throws { try await service.settings.update(["cardBills": "true"]) }

    static func check(_ service: BudgetService) async throws -> CardBillCheck? { try await service.store.links().first?.cardBills }
}

@Suite("Card bills (Plaid Liabilities) on the server")
struct CardBillsServerTests {
    @Test("Off by default: syncing never asks for liabilities")
    func offByDefault() async throws {
        let plaid = LiabilitiesScript.provider(liabilities: [LiabilitiesScript.bills])
        let (_, service) = try await TestServer.app(seedDemo: false, plaid: plaid)
        #expect(await service.settings.cardBillsEnabled == false)
        try await LiabilitiesScript.link(service)
        #expect(await service.sync.syncAll().map(\.ok) == [true])
        #expect(plaid.count("/liabilities/get") == 0)
        #expect(try await LiabilitiesScript.check(service) == nil)
        #expect(await service.api.state.cardBills.isEmpty)
    }

    @Test("On: the card's statement is stored, Upcoming shows it, and it's asked for at most once a day")
    func onceADay() async throws {
        let plaid = LiabilitiesScript.provider(liabilities: [LiabilitiesScript.bills])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: plaid)
        try await LiabilitiesScript.turnOn(service)
        try await LiabilitiesScript.link(service)
        #expect(await service.sync.syncAll().map(\.ok) == [true])
        #expect(plaid.count("/liabilities/get") == 1)
        let check = try #require(try await LiabilitiesScript.check(service))
        #expect(check.access == .ok && check.cards == 1 && check.requestID == "req-liab-ok")
        // Only the credit card is asked about.
        #expect(LiabilitiesScript.body(plaid, "/liabilities/get")["options"] == .object(["account_ids": .array([.string("card")])]))
        #expect(await service.api.state.cardBills["plaid:card"]?.statementBalance == Money(640.25))

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/upcoming?days=14", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let upcoming = try RemoteBudgetAPI.decoder.decode(Upcoming.self, from: Data(response.body.readableBytesView))
                let card = try #require(upcoming.items.first { $0.kind == .cardBill })
                #expect(card.amount == Money(-640.25) && card.minimumPayment == Money(35) && card.title == "Gold Card ••1008")
                #expect(upcoming.cardBills.first?.purchaseAPR == 22.99)
            }
        }

        // Later syncs the same day don't ask again; a person's own "Sync now" on a link that's fine doesn't either.
        _ = await service.sync.syncAll()
        _ = try await service.sync.sync(linkID: "plaid-item-1")
        #expect(plaid.count("/liabilities/get") == 1)
        // A day on, it's asked again.
        var link = try #require(try await service.store.links().first)
        link.cardBills?.checkedAt = Date().addingTimeInterval(-25 * 3600)
        try await service.store.upsertLink(link)
        _ = await service.sync.syncAll()
        #expect(plaid.count("/liabilities/get") == 2)
    }

    @Test("Linked before card bills: the sync still succeeds, the link says it needs consent, and only the person's grant asks again")
    func needsConsent() async throws {
        let plaid = LiabilitiesScript.provider(liabilities: [LiabilitiesScript.error("ADDITIONAL_CONSENT_REQUIRED"), LiabilitiesScript.bills])
        let (dash, service) = try await TestServer.app(seedDemo: false, plaid: plaid, surface: .dashboard)
        try await LiabilitiesScript.turnOn(service)
        try await LiabilitiesScript.link(service)
        let first = await service.sync.syncAll()
        #expect(first.map(\.ok) == [true])
        #expect(try await LiabilitiesScript.check(service)?.access == .needsConsent)
        #expect(try await LiabilitiesScript.check(service)?.requestID == "req-ADDITIONAL_CONSENT_REQUIRED")
        // The schedule doesn't keep asking.
        _ = await service.sync.syncAll()
        #expect(plaid.count("/liabilities/get") == 1)

        try await dash.test(.router) { client in
            // The dashboard's "Grant card-bill access": update mode on the same Item, liabilities consent, no products.
            try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: SyncRouteTests.write,
                                     body: TestServer.body(#"{"linkID":"plaid-item-1","grantCardBills":true}"#)) { response in
                #expect(String(buffer: response.body).contains("link-grant-1"))
            }
            let token = LiabilitiesScript.body(plaid, "/link/token/create")
            #expect(token["access_token"] == .string("access-sandbox-9"))
            #expect(token["additional_consented_products"] == .array([.string("liabilities")]))
            #expect(token["products"] == .array([]))
            // Without a link it's refused rather than starting a new Item.
            try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: SyncRouteTests.write,
                                     body: TestServer.body(#"{"grantCardBills":true}"#)) { #expect($0.status == .unprocessableContent) }
            // Link finished: the same sync update mode ends with, which asks again at once.
            try await client.execute(uri: "/v1/links/plaid-item-1/sync", method: .post, headers: SyncRouteTests.write) { #expect($0.status == .ok) }
        }
        #expect(plaid.count("/liabilities/get") == 2)
        #expect(try await LiabilitiesScript.check(service)?.access == .ok)
        // Never exchanged, never removed: the Item and its access token are the same.
        #expect(plaid.count("/item/public_token/exchange") == 0)
        #expect(plaid.count("/item/remove") == 0)
        #expect(plaid.count("/item/access_token/invalidate") == 0)
        #expect(try await service.store.links().map(\.id) == ["plaid-item-1"])
    }

    @Test("Each \"not available\" answer is kept on the link, and none fails the sync", arguments: [
        ("PRODUCTS_NOT_SUPPORTED", CardBillAccess.notSupported), ("NO_LIABILITY_ACCOUNTS", .noCreditAccounts),
        ("PRODUCT_NOT_READY", .notReady), ("INVALID_PRODUCT", .notSupported), ("INTERNAL_SERVER_ERROR", .failed),
    ])
    func notAvailable(code: String, access: CardBillAccess) async throws {
        let plaid = LiabilitiesScript.provider(liabilities: [LiabilitiesScript.error(code)])
        let (_, service) = try await TestServer.app(seedDemo: false, plaid: plaid)
        try await LiabilitiesScript.turnOn(service)
        try await LiabilitiesScript.link(service)
        let results = await service.sync.syncAll()
        #expect(results.map(\.ok) == [true])
        #expect(try await service.store.links().first?.status == .connected)
        let check = try #require(try await LiabilitiesScript.check(service))
        #expect(check.access == access)
        #expect(check.requestID == "req-\(code)")
    }

    @Test("An Item with no credit card is never asked")
    func noCard() async throws {
        let plaid = LiabilitiesScript.provider(liabilities: [LiabilitiesScript.bills], balances: PlaidScript.balances)
        let (_, service) = try await TestServer.app(seedDemo: false, plaid: plaid)
        try await LiabilitiesScript.turnOn(service)
        try await LiabilitiesScript.link(service)
        _ = await service.sync.syncAll()
        #expect(plaid.count("/liabilities/get") == 0)
        #expect(try await LiabilitiesScript.check(service)?.access == .noCreditAccounts)
    }

    @Test("Card-bill checks before this version, and links saved before them, still load")
    func storedLinks() throws {
        let old = #"{"id":"plaid-item-1","provider":"plaid","institution":"Summit Card","sealedToken":"x","status":"connected","createdAt":0}"#
        let link = try JSONDecoder().decode(StoredLink.self, from: Data(old.utf8))
        #expect(link.cardBills == nil)
        let check = #"{"access":"somethingLater","checkedAt":0}"#
        #expect(try JSONDecoder().decode(CardBillCheck.self, from: Data(check.utf8)).access == .failed)
    }

    @Test("Due: never asked, a day old, or waiting on the person who just asked")
    func due() {
        let now = Date()
        #expect(CardBillSync.isDue(nil, now: now, requestedByPerson: false))
        let fresh = CardBillCheck(access: .ok, checkedAt: now.addingTimeInterval(-3600))
        #expect(!CardBillSync.isDue(fresh, now: now, requestedByPerson: false))
        #expect(!CardBillSync.isDue(fresh, now: now, requestedByPerson: true))
        #expect(CardBillSync.isDue(CardBillCheck(access: .ok, checkedAt: now.addingTimeInterval(-24 * 3600)), now: now, requestedByPerson: false))
        let waiting = CardBillCheck(access: .needsConsent, checkedAt: now.addingTimeInterval(-60))
        #expect(!CardBillSync.isDue(waiting, now: now, requestedByPerson: false))
        #expect(CardBillSync.isDue(waiting, now: now, requestedByPerson: true))
        #expect(!CardBillSync.isDue(CardBillCheck(access: .notSupported, checkedAt: now), now: now, requestedByPerson: true))
    }

    @Test("GET /v1/upcoming: the default window, a refused one, and the app's own client")
    func upcomingRoute() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let upcoming = try await remote.upcoming(days: 30)
            #expect(upcoming.days == 30)
            #expect(upcoming.nextPaycheck?.title == "Acme Corp")
            #expect(upcoming.byDay.flatMap(\.itemIDs) == upcoming.items.map(\.id))
            await #expect(throws: BudgetAPIError.self) { try await remote.upcoming(days: 0) }
        }
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/upcoming", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let upcoming = try RemoteBudgetAPI.decoder.decode(Upcoming.self, from: Data(response.body.readableBytesView))
                #expect(upcoming.days == 30)
            }
            try await client.execute(uri: "/v1/upcoming?days=abc", method: .get, headers: TestServer.auth) { #expect($0.status == .badRequest) }
        }
    }
}
