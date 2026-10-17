import BudgetKit
@testable import BudgetServerCore
import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Testing

/// The reconnect review's fixes: a sign-in that finishes after the page's 15 minutes, an `/item/get` that fails after
/// one, a webhook that doesn't wait on Plaid, and the setup a phone reconnect needs.
@Suite("Reconnect from the phone: late finishes, unconfirmed checks, setup")
struct ReconnectReviewTests {
    typealias R = ReconnectRouteTests

    @Test("A sign-in begun before the page closed and finished after it ends done, synced, not expired")
    func finishedAfterThePageClosed() async throws {
        let f = try await R.fixture(R.provider(get: [R.succeeded]))
        try await f.app.test(.router) { client in
            let session = try R.session(try await R.post(client).1)
            f.clock.set(R.start.addingTimeInterval(901 + 60))
            let done = try await R.settle(client, session.id)
            #expect(done.state == .done)
            #expect(done.result?.ok == true)
        }
        #expect(try await f.link().status == .connected)
        #expect(f.plaid.count("/transactions/sync") == 1)
    }

    @Test("A SESSION_FINISHED webhook after the page closed, while the token lasts, still moves the session on")
    func lateWebhook() async throws {
        let f = try await R.fixture(R.provider(get: [R.succeeded]))
        try await f.app.test(.router) { client in
            let session = try R.session(try await R.post(client).1)
            f.clock.set(R.start.addingTimeInterval(1200))
            await f.service.reconnects.check(linkTokenHash: PlaidWebhookVerifier.hex(SHA256.hash(data: Data(R.linkToken.utf8))))
            for _ in 0..<200 where f.plaid.count("/link/token/get") == 0 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(f.plaid.count("/link/token/get") == 1)
            #expect(try await R.settle(client, session.id).state == .done)
        }
    }

    @Test("/item/get failing after a finished session confirms nothing: the sync runs and decides, never \"Plaid still says\"")
    func itemCheckFails() async throws {
        let down = PlaidErrorKindTests.plaidError("INTERNAL_SERVER_ERROR", type: "API_ERROR", status: 500)
        let f = try await R.fixture(R.provider(get: [R.succeeded], item: [down]))
        try await f.app.test(.router) { client in
            let session = try R.session(try await R.post(client).1)
            let ended = try await R.settle(client, session.id)
            #expect(ended.state == .done)
            #expect(ended.message?.contains("still says") != true)
        }
        #expect(f.plaid.count("/item/get") == 1)
        #expect(f.plaid.count("/transactions/sync") == 1)
        #expect(try await f.link().status == .connected)
    }

    @Test("/item/get failing, and the bank still refusing the sync: failed with the sync's words, the link still waiting")
    func itemCheckFailsAndBankRefuses() async throws {
        let down = PlaidErrorKindTests.plaidError("INTERNAL_SERVER_ERROR", type: "API_ERROR", status: 500)
        let plaid = ScriptedProvider([
            "/link/token/create": [R.created],
            "/link/token/get": [R.succeeded],
            "/item/get": [down],
            "/transactions/sync": [PlaidErrorKindTests.plaidError("ITEM_LOGIN_REQUIRED")],
        ])
        let f = try await R.fixture(plaid)
        try await f.app.test(.router) { client in
            let session = try R.session(try await R.post(client).1)
            let ended = try await R.settle(client, session.id)
            #expect(ended.state == .failed)
            #expect(ended.message?.contains("still says") != true)
        }
        #expect(try await f.link().status == .needsReauth)
    }

    @Test("The webhook's check returns before Plaid answers /link/token/get")
    func webhookDoesNotWait() async throws {
        let f = try await R.fixture(R.provider(delay: .milliseconds(600)))
        try await f.app.test(.router) { client in
            let session = try R.session(try await R.post(client).1)
            let clock = ContinuousClock()
            let began = clock.now
            await f.service.reconnects.check(linkTokenHash: PlaidWebhookVerifier.hex(SHA256.hash(data: Data(R.linkToken.utf8))))
            #expect(clock.now - began < .milliseconds(300))
            // A poll while that look is out doesn't ask Plaid a second time.
            for _ in 0..<200 where f.plaid.count("/link/token/get") == 0 { try await Task.sleep(for: .milliseconds(5)) }
            _ = try await R.poll(client, session.id)
            #expect(f.plaid.count("/link/token/get") == 1)
        }
    }

    @Test("Two polls at once ask Plaid once")
    func concurrentPolls() async throws {
        let f = try await R.fixture(R.provider(delay: .milliseconds(100)))
        try await f.app.test(.router) { client in
            let session = try R.session(try await R.post(client).1)
            async let a = R.poll(client, session.id)
            async let b = R.poll(client, session.id)
            _ = try await (a, b)
        }
        #expect(f.plaid.count("/link/token/get") == 1)
    }

    @Test("A sandbox with no redirect at all (mobile off, no PLAID_REDIRECT_URI): 422 providerSetup, no Plaid call, not offered on the phone")
    func sandboxWithoutRedirect() async throws {
        let f = try await R.fixture(edit: { $0.plaidMobileRedirectURI = "off"; $0.plaid?.redirectURI = nil })
        try await f.app.test(.router) { client in
            let (status, body, _) = try await R.post(client)
            #expect(status == .unprocessableContent)
            #expect(body.contains("providerSetup"))
            #expect(body.contains("PLAID_REDIRECT_URI"))
        }
        #expect(f.plaid.count("/link/token/create") == 0)
        await f.service.sync.publishInstitutions()
        #expect(try await f.service.api.serverStatus().institutions.first { $0.id == R.id }?.reconnect == .dashboard)
    }

    @Test("No BUDGET_TOKEN_KEY: the phone isn't offered a reconnect it would be refused")
    func noTokenKey() async throws {
        let f = try await R.fixture()
        #expect(await ReconnectMethod.phoneCapable(settings: f.service.settings, providers: f.service.providers, sealer: f.service.sealer))
        #expect(!(await ReconnectMethod.phoneCapable(settings: f.service.settings, providers: f.service.providers, sealer: nil)))
    }

    @Test("Plaid's expiration already past by the server's clock: the session still gets its 15 minutes")
    func skewedExpiration() async throws {
        let stale = (200, #"{"link_token": "\#(R.linkToken)", "hosted_link_url": "\#(R.hostedURL)", "expiration": "2026-10-14T09:00:00Z", "request_id": "req-lt"}"#)
        let f = try await R.fixture(R.provider(create: [stale]))
        try await f.app.test(.router) { client in
            let (status, body, _) = try await R.post(client)
            #expect(status == .created)
            let session = try R.session(body)
            #expect(session.expiresAt == R.start.addingTimeInterval(900))
            #expect(try R.session(try await R.poll(client, session.id).1).state == .waiting)
        }
    }
}
