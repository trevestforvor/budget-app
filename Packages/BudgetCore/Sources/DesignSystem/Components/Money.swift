import SwiftUI

/// Formats an amount the design-system way. The design system never computes money —
/// callers pass the value the ledger returned.
public enum DSAmountFormat {
    public enum Sign: Sendable {
        /// "−$12.00" for negatives, "$12.00" otherwise.
        case automatic
        /// Magnitude only — for contexts where the label already says "spent".
        case magnitude
        /// "+$12.00" for positives, "$12.00" for negatives (ledger outflows shown as plain spend).
        case inflowPlus
    }

    public static func string(_ value: Decimal, currencyCode: String, sign: Sign = .automatic, fractionDigits: Int = 2, locale: Locale = .autoupdatingCurrent) -> String {
        let magnitude = value < 0 ? -value : value
        let body = magnitude.formatted(.currency(code: currencyCode).precision(.fractionLength(fractionDigits)).locale(locale))
        switch sign {
        case .automatic: return value < 0 ? "−" + body : body
        case .magnitude: return body
        case .inflowPlus: return value > 0 ? "+" + body : body
        }
    }

    /// Splits "$12,480.32" into ("$12,480", ".32") for hero numbers with small cents.
    static func split(_ value: Decimal, currencyCode: String, locale: Locale = .autoupdatingCurrent) -> (whole: String, fraction: String) {
        let full = string(value, currencyCode: currencyCode, sign: .automatic, locale: locale)
        let separator = locale.decimalSeparator ?? "."
        guard let range = full.range(of: separator, options: .backwards) else { return (full, "") }
        return (String(full[..<range.lowerBound]), String(full[range.lowerBound...]))
    }
}

/// An amount in running UI (rows, stat blocks).
public struct DSAmountText: View {
    public enum Size: Sendable { case row, title, display }

    private let value: Decimal
    private let currencyCode: String
    private let size: Size
    private let sign: DSAmountFormat.Sign
    private let tintsInflow: Bool
    private let emphasis: DSEmphasis

    /// - Parameter emphasis: `.muted` drops to `inkSecondary` and never tints inflow — for rows that don't count.
    public init(_ value: Decimal, currencyCode: String = "USD", size: Size = .row, sign: DSAmountFormat.Sign = .automatic, tintsInflow: Bool = false,
                emphasis: DSEmphasis = .normal) {
        self.value = value
        self.currencyCode = currencyCode
        self.size = size
        self.sign = sign
        self.tintsInflow = tintsInflow
        self.emphasis = emphasis
    }

    public var body: some View {
        Text(DSAmountFormat.string(value, currencyCode: currencyCode, sign: sign))
            .dsFont(style)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private var foreground: Color {
        if emphasis == .muted { return Color.ds.inkSecondary }
        return tintsInflow && value > 0 ? Color.ds.inflow : Color.ds.ink
    }

    private var style: DSTextStyle {
        switch size {
        case .row: .amountRow
        case .title: .amount
        case .display: .amountXL
        }
    }
}

/// The hero number: whisper-weight serif with superior cents — set smaller, raised toward the cap
/// height and in secondary ink, as prices are in print. The whole dollars roll digit by digit when
/// the value changes.
public struct DSHeroAmount: View {
    private let label: String
    private let value: Decimal
    private let currencyCode: String
    private let caption: String?
    private let captionTint: Color
    /// `amountXL`'s size, scaled, so the cents follow Dynamic Type with it.
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 56

    /// The cents' size and lift against the whole dollars.
    nonisolated static let centsScale: CGFloat = 0.58
    nonisolated static let centsLift: CGFloat = 0.36

    public init(label: String, value: Decimal, currencyCode: String = "USD", caption: String? = nil, captionTint: Color = Color.ds.inkSecondary) {
        self.label = label
        self.value = value
        self.currencyCode = currencyCode
        self.caption = caption
        self.captionTint = captionTint
    }

    public var body: some View {
        let parts = DSAmountFormat.split(value, currencyCode: currencyCode)
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSEyebrow(label)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(parts.whole)
                    .dsFont(.amountXL)
                    .foregroundStyle(Color.ds.ink)
                    .contentTransition(.numericText(value: NSDecimalNumber(decimal: value).doubleValue))
                Text(parts.fraction)
                    .font(.system(size: heroSize * Self.centsScale, weight: .light, design: .serif))
                    .baselineOffset(heroSize * Self.centsLift)
                    .foregroundStyle(Color.ds.inkSecondary)
            }
            .animation(DSMotion.standard, value: value)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            if let caption {
                Text(caption)
                    .dsFont(.callout)
                    .foregroundStyle(captionTint)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([DSAmountFormat.string(value, currencyCode: currencyCode), caption].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Eyebrow + number + footnote, for "this month" rows.
public struct DSStatBlock: View {
    private let label: String
    private let value: Decimal
    private let currencyCode: String
    private let footnote: String?
    private let tint: Color

    public init(label: String, value: Decimal, currencyCode: String = "USD", footnote: String? = nil, tint: Color = Color.ds.ink) {
        self.label = label
        self.value = value
        self.currencyCode = currencyCode
        self.footnote = footnote
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSEyebrow(label)
            Text(DSAmountFormat.string(value, currencyCode: currencyCode, sign: .automatic, fractionDigits: 0))
                .dsFont(.amount)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let footnote {
                Text(footnote).dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
