import Foundation

/// Dollar amounts in text read off a price tag or a screenshot.
public enum PriceText {
    /// A dollar sign, or cents, marks a price; a bare whole number ("1299", "12 oz") is a SKU or a quantity and is left
    /// out. Digits or a decimal point right before or after mean it's part of something longer.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\d.,])(\$\s?)?(\d{1,3}(?:,\d{3})+|\d+)(\.\d{2})?(?![\d]|\.\d)"#)

    /// Every price in `text`, in the order found: "$1,299.99", "12.99", "$5".
    public static func amounts(in text: String) -> [Decimal] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            let hasSign = match.range(at: 1).location != NSNotFound
            let hasCents = match.range(at: 3).location != NSNotFound
            guard hasSign || hasCents, let whole = Range(match.range(at: 2), in: text) else { return nil }
            var digits = text[whole].replacingOccurrences(of: ",", with: "")
            if hasCents, let cents = Range(match.range(at: 3), in: text) { digits += text[cents] }
            guard let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
            return value
        }
    }

    /// The prices in lines of recognized text, most likely first: the one printed biggest leads, since a tag or a
    /// product page sets its price larger than the per-ounce price, the old price or the shipping. Each price once.
    /// - Parameter lines: each line's text and its height (any unit, the same for every line).
    public static func ranked(_ lines: [(text: String, height: Double)]) -> [Decimal] {
        let found = lines.enumerated().flatMap { index, line in
            amounts(in: line.text).map { (amount: $0, height: line.height, order: index) }
        }
        var seen: Set<Decimal> = []
        return found
            .sorted { $0.height != $1.height ? $0.height > $1.height : $0.order < $1.order }
            .compactMap { seen.insert($0.amount).inserted ? $0.amount : nil }
    }
}
