@testable import BudgetKit
import Foundation
import Testing

@Suite("Plaid /item/get")
struct PlaidItemTests {
    @Test("Reads the Item's error, consent expiry, products, webhook and last transactions update")
    func parse() throws {
        let json = try JSONValue.parse(Data(#"""
        {"item": {"item_id": "item-1", "institution_id": "ins_3", "webhook": "https://budget.example/v1/plaid/webhook",
                  "error": {"error_type": "ITEM_ERROR", "error_code": "ITEM_LOGIN_REQUIRED", "error_message": "login changed", "display_message": null},
                  "billed_products": ["transactions", "investments"], "available_products": ["liabilities"],
                  "consent_expiration_time": "2026-11-03T17:20:13Z"},
         "status": {"transactions": {"last_successful_update": "2026-10-16T09:00:01.123Z", "last_failed_update": null}},
         "request_id": "req-1"}
        """#.utf8))
        let item = try PlaidSource.parseItem(json)
        #expect(item.itemID == "item-1" && item.institutionID == "ins_3" && item.requestID == "req-1")
        #expect(item.error?.errorCode == "ITEM_LOGIN_REQUIRED" && item.error?.errorType == "ITEM_ERROR")
        #expect(item.billedProducts == ["transactions", "investments"] && item.availableProducts == ["liabilities"])
        #expect(item.webhook == "https://budget.example/v1/plaid/webhook")
        #expect(item.consentExpiresAt == Date(timeIntervalSince1970: 1_793_726_413))
        #expect(item.transactionsUpdatedAt.map { abs($0.timeIntervalSince1970 - 1_792_141_201.123) < 0.01 } == true)
    }

    @Test("A healthy Item has no error; missing fields are empty, not a failure")
    func healthy() throws {
        let item = try PlaidSource.parseItem(try JSONValue.parse(Data(#"{"item": {"item_id": "i", "error": null, "webhook": ""}}"#.utf8)))
        #expect(item.error == nil && item.webhook == nil && item.consentExpiresAt == nil && item.billedProducts.isEmpty)
        #expect(throws: (any Error).self) { try PlaidSource.parseItem(try JSONValue.parse(Data(#"{"nope": 1}"#.utf8))) }
    }
}
