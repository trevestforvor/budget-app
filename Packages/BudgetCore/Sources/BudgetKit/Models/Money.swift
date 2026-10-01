import Foundation

/// Money in integer minor units. The client never derives totals from these —
/// every total arrives from the ledger. Arithmetic exists for the demo ledger and tests.
public struct Money: Hashable, Sendable, Comparable {
    public var minorUnits: Int64
    public var currencyCode: String

    public init(minorUnits: Int64, currencyCode: String = "USD") {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
    }

    public init(_ decimal: Decimal, currencyCode: String = "USD") {
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .bankers)
        self.init(minorUnits: NSDecimalNumber(decimal: rounded).int64Value, currencyCode: currencyCode)
    }

    public static let zero = Money(minorUnits: 0)

    public var decimal: Decimal { Decimal(minorUnits) / 100 }
    public var doubleValue: Double { Double(minorUnits) / 100 }
    public var isNegative: Bool { minorUnits < 0 }
    public var magnitude: Money { Money(minorUnits: Swift.abs(minorUnits), currencyCode: currencyCode) }

    /// Two currencies don't add without an exchange rate, and trapping here took the whole process down every time it
    /// loaded a ledger holding both. Ingest sets other currencies aside (`Ledger.homeCurrency`), so they shouldn't meet;
    /// if they do, a zero takes the other side's currency and anything else adds in the left side's.
    public static func + (lhs: Money, rhs: Money) -> Money {
        let currency = lhs.minorUnits == 0 && rhs.minorUnits != 0 ? rhs.currencyCode : lhs.currencyCode
        return Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currencyCode: currency)
    }

    public static func - (lhs: Money, rhs: Money) -> Money { lhs + -rhs }

    public static prefix func - (value: Money) -> Money {
        Money(minorUnits: -value.minorUnits, currencyCode: value.currencyCode)
    }

    public static func < (lhs: Money, rhs: Money) -> Bool { lhs.minorUnits < rhs.minorUnits }

    /// The user's locale — except in a server container with no locale set (POSIX), where
    /// Foundation would print "US$150"; the ledger speaks en_US there.
    public static var defaultLocale: Locale {
        let current = Locale.autoupdatingCurrent
        let id = current.identifier
        // Containers without LANG report en_001 ("World English", region 001), which prints "US$".
        let region = current.region?.identifier
        return id.isEmpty || id == "en_US_POSIX" || id == "C" || id == "POSIX" || region == nil || region == "001" ? Locale(identifier: "en_US") : current
    }

    public func formatted(fractionDigits: Int = 2, locale: Locale = Money.defaultLocale) -> String {
        let body = magnitude.decimal.formatted(.currency(code: currencyCode).precision(.fractionLength(fractionDigits)).locale(locale))
        return isNegative ? "−" + body : body
    }
}

extension Money: Codable {
    private enum CodingKeys: String, CodingKey { case minor, currency }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(minorUnits: try c.decode(Int64.self, forKey: .minor), currencyCode: try c.decode(String.self, forKey: .currency))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(minorUnits, forKey: .minor)
        try c.encode(currencyCode, forKey: .currency)
    }
}

extension Sequence where Element == Money {
    public func sum(currencyCode: String = "USD") -> Money {
        reduce(Money(minorUnits: 0, currencyCode: currencyCode), +)
    }
}

extension Array where Element == String {
    /// "a", "a and b", "a, b and c" — `ListFormatter` isn't available on Linux.
    var spokenList: String {
        switch count {
        case 0: ""
        case 1: self[0]
        default: dropLast().joined(separator: ", ") + " and " + last!
        }
    }
}
