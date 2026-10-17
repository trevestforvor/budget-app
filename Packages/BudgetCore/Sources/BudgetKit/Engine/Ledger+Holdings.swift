import Foundation

extension Ledger {
    /// Stores each investment account's positions from its provider, keyed by the provider's account id. Only accounts
    /// the ledger holds as investments take them, and each is replaced whole. Returns how many accounts took them.
    @discardableResult
    mutating func applyHoldings(_ byExternal: [String: [SourceHolding]], source: SourceKind, at date: Date) -> Int {
        var stored = 0
        for (external, positions) in byExternal {
            let id = Self.accountID(source, external)
            guard let account = accounts.first(where: { $0.id == id && $0.kind == .investment }) else { continue }
            holdings[id] = Self.accountHoldings(account, positions, at: date)
            stored += 1
        }
        return stored
    }

    /// One account's positions as the ledger keeps them: in the home currency only (another currency is set aside, like
    /// ingest does, and so counts as not itemized), largest first, totalled, with what the balance holds beyond them.
    static func accountHoldings(_ account: Account, _ positions: [SourceHolding], at date: Date) -> AccountHoldings {
        var seen: [String: Int] = [:]
        let kept = positions.filter { $0.marketValue.currencyCode == homeCurrency }.map { p -> Holding in
            // Two lots of one security (or two without an id) still get ids of their own.
            let key = account.id + "|" + (p.securityID ?? p.symbol ?? p.description)
            let n = seen[key, default: 0]
            seen[key] = n + 1
            return Holding(id: StableHash.short(n == 0 ? key : "\(key)#\(n)"), name: p.description, ticker: p.symbol, type: p.type,
                           quantity: p.quantity, price: p.price, priceAsOf: p.priceAsOf, value: p.marketValue, costBasis: p.costBasis,
                           isCash: p.isCash)
        }
        .sorted { ($0.value, $1.name) > ($1.value, $0.name) }
        let total = kept.map(\.value).sum()
        return AccountHoldings(id: account.id, holdings: kept, total: total, fetchedAt: date,
                               unitemized: unitemized(balance: account.balance, total: total))
    }

    /// The balance less the positions, when it's more than $1 and more than 1% of the balance: cash or positions the
    /// broker didn't list. Less than that is rounding, and positions worth more than the balance aren't explained here.
    static func unitemized(balance: Money, total: Money) -> Money? {
        let gap = balance - total
        return gap.minorUnits > 100 && gap.minorUnits * 100 > balance.minorUnits.magnitude ? gap : nil
    }
}
