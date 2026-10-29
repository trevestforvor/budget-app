import Foundation

extension PlaidSource {
    /// Whether Plaid offers card bills at this Item's institution, independently of the Item's consent.
    /// A missing or incomplete product list is unknown, never evidence that the bank doesn't support them.
    /// Passing an institution id already read from Plaid avoids another `/item/get` request.
    public func supportsLiabilities(institutionID: String? = nil) async throws -> Bool? {
        let resolvedID: String?
        if let institutionID, !institutionID.isEmpty {
            resolvedID = institutionID
        } else {
            let item = try await item()
            // Products already used or available on the Item are positive evidence. Their absence isn't
            // negative evidence: consent and institution support are separate questions.
            if item.billedProducts.contains(Self.liabilitiesProduct) || item.availableProducts.contains(Self.liabilitiesProduct) {
                return true
            }
            resolvedID = item.institutionID
        }
        guard let resolvedID, !resolvedID.isEmpty else { return nil }

        let json: JSONValue
        do {
            json = try await transport.json(try Self.request(environment, "institutions/get_by_id", [
                "institution_id": .string(resolvedID),
                "country_codes": .array([.string("US")]),
            ], credentials))
        } catch let error as SourceHTTPError {
            throw PlaidAPIError(error) ?? error
        }
        guard case let .object(response) = json,
              case let .object(institution)? = response["institution"],
              case let .array(products)? = institution["products"] else { return nil }
        var supported: [String] = []
        for product in products {
            guard case let .string(name) = product else { return nil }
            supported.append(name)
        }
        return supported.contains(Self.liabilitiesProduct)
    }
}
