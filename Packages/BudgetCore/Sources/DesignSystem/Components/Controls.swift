import SwiftUI

/// Buttons. White-on-black is the only primary action; everything else recedes.
public struct DSButtonStyle: ButtonStyle {
    public enum Variant: Sendable {
        /// White fill, black ink, trailing arrow. One per screen.
        case primary
        /// Transparent with a hairline ink border.
        case secondary
        /// Cyan fill for data-flavored actions ("Ask", "Run plan").
        case accent
        /// Text-only cyan link.
        case quiet
    }

    let variant: Variant
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(variant: Variant, fullWidth: Bool = false) {
        self.variant = variant
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DSSpace.xs) {
            configuration.label
            if variant == .primary {
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .accessibilityHidden(true)
            }
        }
        .dsFont(variant == .quiet ? .callout : .bodyEmphasis)
        .foregroundStyle(foreground)
        .padding(.horizontal, variant == .quiet ? 0 : 18)
        .padding(.vertical, variant == .quiet ? 0 : 12)
        .frame(minHeight: 44)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .background {
            if let background {
                RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).fill(background)
            }
        }
        .overlay {
            if variant == .secondary {
                RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                    .strokeBorder(Color.ds.hairlineStrong, lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
        .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .primary, .accent: Color.ds.inkInverse
        case .secondary: Color.ds.ink
        case .quiet: Color.ds.accent
        }
    }

    private var background: Color? {
        switch variant {
        case .primary: Color.ds.ink
        case .accent: Color.ds.accent
        case .secondary, .quiet: nil
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    public static func ds(_ variant: DSButtonStyle.Variant, fullWidth: Bool = false) -> DSButtonStyle {
        DSButtonStyle(variant: variant, fullWidth: fullWidth)
    }
}

/// Filter / suggestion chip. Selected state is a white fill — obvious without animation.
public struct DSChip: View {
    private let title: String
    private let systemImage: String?
    private let isSelected: Bool
    private let action: () -> Void

    public init(_ title: String, systemImage: String? = nil, isSelected: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            DSChipLabel(title, systemImage: systemImage, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The look of a chip without the button, so a `Menu` label can sit in a row of chips:
/// `Menu { … } label: { DSChipLabel("Newest", trailingSystemImage: "chevron.down") }`.
public struct DSChipLabel: View {
    private let title: String
    private let systemImage: String?
    private let trailingSystemImage: String?
    private let isSelected: Bool

    public init(_ title: String, systemImage: String? = nil, trailingSystemImage: String? = nil, isSelected: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.trailingSystemImage = trailingSystemImage
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
            }
            Text(title).dsFont(.callout)
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage).imageScale(.small).accessibilityHidden(true)
            }
        }
        .foregroundStyle(isSelected ? Color.ds.inkInverse : Color.ds.inkSoft)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                .fill(isSelected ? Color.ds.ink : Color.ds.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                .strokeBorder(isSelected ? Color.clear : Color.ds.hairlineStrong, lineWidth: 1)
        }
        .frame(minHeight: 44) // the hit target is 44pt tall whatever the text size; the chip itself stays compact
        .contentShape(Rectangle())
    }
}

/// Small monospace tag, 4pt radius — the smallest shape in the system.
///
/// At accessibility text sizes a tag with words switches from the uppercase monospace to the sans callout voice:
/// the monospace is so wide there that a word would break mid-letter in a row's trailing slot, while the sans
/// wraps between words.
public struct DSTag: View {
    private let text: String?
    private let systemImage: String?
    private let tint: Color
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ text: String, systemImage: String? = nil, tint: Color = Color.ds.inkSecondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    /// Icon only, for a status the row already says in words to VoiceOver (e.g. `eye.slash` for hidden).
    public init(systemImage: String, tint: Color = Color.ds.inkSecondary) {
        self.text = nil
        self.systemImage = systemImage
        self.tint = tint
    }

    /// "Over" said in words. Caution is also a category tone (orchid), so an over-target state
    /// never relies on colour alone: pair the caution tint with this tag or a marker.
    public static func over(_ text: String = "Over") -> DSTag {
        DSTag(text, systemImage: "exclamationmark", tint: Color.ds.caution)
    }

    public var body: some View {
        if let text, dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).fontWeight(.semibold).accessibilityHidden(true)
                }
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .dsFont(.callout)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background { RoundedRectangle(cornerRadius: DSRadius.tag, style: .continuous).fill(tint.opacity(0.12)) }
        } else {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: text == nil ? 10 : 9, weight: .semibold))
                        .accessibilityHidden(text != nil)
                }
                if let text {
                    Text(text).dsFont(.eyebrow)
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, text == nil ? 5 : 6)
            .padding(.vertical, 3)
            .background { RoundedRectangle(cornerRadius: DSRadius.tag, style: .continuous).fill(tint.opacity(0.12)) }
        }
    }
}

/// How sure the categorizer is. Thresholds come from the server; this only renders the level.
public enum DSConfidence: Sendable, Equatable {
    /// Filed with high confidence by memory, a rule, or the person.
    case auto
    case likely
    /// Accepted automatically by the decision model — shown so it's easy to overrule.
    case decided
    case review

    public var label: String {
        switch self {
        case .auto: "Auto"
        case .likely: "Likely"
        case .decided: "Decided"
        case .review: "Review"
        }
    }

    public var tint: Color {
        switch self {
        case .auto: Color.ds.accent
        case .likely: Color.ds.azure
        case .decided: Color.ds.iris
        case .review: Color.ds.orchid
        }
    }

    var symbol: String {
        switch self {
        case .auto: "checkmark"
        case .likely: "circle.dotted"
        case .decided: "sparkle"
        case .review: "questionmark"
        }
    }
}

public struct DSConfidenceBadge: View {
    private let confidence: DSConfidence
    private let percent: Int?

    public init(_ confidence: DSConfidence, percent: Int? = nil) {
        self.confidence = confidence
        self.percent = percent
    }

    public var body: some View {
        DSTag(percent.map { "\(confidence.label) \($0)%" } ?? confidence.label,
              systemImage: confidence.symbol,
              tint: confidence.tint)
            .accessibilityLabel("Categorization: \(confidence.label)\(percent.map { ", \($0) percent confident" } ?? "")")
    }
}

/// Where the data was processed. Makes the privacy boundary visible, not just promised.
public struct DSPrivacyBadge: View {
    public enum State: Sendable { case local, aggregatesOnly, cached, updating, unreachable, demo }

    private let state: State

    public init(_ state: State) { self.state = state }

    public var body: some View {
        switch state {
        case .local: DSTag("On your Olares", systemImage: "lock.fill", tint: Color.ds.accent)
        case .aggregatesOnly: DSTag("Aggregates only", systemImage: "lock.shield", tint: Color.ds.azure)
        case .cached: DSTag("Offline copy", systemImage: "icloud.slash", tint: Color.ds.inkSecondary)
        // The copy saved on the phone, on screen while the fresh numbers load.
        case .updating: DSTag("Updating", systemImage: "arrow.triangle.2.circlepath", tint: Color.ds.inkSecondary)
        // Nothing loaded and nothing saved: never the reassuring "On your Olares" above "Can't reach your ledger".
        case .unreachable: DSTag("Olares offline", systemImage: "wifi.slash", tint: Color.ds.amber)
        case .demo: DSTag("Demo ledger", systemImage: "testtube.2", tint: Color.ds.iris)
        }
    }
}

/// Thin budget bar. Over target is never told by colour alone — caution is also the orchid
/// category tone — so an over bar rescales: the target becomes a notch with a white tick,
/// the part within target keeps its tint, and the overage past the notch turns caution.
/// Pair it with `DSTag.over()` in the row.
public struct DSProgressBar: View {
    private let fraction: Double
    private let tint: Color

    /// - Parameter fraction: 0...∞ where 1 is "on target". Values above 1 render as over.
    public init(fraction: Double, tint: Color = Color.ds.accent) {
        self.fraction = fraction
        self.tint = tint
    }

    /// True when `fraction` is past the target — for callers deciding whether to add `DSTag.over()`.
    public nonisolated static func isOver(_ fraction: Double) -> Bool { fraction > 1 }

    /// Where the target sits along the bar, 0...1: the far end until spending passes it,
    /// then pulled back so the whole bar is what was spent.
    nonisolated static func targetPosition(for fraction: Double) -> Double {
        isOver(fraction) ? 1 / fraction : 1
    }

    /// How much of the bar is filled, 0...1.
    nonisolated static func filled(for fraction: Double) -> Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : (fraction > 0 ? 1 : 0)
    }

    public var body: some View {
        let isOver = Self.isOver(fraction) && fraction.isFinite
        GeometryReader { proxy in
            let width = proxy.size.width
            let notch = width * Self.targetPosition(for: fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ds.hairlineStrong)
                if isOver {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.ds.caution)
                        Capsule().fill(tint).frame(width: notch)
                        // Cut a gap at the target so the tick reads even when tint == caution.
                        Rectangle()
                            .frame(width: 4)
                            .offset(x: notch - 2)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                } else {
                    Capsule()
                        .fill(tint)
                        .frame(width: width * Self.filled(for: fraction))
                }
            }
            .overlay(alignment: .leading) {
                // In an overlay so the tall tick doesn't change the bar's layout height.
                if isOver {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.ds.ink)
                        .frame(width: 2, height: 10)
                        .offset(x: notch - 1)
                }
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(isOver ? "Over target, \(Int(fraction * 100)) percent" : "\(Int(Self.filled(for: fraction) * 100)) percent")
    }
}

/// "Ask about this": a small sparkle button in a card header that opens Ask with a question
/// already written. Iris marks it as the AI surface, like the ask field.
public struct DSAskButton: View {
    private let label: String
    private let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32

    /// - Parameter label: what the question is about; VoiceOver reads "Ask about <label>".
    public init(label: String, action: @escaping () -> Void) {
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "sparkle")
                .font(.system(size: side * 0.44, weight: .medium))
                .foregroundStyle(Color.ds.iris)
                .frame(width: side, height: side)
                .overlay {
                    RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                        .strokeBorder(Color.ds.hairlineStrong, lineWidth: 1)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask about \(label)")
    }
}

/// A tinted line that says something needs you — "2 accounts need attention" — and goes there.
/// Tint is caution by default; the words carry the meaning, the colour only draws the eye.
public struct DSAttentionPill: View {
    private let title: String
    private let tint: Color
    private let action: () -> Void

    public init(_ title: String, tint: Color = Color.ds.caution, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpace.xs) {
                Circle().fill(tint).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(title)
                    .dsFont(.callout)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, DSSpace.sm)
            .padding(.vertical, DSSpace.xs)
            .frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).fill(tint.opacity(0.14))
            }
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Steps through months: `‹ September 2026 ›`. Forward stops at `latest` (normally this month),
/// back stops at `earliest` when there's no data before it. The selection is always a month start.
public struct DSMonthSwitcher: View {
    @Binding private var month: Date
    private let earliest: Date?
    private let latest: Date
    private let calendar: Calendar

    public init(month: Binding<Date>, earliest: Date? = nil, latest: Date = .now, calendar: Calendar = .current) {
        _month = month
        self.earliest = earliest
        self.latest = latest
        self.calendar = calendar
    }

    /// The month `offset` months from `month`, or nil when that leaves `earliest...latest`.
    nonisolated static func step(_ month: Date, by offset: Int, earliest: Date?, latest: Date, calendar: Calendar) -> Date? {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let target = calendar.date(byAdding: .month, value: offset, to: start),
              let last = calendar.dateInterval(of: .month, for: latest)?.start else { return nil }
        if target > last { return nil }
        if let earliest, let first = calendar.dateInterval(of: .month, for: earliest)?.start, target < first { return nil }
        return target
    }

    private func go(_ offset: Int) {
        guard let target = Self.step(month, by: offset, earliest: earliest, latest: latest, calendar: calendar) else { return }
        withAnimation(DSMotion.standard) { month = target }
    }

    private func style(_ base: Date.FormatStyle) -> Date.FormatStyle {
        var style = base
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return style
    }

    public var body: some View {
        let canGoBack = Self.step(month, by: -1, earliest: earliest, latest: latest, calendar: calendar) != nil
        let canGoForward = Self.step(month, by: 1, earliest: earliest, latest: latest, calendar: calendar) != nil
        let monthName = month.formatted(style(Date.FormatStyle().month(.wide)))
        let year = month.formatted(style(Date.FormatStyle().year()))
        HStack(spacing: DSSpace.xs) {
            chevron("chevron.left", label: "Previous month", enabled: canGoBack) { go(-1) }
            Spacer(minLength: 0)
            // Month and year on one line; stacked when a large text size won't fit them side by side.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(monthName).foregroundStyle(Color.ds.ink)
                    Text(year).foregroundStyle(Color.ds.inkTertiary)
                }
                VStack(spacing: 0) {
                    Text(monthName).foregroundStyle(Color.ds.ink)
                    Text(year).foregroundStyle(Color.ds.inkTertiary)
                }
            }
            .dsFont(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(monthName) \(year)")
            .accessibilityAddTraits(.isHeader)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: go(1)
                case .decrement: go(-1)
                @unknown default: break
                }
            }
            Spacer(minLength: 0)
            chevron("chevron.right", label: "Next month", enabled: canGoForward) { go(1) }
        }
    }

    private func chevron(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ds.inkSoft)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }
}
