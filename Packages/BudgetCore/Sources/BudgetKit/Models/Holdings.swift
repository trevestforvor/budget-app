import Foundation

/// One position in an investment account, as the broker reported it at the last holdings check.
public struct Holding: Identifiable, Hashable, Codable, Sendable {
    /// `StableHash.short(accountID + "|" + securityID)`: no provider id leaves the server.
    public var id: String
    public var name: String
    public var ticker: String?
    public var type: String?
    public var quantity: Decimal?
    public var price: Money?
    public var priceAsOf: Date?
    /// The broker's own figure, consistent with the account balance.
    public var value: Money
    /// The whole position's cost, when the broker knows it.
    public var costBasis: Money?
    public var isCash: Bool

    public init(id: String, name: String, ticker: String? = nil, type: String? = nil, quantity: Decimal? = nil, price: Money? = nil,
                priceAsOf: Date? = nil, value: Money, costBasis: Money? = nil, isCash: Bool = false) {
        self.id = id; self.name = name; self.ticker = ticker; self.type = type; self.quantity = quantity; self.price = price
        self.priceAsOf = priceAsOf; self.value = value; self.costBasis = costBasis; self.isCash = isCash
    }

    public var gain: Money? { costBasis.map { value - $0 } }
}

/// One investment account's positions.
public struct AccountHoldings: Identifiable, Hashable, Codable, Sendable {
    /// The ledger account id.
    public var id: String
    /// By value, largest first.
    public var holdings: [Holding]
    public var total: Money
    public var fetchedAt: Date
    /// Balance − total, when it's more than $1 and 1%: cash or positions the broker didn't itemize.
    public var unitemized: Money?

    public init(id: String, holdings: [Holding], total: Money, fetchedAt: Date, unitemized: Money? = nil) {
        self.id = id; self.holdings = holdings; self.total = total; self.fetchedAt = fetchedAt; self.unitemized = unitemized
    }
}

/// The body of `GET /v1/holdings`.
public struct HoldingsReport: Hashable, Codable, Sendable {
    public var accounts: [AccountHoldings]
    /// The oldest `fetchedAt` among the accounts; nil when there are none.
    public var asOf: Date?

    public init(accounts: [AccountHoldings], asOf: Date? = nil) { self.accounts = accounts; self.asOf = asOf }

    public static let empty = HoldingsReport(accounts: [])
}

/// Positions in investment accounts (server 0.6.0). The demo ledger and the server conform; the phone casts to it.
public protocol HoldingsAPI: Sendable {
    func holdings() async throws -> HoldingsReport
}
