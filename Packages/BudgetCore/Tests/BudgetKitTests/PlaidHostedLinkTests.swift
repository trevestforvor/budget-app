import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BudgetKit

@Suite("Plaid Hosted Link in update mode")
struct PlaidHostedLinkTests {
    static let credentials = PlaidSource.Credentials(clientID: "cid", secret: "sec")
    static let secret = "link-sandbox-SECRET"

    static func outcome(_ json: String) throws -> PlaidSource.LinkSessionOutcome {
        guard case let .object(o) = try JSONValue.parse(Data(json.utf8)) else { throw DecisionError.malformed("test") }
        return PlaidSource.parseLinkSessions(o)
    }

    @Test("A Link session reads as pending, finished or exited, in the current fields and the deprecated ones")
    func sessions() throws {
        #expect(try Self.outcome(#"{"link_sessions": []}"#) == .pending)
        #expect(try Self.outcome(#"{}"#) == .pending)
        #expect(try Self.outcome(#"{"link_sessions": [{"started_at": "2026-10-15T08:31:00Z", "finished_at": null}]}"#) == .pending)
        #expect(try Self.outcome(#"{"link_sessions": [{"finished_at": "x", "on_success": {"public_token": "p"}}]}"#) == .finished)
        #expect(try Self.outcome(#"{"link_sessions": [{"finished_at": "x", "results": {"item_add_results": [{"public_token": "p"}]}}]}"#) == .finished)
        // Finished with neither callback: /item/get decides.
        #expect(try Self.outcome(#"{"link_sessions": [{"finished_at": "x", "results": {"item_add_results": []}}]}"#) == .finished)
        #expect(try Self.outcome(#"{"link_sessions": [{"finished_at": "x", "exit": {"error": null}}]}"#) == .exited(code: nil))
        #expect(try Self.outcome(#"{"link_sessions": [{"finished_at": "x", "on_exit": {"error": {"error_code": "INSTITUTION_NOT_RESPONDING"}}}]}"#)
                == .exited(code: "INSTITUTION_NOT_RESPONDING"))
        // Left once, then came back and finished: success wins.
        #expect(try Self.outcome(#"{"link_sessions": [{"finished_at": "x", "exit": {"error": null}}, {"finished_at": "y", "on_success": {}}]}"#) == .finished)
    }

    @Test("Update mode's token: the access token, empty products, Hosted Link; reauthorization only when asked")
    func body() async throws {
        let transport = StatusTransport(["/link/token/create": (200, #"{"link_token": "\#(Self.secret)", "hosted_link_url": "https://secure.plaid.com/hl/x", "expiration": "2026-10-15T09:00:00Z", "request_id": "req-1"}"#)])
        let link = try await PlaidSource.updateModeLinkToken(
            accessToken: "access-1", environment: .sandbox, credentials: Self.credentials, userID: "owner", redirectURI: "https://b.example/plaid/oauth-return",
            webhook: nil, hostedLink: .init(completionRedirectURI: "budgetapp-plaid://reconnect-done", isMobileApp: true, urlLifetimeSeconds: 900),
            transport: transport)
        #expect(link.linkToken == Self.secret)
        #expect(link.hostedLinkURL == "https://secure.plaid.com/hl/x")
        #expect(link.requestID == "req-1")
        #expect(link.expiresAt == PlaidSource.timestamp("2026-10-15T09:00:00Z"))
        guard case let .object(sent)? = transport.body(of: "/link/token/create") else { Issue.record("no body"); return }
        #expect(sent["access_token"] == .string("access-1"))
        #expect(sent["products"] == .array([]))
        #expect(sent["webhook"] == nil)
        #expect(sent["update"] == nil)
        #expect(sent["additional_consented_products"] == nil)

        _ = try await PlaidSource.updateModeLinkToken(accessToken: "access-1", environment: .sandbox, credentials: Self.credentials, userID: "owner",
                                                      redirectURI: nil, webhook: nil, hostedLink: nil, reauthorization: true, transport: transport)
        guard case let .object(renew)? = transport.body(of: "/link/token/create") else { Issue.record("no body"); return }
        #expect(renew["update"] == .object(["reauthorization_enabled": .bool(true)]))
        #expect(renew["redirect_uri"] == nil)
    }

    @Test("An answer that doesn't parse throws without quoting it; Plaid's error comes back as PlaidAPIError")
    func secretsStayOutOfErrors() async throws {
        let garbled = StatusTransport(["/link/token/get": (200, "{\"link_token\": \"\(Self.secret)\", oops")])
        do {
            _ = try await PlaidSource.linkSession(linkToken: Self.secret, environment: .sandbox, credentials: Self.credentials, transport: garbled)
            Issue.record("parsed a broken body")
        } catch {
            #expect(!String(describing: error).contains("SECRET"))
            #expect(!error.localizedDescription.contains("SECRET"))
        }
        let refused = StatusTransport(["/link/token/create": (400, #"{"error_type": "INVALID_REQUEST", "error_code": "INVALID_FIELD", "error_message": "bad", "request_id": "req-9"}"#)])
        do {
            _ = try await PlaidSource.updateModeLinkToken(accessToken: "a", environment: .sandbox, credentials: Self.credentials, userID: "owner",
                                                          redirectURI: nil, webhook: nil, hostedLink: nil, transport: refused)
            Issue.record("accepted a refusal")
        } catch let error as PlaidAPIError {
            #expect(error.errorCode == "INVALID_FIELD")
            #expect(error.requestID == "req-9")
        }
    }
}
