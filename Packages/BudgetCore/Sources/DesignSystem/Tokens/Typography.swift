import SwiftUI

/// Three voices, as in Origin:
/// - a light serif for emotive statements and headline numbers (New York stands in for Lyon Display),
/// - a neo-grotesque sans for UI (SF Pro stands in for Suisse Int'l),
/// - an uppercase monospace for technical labels and data (SF Mono stands in for Roboto Mono).
/// System faces keep Dynamic Type, localization and licensing free.
public enum DSTextStyle: CaseIterable, Sendable {
    case displayXL, display, title, headline
    case body, bodyEmphasis, callout, caption
    case eyebrow, mono
    case amountXL, amount, amountRow

    var baseSize: CGFloat {
        switch self {
        case .displayXL, .amountXL: 56
        case .display: 40
        case .title, .amount: 28
        case .headline: 20
        case .body, .bodyEmphasis, .amountRow: 16
        case .callout: 14
        case .caption: 12
        case .eyebrow: 11
        case .mono: 12
        }
    }

    var weight: Font.Weight {
        switch self {
        case .displayXL, .display, .title, .amountXL, .amount: .light
        case .headline, .body, .callout, .caption: .regular
        case .bodyEmphasis, .amountRow, .eyebrow, .mono: .medium
        }
    }

    var design: Font.Design {
        switch self {
        case .displayXL, .display, .title, .headline, .amountXL, .amount: .serif
        case .eyebrow, .mono: .monospaced
        case .body, .bodyEmphasis, .callout, .caption, .amountRow: .default
        }
    }

    var relativeTextStyle: Font.TextStyle {
        switch self {
        case .displayXL, .display, .amountXL: .largeTitle
        case .title, .amount: .title
        case .headline: .title3
        case .body, .bodyEmphasis, .amountRow: .body
        case .callout: .callout
        case .caption: .caption
        case .eyebrow: .caption2
        case .mono: .footnote
        }
    }

    var tracking: CGFloat {
        switch self {
        case .displayXL, .amountXL: -1.2
        case .display: -0.8
        case .title, .amount: -0.4
        case .eyebrow: 1.1
        case .mono: 0.2
        default: 0
        }
    }

    var isUppercase: Bool { self == .eyebrow }
    var usesMonospacedDigits: Bool { [.amountXL, .amount, .amountRow, .mono].contains(self) }
}

struct DSFontModifier: ViewModifier {
    let style: DSTextStyle
    @ScaledMetric private var size: CGFloat

    init(style: DSTextStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTextStyle)
    }

    func body(content: Content) -> some View {
        var font = Font.system(size: size, weight: style.weight, design: style.design)
        if style.usesMonospacedDigits { font = font.monospacedDigit() }
        return content
            .font(font)
            .tracking(style.tracking)
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}

extension View {
    /// Applies a design-system text style that scales with Dynamic Type.
    public func dsFont(_ style: DSTextStyle) -> some View {
        modifier(DSFontModifier(style: style))
    }
}
