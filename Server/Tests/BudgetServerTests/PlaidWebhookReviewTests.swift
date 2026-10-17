import BudgetKit
@testable import BudgetServerCore
import Crypto
import Foundation
import HTTPTypes
import Testing

/// The P4 review's cases: which key-fetch answers count as an unknown `kid`, what a failed fetch logs, a heal's sync
/// spaced with the queue's, and keys asked again when Plaid rotates.
@Suite("Plaid webhook receiver: review fixes")
struct PlaidWebhookReviewTests {
    typealias F = WebhookFixture
    typealias T = PlaidWebhookTests

    static let missingFields = (400, #"{"error_type": "INVALID_REQUEST", "error_code": "MISSING_FIELDS", "error_message": "the following required fields are missing: key_id", "request_id": "req-missing"}"#)

    @Test("Only INVALID_WEBHOOK_VERIFICATION_KEY_ID means an unknown kid: another bad-request answer is a 503 and isn't remembered")
    func onlyTheExactCodeIsUnknown() async throws {
        #expect(PlaidWebhookVerifier.meansUnknownKey(PlaidAPIError(status: 400, errorType: "INVALID_INPUT", errorCode: "INVALID_WEBHOOK_VERIFICATION_KEY_ID")))
        for (type, code) in [("INVALID_REQUEST", "MISSING_FIELDS"), ("INVALID_REQUEST", "UNKNOWN_FIELDS"), ("INVALID_REQUEST", "INVALID_BODY"),
                             ("INVALID_REQUEST", "INVALID_FIELD"), ("INVALID_REQUEST", "INCOMPATIBLE_API_VERSION"), ("INVALID_INPUT", "INVALID_API_KEYS")] {
            #expect(!PlaidWebhookVerifier.meansUnknownKey(PlaidAPIError(status: 400, errorType: type, errorCode: code)))
        }

        let start = Date()
        let clock = TestClock(start)
        let f = try await F.fixture(F.provider(key: [Self.missingFields, F.jwk()]), clock: { clock.now })
        let body = F.body()
        try await f.app.test(.router) { client in
            try await T.post(client, body, jwt: F.jwt(body, iat: clock.now), expecting: .serviceUnavailable)
            // Past the 10 s spacing: no negative cache, so Plaid is asked again, and this time has the key.
            clock.set(start.addingTimeInterval(11))
            try await T.post(client, body, jwt: F.jwt(body, iat: clock.now), expecting: .ok)
        }
        #expect(f.fetches == 2)
    }

    @Test("A failed key fetch logs Plaid's code and request_id, never the kid")
    func failedFetchIsLogged() async throws {
        let start = Date()
        let clock = TestClock(start)
        let f = try await F.fixture(F.provider(key: [(500, #"{"error_type": "API_ERROR", "error_code": "INTERNAL_SERVER_ERROR", "request_id": "req-500"}"#),
                                                     Self.missingFields, F.unknownKey]), clock: { clock.now })
        let body = F.body()
        let kids = [F.kid, "kid-SECONDMARK", "kid-THIRDMARK"]
        try await f.app.test(.router) { client in
            for (i, kid) in kids.enumerated() {
                clock.set(start.addingTimeInterval(Double(i) * 11))
                _ = try await T.status(client, body, jwt: F.jwt(body, iat: clock.now, kid: kid))
            }
        }
        #expect(f.fetches == 3)
        let all = f.log.lines.joined(separator: "\n")
        #expect(all.contains("type API_ERROR, code INTERNAL_SERVER_ERROR, request_id req-500"))
        #expect(all.contains("type INVALID_REQUEST, code MISSING_FIELDS, request_id req-missing"))
        #expect(all.contains("type INVALID_INPUT, code INVALID_WEBHOOK_VERIFICATION_KEY_ID, request_id req-nokey"))
        for kid in kids { #expect(!all.contains(kid)) }
        #expect(!all.contains("MARK"))
    }

    @Test("LOGIN_REPAIRED and SYNC_UPDATES_AVAILABLE in one burst on a link waiting for a sign-in: healed, and one sync")
    func healAndSyncInOneBurst() async throws {
        let f = try await F.fixture(ScriptedProvider([
            "/webhook_verification_key/get": [F.jwk()],
            "/item/get": [ItemCheckTests.item(error: "ITEM_LOGIN_REQUIRED", webhook: nil), ItemCheckTests.item(webhook: nil)],
            "/transactions/sync": [PlaidScript.page("c1")], "/accounts/get": [PlaidScript.balances],
        ]), settle: 0.5)
        try await f.app.test(.router) { client in
            try await T.post(client, F.body("ITEM", "ERROR"), expecting: .ok)
        }
        try await f.settled()
        #expect(try await f.link().status == .needsReauth)
        try await f.app.test(.router) { client in
            try await T.post(client, F.body("ITEM", "LOGIN_REPAIRED"), expecting: .ok)
            try await T.post(client, F.body(), expecting: .ok)
        }
        try await f.settled()
        // Room for a second sync, had the heal queued its own.
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await f.link().status == .connected)
        #expect(f.syncs == 1)
        #expect(f.plaid.count("/item/get") == 2)
    }

    @Test("A new kid from Plaid: the cached keys with no expired_at are asked again on their next use, and a retired one is refused")
    func rotationRefreshesOtherKeys() async throws {
        let start = Date()
        let clock = TestClock(start)
        let newKey = P256.Signing.PrivateKey()
        let newKid = "6c5516e1-92dc-479e-a8ff-5a51992e0002"
        let f = try await F.fixture(F.provider(key: [F.jwk(), F.jwk(newKey, kid: newKid), F.jwk(expiredAt: start)]), clock: { clock.now })
        let body = F.body()
        try await f.app.test(.router) { client in
            try await T.post(client, body, jwt: F.jwt(body, iat: clock.now), expecting: .ok)
            clock.set(start.addingTimeInterval(11))
            try await T.post(client, body, jwt: F.jwt(body, iat: clock.now, kid: newKid, key: newKey), expecting: .ok)
            // The first key, asked again within its day because a new kid came: Plaid has retired it.
            clock.set(start.addingTimeInterval(22))
            try await T.post(client, body, jwt: F.jwt(body, iat: clock.now), expecting: .unauthorized)
            // The new key, fetched after the rotation, isn't asked again.
            clock.set(start.addingTimeInterval(33))
            try await T.post(client, body, jwt: F.jwt(body, iat: clock.now, kid: newKid, key: newKey), expecting: .ok)
        }
        #expect(f.fetches == 3)
    }
}
