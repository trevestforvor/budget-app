import Foundation

extension PlaidSource {
    /// The product name Plaid uses for holdings (`billed_products`).
    public static let investmentsProduct = "investments"

    /// `/investments/holdings/get`: each investment account's positions by Plaid account id, with the response's
    /// `request_id`. An investment account with no positions comes back empty, so one that sold everything is cleared.
    /// Plaid's errors come back as `PlaidAPIError`, so callers branch on the code.
    public func holdingsReport() async throws -> (holdings: [String: [SourceHolding]], requestID: String?) {
        do {
            return try Self.parseHoldings(try await transport.json(
                try Self.request(environment, "investments/holdings/get", ["access_token": .string(accessToken)], credentials)))
        } catch let error as SourceHTTPError {
            throw PlaidAPIError(error) ?? error
        }
    }

    /// `/investments/holdings/get`, grouped by account.
    public func holdings() async throws -> [String: [SourceHolding]] { try await holdingsReport().holdings }

    /// Holdings joined to the securities in the same response (names and tickers live only there). Every field but the
    /// account and the broker's value may be missing at some institution, and each is read on its own. A position in
    /// another currency keeps its code, so the ledger can set it aside.
    static func parseHoldings(_ json: JSONValue) throws -> (holdings: [String: [SourceHolding]], requestID: String?) {
        guard case let .object(o) = json, case let .array(holdings)? = o["holdings"] else { throw DecisionError.malformed("no holdings") }
        var securities: [String: [String: JSONValue]] = [:]
        if case let .array(list)? = o["securities"] {
            for case let .object(s) in list { if let id = string(s, "security_id") { securities[id] = s } }
        }
        var out: [String: [SourceHolding]] = [:]
        if case let .array(accounts)? = o["accounts"] {
            for case let .object(a) in accounts where ["investment", "brokerage"].contains(string(a, "type")) {
                if let id = string(a, "account_id") { out[id] = [] }
            }
        }
        for case let .object(h) in holdings {
            guard let account = string(h, "account_id"), let value = number(h, "institution_value") else { continue }
            let securityID = string(h, "security_id")
            let security = securityID.flatMap { securities[$0] } ?? [:]
            let code = currency(h)
            let isCash: Bool = if case let .bool(v)? = security["is_cash_equivalent"] { v } else { false }
            let type = string(security, "type")
            let (price, priceAsOf) = fresherPrice(holding: h, security: security, currency: code)
            out[account, default: []].append(SourceHolding(
                symbol: string(security, "ticker_symbol"), description: string(security, "name") ?? string(security, "ticker_symbol") ?? "Holding",
                marketValue: money(value, code), securityID: securityID, quantity: number(h, "quantity").map(decimal),
                price: price, priceAsOf: priceAsOf, costBasis: number(h, "cost_basis").map { money($0, code) }, type: type,
                isCash: isCash || type == "cash"))
        }
        return (out, string(o, "request_id"))
    }

    /// The broker's price or the prior session's close, whichever says it's newer; the broker's when neither or both say
    /// the same, since it matches the value. A price with no date only wins when the other is missing too. A foreign
    /// currency held as cash has its close priced in dollars (INV-007).
    static func fresherPrice(holding h: [String: JSONValue], security s: [String: JSONValue], currency code: String?) -> (Money?, Date?) {
        let institution = number(h, "institution_price").map { (money($0, code), stamp(h, datetime: "institution_price_datetime", day: "institution_price_as_of")) }
        let closeCode = string(s, "type") == "cash" && (currency(s) ?? code).map({ $0 != "USD" }) == true ? "USD" : currency(s) ?? code
        let close = number(s, "close_price").map { (money($0, closeCode), stamp(s, datetime: "update_datetime", day: "close_price_as_of")) }
        switch (institution, close) {
        case let (i?, c?):
            if let closeDate = c.1, i.1.map({ closeDate > $0 }) ?? true { return (c.0, c.1) }
            return (i.0, i.1)
        case let (i?, nil): return (i.0, i.1)
        case let (nil, c?): return (c.0, c.1)
        case (nil, nil): return (nil, nil)
        }
    }

    /// A timestamp from an ISO 8601 date-time, else a plain date.
    static func stamp(_ o: [String: JSONValue], datetime: String, day dayKey: String) -> Date? {
        if let raw = string(o, datetime), let date = try? Date(raw, strategy: .iso8601) { return date }
        return string(o, dayKey).flatMap(day)
    }

    /// A JSON number as the decimal it was written as (12.5 shares, never 12.4999…).
    static func decimal(_ value: Double) -> Decimal { Decimal(string: "\(value)") ?? Decimal(value) }
}
