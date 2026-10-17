import Foundation

/// The demo's holdings, as Plaid Investments would report them this morning: Northwind's brokerage itemizes every
/// position down to its cash sweep, so its positions add up to the balance; Meadow's automated account lists its funds
/// but not the cash it keeps, which shows as not itemized. Tidewater is waiting for a sign-in, so it has none.
extension Ledger {
    mutating func addDemoHoldings() {
        let today = calendar.startOfDay(for: now)
        let close = calendar.date(byAdding: .hour, value: -8, to: today)!
        let fetched = now.addingTimeInterval(-3 * 3600)
        // Written as text: a float literal would make 2,957.55 shares 2,957.5500000000002.
        func position(_ ticker: String?, _ name: String, _ type: String, _ quantity: String, _ unitPrice: String, cost: Decimal?, cash: Bool = false) -> SourceHolding {
            let (shares, price) = (Decimal(string: quantity)!, Decimal(string: unitPrice)!)
            return SourceHolding(symbol: ticker, description: name, marketValue: Money(shares * price), securityID: "demo-\(ticker ?? name)", quantity: shares,
                                 price: Money(price), priceAsOf: close, costBasis: cost.map { Money($0) }, type: type, isCash: cash)
        }
        let byAccount: [String: [SourceHolding]] = [
            "northwind": [
                position("VTI", "Vanguard Total Stock Market ETF", "etf", "72.5", "301.12", cost: 16_400),
                position("AAPL", "Apple Inc.", "equity", "40", "228.40", cost: 6_210),
                position("VXUS", "Vanguard Total International Stock ETF", "etf", "95", "68.05", cost: 5_900),
                position("BND", "Vanguard Total Bond Market ETF", "etf", "60", "72.85", cost: 4_500),
                position("MSFT", "Microsoft Corporation", "equity", "8", "431.20", cost: 2_600),
                position(nil, "Cash sweep", "cash", "2957.55", "1", cost: nil, cash: true),
            ],
            "meadow-inv": [
                position("VTI", "Vanguard Total Stock Market ETF", "etf", "30", "301.12", cost: 7_400),
                position("VEA", "Vanguard FTSE Developed Markets ETF", "etf", "120", "51.30", cost: 5_520),
                position("IJR", "iShares Core S&P Small-Cap ETF", "etf", "35", "115.40", cost: 3_710),
                position("VWO", "Vanguard FTSE Emerging Markets ETF", "etf", "90", "45.10", cost: 3_870),
                position("SCHP", "Schwab U.S. TIPS ETF", "etf", "150", "26.80", cost: 4_110),
                position("VTEB", "Vanguard Tax-Exempt Bond ETF", "etf", "60", "50.20", cost: 3_050),
            ],
        ]
        for (id, positions) in byAccount {
            guard let account = accounts.first(where: { $0.id == id }) else { continue }
            holdings[id] = Self.accountHoldings(account, positions, at: fetched)
        }
    }
}
