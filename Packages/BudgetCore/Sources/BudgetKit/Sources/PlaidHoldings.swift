import Foundation

extension PlaidSource {
    /// `/investments/holdings/get`, grouped by account.
    public func holdings() async throws -> [String: [SourceHolding]] {
        try Self.parseHoldings(try await transport.json(
            try Self.request(environment, "investments/holdings/get", ["access_token": .string(accessToken)], credentials)))
    }

    static func parseHoldings(_ json: JSONValue) throws -> [String: [SourceHolding]] {
        guard case let .object(o) = json, case let .array(holdings)? = o["holdings"] else { throw DecisionError.malformed("no holdings") }
        var securities: [String: (ticker: String?, name: String)] = [:]
        if case let .array(list)? = o["securities"] {
            for case let .object(s) in list {
                if let id = string(s, "security_id") { securities[id] = (string(s, "ticker_symbol"), string(s, "name") ?? "Security") }
            }
        }
        var out: [String: [SourceHolding]] = [:]
        for case let .object(h) in holdings {
            guard let account = string(h, "account_id"), let value = number(h, "institution_value") else { continue }
            let security = string(h, "security_id").flatMap { securities[$0] }
            out[account, default: []].append(SourceHolding(symbol: security?.ticker, description: security?.name ?? "Holding",
                                                          marketValue: money(value, string(h, "iso_currency_code"))))
        }
        return out
    }
}
