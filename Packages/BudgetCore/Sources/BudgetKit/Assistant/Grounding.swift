import Foundation

/// Enforces "the model never does math": finds amounts and percentages in model prose that
/// don't appear in tool results. The server rejects (or regenerates) replies with any.
public enum Grounding {
    /// Currency amounts in `text` not found in `allowed`. A whole-dollar mention ("$648")
    /// is accepted when it's the nearest-dollar rounding of an allowed value ("$647.80").
    public static func ungroundedAmounts(in text: String, allowed: [Money]) -> [String] {
        let magnitudes = Set(allowed.map { Swift.abs($0.minorUnits) })
        var problems: [String] = []
        for match in text.matches(of: /\$\s?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?/) {
            guard let whole = Int64(match.1.replacingOccurrences(of: ",", with: "")) else { continue }
            if let centsText = match.2 {
                let cents = Int64(centsText.padding(toLength: 2, withPad: "0", startingAt: 0))!
                if !magnitudes.contains(whole * 100 + cents) { problems.append(String(match.0)) }
            } else if !magnitudes.contains(where: { ($0 + 50) / 100 == whole }) {
                problems.append(String(match.0))
            }
        }
        return problems
    }

    /// Percentages in `text` not found in `allowed`.
    public static func ungroundedPercents(in text: String, allowed: [Int]) -> [String] {
        text.matches(of: /(\d{1,4})\s?%/).compactMap { match in
            guard let value = Int(match.1), !allowed.contains(value) else { return nil }
            return String(match.0)
        }
    }
}
