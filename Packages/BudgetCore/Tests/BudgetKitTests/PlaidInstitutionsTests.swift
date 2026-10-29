import Foundation
import Testing
@testable import BudgetKit

@Suite("Plaid institution card-bill support")
struct PlaidInstitutionsTests {
    private func source(_ transport: any HTTPTransport) -> PlaidSource {
        PlaidSource(environment: .sandbox, credentials: .init(clientID: "cid", secret: "sec"),
                    accessToken: "access-test-1", institution: "Test Bank", transport: transport)
    }

    @Test("Institution support is checked independently of consent, with authenticated metadata and no Item token",
          arguments: [(#"["transactions", "liabilities"]"#, true), (#"["transactions"]"#, false), ("[]", false)])
    func knownInstitution(products: String, expected: Bool) async throws {
        let transport = StatusTransport([
            "/institutions/get_by_id": (200, #"{"institution":{"products":\#(products)}}"#),
        ])
        #expect(try await source(transport).supportsLiabilities(institutionID: "ins-test-1") == expected)
        #expect(transport.paths == ["/institutions/get_by_id"])
        guard case let .object(body)? = transport.body(of: "/institutions/get_by_id") else {
            Issue.record("no institution request"); return
        }
        #expect(body["institution_id"] == .string("ins-test-1"))
        #expect(body["country_codes"] == .array([.string("US")]))
        #expect(body["client_id"] == .string("cid"))
        #expect(body["secret"] == .string("sec"))
        #expect(body["access_token"] == nil)
        #expect(transport.requests.first?.url?.host == "sandbox.plaid.com")
    }

    @Test("An older Item without product metadata resolves the institution before deciding support")
    func resolveInstitution() async throws {
        let transport = StatusTransport([
            "/item/get": (200, #"{"item":{"institution_id":"ins-test-1"}}"#),
            "/institutions/get_by_id": (200, #"{"institution":{"products":["transactions"]}}"#),
        ])
        #expect(try await source(transport).supportsLiabilities() == false)
        #expect(transport.paths == ["/item/get", "/institutions/get_by_id"])
    }

    @Test("An Item with no institution id has unknown support")
    func missingInstitution() async throws {
        let transport = StatusTransport(["/item/get": (200, #"{"item":{}}"#)])
        #expect(try await source(transport).supportsLiabilities() == nil)
        #expect(transport.paths == ["/item/get"])
    }

    @Test("Positive Item product evidence avoids an institution lookup", arguments: ["billed_products", "available_products"])
    func positiveItemEvidence(field: String) async throws {
        let transport = StatusTransport([
            "/item/get": (200, #"{"item":{"institution_id":"ins-test-1","\#(field)":["liabilities"]}}"#),
        ])
        #expect(try await source(transport).supportsLiabilities() == true)
        #expect(transport.paths == ["/item/get"])
    }

    @Test("Missing and malformed institution product metadata stay unknown", arguments: [
        #"{}"#, #"{"institution":{}}"#, #"{"institution":{"products":null}}"#,
        #"{"institution":{"products":"liabilities"}}"#,
        #"{"institution":{"products":["transactions",42]}}"#,
        #"{"institution":{"products":["liabilities",null]}}"#,
    ])
    func incompleteMetadata(body: String) async throws {
        let transport = StatusTransport(["/institutions/get_by_id": (200, body)])
        #expect(try await source(transport).supportsLiabilities(institutionID: "ins-test-1") == nil)
    }

    @Test("Provider errors stay typed and never become unsupported")
    func lookupError() async throws {
        let transport = StatusTransport([
            "/institutions/get_by_id": (400, #"{"error_code":"INVALID_FIELD","error_type":"INVALID_REQUEST","error_message":"A field is invalid","request_id":"req-inst-1"}"#),
        ])
        do {
            _ = try await source(transport).supportsLiabilities(institutionID: "ins-test-1")
            Issue.record("expected an error")
        } catch let error as PlaidAPIError {
            #expect(error.errorCode == "INVALID_FIELD")
            #expect(error.requestID == "req-inst-1")
        }
    }
}
