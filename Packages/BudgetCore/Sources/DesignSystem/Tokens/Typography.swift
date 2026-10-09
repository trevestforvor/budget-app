import SwiftUI

/// Three voices:
/// - a light serif for emotive statements and headline numbers (New York),
/// - a neo-grotesque sans for UI (SF Pro, with its own optical tracking — no extra tracking added),
/// - an uppercase monospace for technical labels and data (SF Mono).
/// System faces keep Dynamic Type, optical sizes, localization and licensing free; no fonts are bundled.
public enum DSTextStyle: CaseIterable, Sendable {
    case displayXL, display, title, headline
    case body, bodyEmphasis, callout, calloutEmphasis, label, caption
    case eyebrow, mono, code, axis
    case amountXL, amount, amountRow

    var baseSize: CGFloat {
        switch self {
        case .displayXL, .amountXL: 56
        case .display: 40
        case .title, .amount: 28
        case .headline: 20
        case .body, .bodyEmphasis, .amountRow: 16
        case .callout, .calloutEmphasis, .code: 14
        case .label: 13
        case .caption, .mono: 12
        case .eyebrow, .axis: 11
        }
    }

    var weight: Font.Weight {
        switch self {
        // Light only at display sizes; at 28 a light serif goes thin on an OLED screen.
        case .displayXL, .display, .amountXL: .light
        case .title, .amount, .headline, .body, .callout, .caption, .code, .axis: .regular
        case .bodyEmphasis, .calloutEmphasis, .label, .amountRow, .eyebrow, .mono: .medium
        }
    }

    var design: Font.Design {
        switch self {
        case .displayXL, .display, .title, .headline, .amountXL, .amount: .serif
        case .eyebrow, .mono, .code, .axis: .monospaced
        case .body, .bodyEmphasis, .callout, .calloutEmphasis, .label, .caption, .amountRow: .default
        }
    }

    var relativeTextStyle: Font.TextStyle {
        switch self {
        case .displayXL, .display, .amountXL: .largeTitle
        case .title, .amount: .title
        case .headline: .title3
        case .body, .bodyEmphasis, .amountRow: .body
        case .callout, .calloutEmphasis, .code: .callout
        case .label, .mono: .footnote
        case .caption: .caption
        case .eyebrow, .axis: .caption2
        }
    }

    var tracking: CGFloat {
        switch self {
        case .displayXL, .amountXL: -1.4
        case .display: -0.9
        case .title, .amount: -0.3
        case .headline: -0.2
        case .eyebrow: 1.3
        case .mono: 0.2
        default: 0
        }
    }

    var isUppercase: Bool { self == .eyebrow }
    /// Tabular figures, so columns of amounts line up. The hero (`amountXL`) keeps proportional
    /// lining figures: it stands alone, and tabular ones gap at 56pt.
    var usesMonospacedDigits: Bool { [.amount, .amountRow, .mono, .code, .axis].contains(self) }
}

struct DSFontModifier: ViewModifier {
    let style: DSTextStyle
    @ScaledMetric private var size: CGFloat
    /// The eyebrow's sans fallback at accessibility sizes, scaled as a caption.
    @ScaledMetric(relativeTo: .caption) private var fallbackSize: CGFloat = 12
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(style: DSTextStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.baseSize, relativeTo: style.relativeTextStyle)
    }

    func body(content: Content) -> some View {
        // At accessibility sizes the uppercase monospace is so wide a label breaks mid-word; the
        // eyebrow switches to the sans caption voice, as `DSTag` does.
        let sansEyebrow = style == .eyebrow && dynamicTypeSize.isAccessibilitySize
        var font = sansEyebrow
            ? Font.system(size: fallbackSize, weight: .medium, design: .default)
            : Font.system(size: size, weight: style.weight, design: style.design)
        if style.usesMonospacedDigits { font = font.monospacedDigit() }
        return content
            .font(font)
            .tracking(sansEyebrow ? 0.4 : style.tracking)
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}

extension View {
    /// Applies a design-system text style that scales with Dynamic Type.
    public func dsFont(_ style: DSTextStyle) -> some View {
        modifier(DSFontModifier(style: style))
    }
}
