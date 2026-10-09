import SwiftUI

/// Buttons. White is commitment: the pearl primary is the one main action on a screen; everything
/// else recedes. Every variant shares the control radius, a slight give when pressed, and a
/// token-based disabled state (a faint fill and `inkDisabled`), never an opacity fade.
public struct DSButtonStyle: ButtonStyle {
    public enum Variant: Sendable {
        /// White settling to pearl, dark ink, trailing arrow. One per screen.
        case primary
        /// A lit slab: a faint white fill under the lit edge.
        case secondary
        /// A cyan wash for in-card data actions ("Review 4", "Sync now").
        case tinted
        /// The assistant's action ("Ask about this", "Apply"): an iris wash, the AI edge and a sparkle.
        /// Breathes while `isLoading`.
        case ai
        /// Text-only cyan link.
        case quiet
        /// The first tap of a destructive action: a caution outline.
        case destructive
        /// The second tap, which confirms: the caution fill with white ink.
        case destructiveArmed
        /// Liquid Glass, for controls that float over content.
        case glass
    }

    public enum Size: Sendable {
        /// 52pt: full-width sheet and onboarding calls to action.
        case large
        /// 44pt.
        case regular
        /// Drawn 32pt tall inside a 44pt hit area.
        case compact
    }

    let variant: Variant
    let size: Size
    let fullWidth: Bool
    let isLoading: Bool

    public init(variant: Variant, size: Size = .regular, fullWidth: Bool = false, isLoading: Bool = false) {
        self.variant = variant
        self.size = size
        self.fullWidth = fullWidth
        self.isLoading = isLoading
    }

    public func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, variant: variant, size: size, fullWidth: fullWidth, isLoading: isLoading)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: DSButtonStyle.Variant
    let size: DSButtonStyle.Size
    let fullWidth: Bool
    let isLoading: Bool
    @Environment(\.isEnabled) private var isEnabled

    private var isPressed: Bool { configuration.isPressed }
    private var isQuiet: Bool { variant == .quiet }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous) }

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            if let leadingSymbol, isEnabled {
                Image(systemName: leadingSymbol)
                    .font(.system(size: DSIconSize.sm, weight: .semibold))
                    .foregroundStyle(variant == .ai ? Color.ds.iris : foreground)
                    .accessibilityHidden(true)
            }
            configuration.label
            if variant == .primary, isEnabled {
                Image(systemName: "arrow.right")
                    .font(.system(size: DSIconSize.sm, weight: .medium))
                    .accessibilityHidden(true)
            }
        }
        .dsFont(isQuiet ? .callout : size == .compact ? .calloutEmphasis : .bodyEmphasis)
        .foregroundStyle(foreground)
        // Loading hides the label but keeps its width, so the button doesn't jump.
        .opacity(isLoading ? 0 : isQuiet && isPressed ? 0.6 : 1)
        .overlay {
            if isLoading {
                ProgressView().controlSize(.small).tint(foreground)
            }
        }
        .padding(.horizontal, isQuiet ? 0 : horizontalPadding)
        .frame(minHeight: isQuiet ? DSSize.hitTarget : visualHeight)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .background { background }
        .overlay { border }
        .modifier(GlassIfNeeded(isOn: variant == .glass))
        .frame(minHeight: DSSize.hitTarget)
        .contentShape(Rectangle())
        .scaleEffect(isPressed ? 0.98 : 1)
        .animation(DSMotion.press, value: isPressed)
        .sensoryFeedback(trigger: isPressed) { _, pressed in pressed ? haptic : nil }
        .accessibilityValue(isLoading ? "Loading" : "")
    }

    private var leadingSymbol: String? {
        switch variant {
        case .ai: "sparkle"
        case .destructiveArmed: "exclamationmark"
        default: nil
        }
    }

    private var haptic: SensoryFeedback? {
        switch variant {
        case .primary: .impact(weight: .medium)
        case .ai: .impact(weight: .light)
        default: nil
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .large: DSSpace.lg
        case .regular: 18
        case .compact: DSSpace.sm
        }
    }

    private var visualHeight: CGFloat {
        switch size {
        case .large: DSSize.buttonLarge
        case .regular: DSSize.buttonRegular
        case .compact: DSSize.buttonCompact
        }
    }

    private var foreground: Color {
        guard isEnabled else { return Color.ds.inkDisabled }
        switch variant {
        case .primary: return Color.ds.inkInverse
        case .secondary, .ai, .glass, .destructiveArmed: return Color.ds.ink
        case .tinted, .quiet: return Color.ds.accent
        case .destructive: return Color.ds.caution
        }
    }

    @ViewBuilder
    private var background: some View {
        if !isEnabled {
            // Shared disabled look: a faint fill for the filled variants, nothing for the outlined and text ones.
            switch variant {
            case .primary, .tinted, .ai, .destructiveArmed: shape.fill(Color.white.opacity(0.04))
            default: EmptyView()
            }
        } else {
            switch variant {
            case .primary:
                if isPressed { shape.fill(Color.ds.pearlPressed) } else { shape.fill(DSFill.pearl) }
            case .secondary:
                shape.fill(Color.white.opacity(isPressed ? 0.12 : 0.06))
            case .tinted:
                shape.fill(Color.ds.accent.opacity(isPressed ? 0.22 : 0.14))
            case .ai:
                shape.fill(Color.ds.iris.opacity(isPressed ? 0.24 : 0.16))
            case .quiet:
                if isPressed {
                    Capsule().fill(DSState.pressed).padding(.horizontal, -DSSpace.xs).padding(.vertical, 6)
                }
            case .destructive:
                shape.fill(Color.ds.caution.opacity(isPressed ? 0.12 : 0))
            case .destructiveArmed:
                shape.fill(isPressed ? Color.ds.cautionFillPressed : Color.ds.cautionFill)
            case .glass:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var border: some View {
        if !isEnabled {
            if variant == .secondary || variant == .destructive {
                shape.strokeBorder(Color.ds.hairline, lineWidth: 1)
            }
        } else {
            switch variant {
            case .secondary:
                Color.clear.dsLitEdge(radius: DSRadius.control, strength: .strong)
            case .tinted:
                shape.strokeBorder(Color.ds.accent.opacity(0.32), lineWidth: 1)
            case .ai:
                Color.clear.dsAIEdge(radius: DSRadius.control, isWorking: isLoading)
            case .destructive:
                shape.strokeBorder(Color.ds.caution.opacity(0.4), lineWidth: 1)
            default:
                EmptyView()
            }
        }
    }
}

/// Liquid Glass on the floating variant only.
private struct GlassIfNeeded: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    public static func ds(_ variant: DSButtonStyle.Variant, size: DSButtonStyle.Size = .regular, fullWidth: Bool = false,
                          isLoading: Bool = false) -> DSButtonStyle {
        DSButtonStyle(variant: variant, size: size, fullWidth: fullWidth, isLoading: isLoading)
    }
}

/// A round icon button: a 36pt lit key inside a 44pt hit area. Floating over content it becomes
/// glass; `isWorking` gives it the assistant's breathing edge.
public struct DSIconButton: View {
    private let systemImage: String
    private let label: String
    private let tint: Color
    private let isFloating: Bool
    private let isWorking: Bool
    private let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = DSSize.iconButton

    /// - Parameter label: what VoiceOver calls the button.
    public init(systemImage: String, label: String, tint: Color = Color.ds.ink, isFloating: Bool = false, isWorking: Bool = false,
                action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.tint = tint
        self.isFloating = isFloating
        self.isWorking = isWorking
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: DSIconSize.md * side / DSSize.iconButton, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: side, height: side)
        }
        .buttonStyle(DSIconButtonStyle(side: side, isFloating: isFloating, isWorking: isWorking))
        .accessibilityLabel(label)
    }
}

private struct DSIconButtonStyle: ButtonStyle {
    let side: CGFloat
    let isFloating: Bool
    let isWorking: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.ds.ink : Color.ds.inkDisabled)
            .background {
                if !isFloating {
                    Circle().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06))
                }
            }
            .overlay {
                if isWorking {
                    Color.clear.dsAIEdge(Circle(), isWorking: true)
                } else if !isFloating {
                    Color.clear.dsLitEdge(radius: side / 2, strength: .strong)
                }
            }
            .modifier(FloatingGlass(isOn: isFloating))
            .frame(minWidth: DSSize.hitTarget, minHeight: DSSize.hitTarget)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(DSMotion.press, value: configuration.isPressed)
    }
}

private struct FloatingGlass: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
        }
    }
}

/// Filter / suggestion chip. Selected is a white fill — white means committed — obvious without animation.
public struct DSChip: View {
    private let title: String
    private let systemImage: String?
    private let isSelected: Bool
    private let tone: DSTone?
    private let action: () -> Void

    /// - Parameter tone: a filter that stands for a category; its wash and ink replace the neutral chip.
    public init(_ title: String, systemImage: String? = nil, isSelected: Bool = false, tone: DSTone? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.tone = tone
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            DSChipLabel(title, systemImage: systemImage, isSelected: isSelected, tone: tone)
        }
        .buttonStyle(DSChipPressStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Hands the pressed state to the chip's label, which brightens its own fill.
private struct DSChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.dsChipPressed, configuration.isPressed)
            .animation(DSMotion.press, value: configuration.isPressed)
    }
}

extension EnvironmentValues {
    @Entry var dsChipPressed: Bool = false
}

/// The look of a chip without the button, so a `Menu` label can sit in a row of chips:
/// `Menu { … } label: { DSChipLabel("Newest", trailingSystemImage: "chevron.down") }`.
/// A rounded rectangle, never a capsule: 36pt drawn, 44pt to touch.
public struct DSChipLabel: View {
    private let title: String
    private let systemImage: String?
    private let trailingSystemImage: String?
    private let isSelected: Bool
    private let tone: DSTone?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dsChipPressed) private var isPressed

    public init(_ title: String, systemImage: String? = nil, trailingSystemImage: String? = nil, isSelected: Bool = false, tone: DSTone? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.trailingSystemImage = trailingSystemImage
        self.isSelected = isSelected
        self.tone = tone
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
            }
            Text(title).dsFont(isSelected ? .calloutEmphasis : .callout).monospacedDigit()
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage).imageScale(.small).accessibilityHidden(true)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: DSSize.chip)
        .background { shape.fill(fill) }
        .overlay { shape.strokeBorder(edge, lineWidth: 1) }
        .frame(minHeight: DSSize.hitTarget) // the hit target is 44pt tall whatever the text size; the chip itself stays compact
        .contentShape(Rectangle())
    }

    private var foreground: Color {
        if !isEnabled { return Color.ds.inkDisabled }
        if isSelected { return Color.ds.inkInverse }
        return tone?.onCanvas ?? Color.ds.inkSoft
    }

    private var fill: Color {
        if !isEnabled { return .clear }
        if isSelected { return Color.ds.ink }
        if let tone { return tone.wash(.tag) }
        return Color.white.opacity(isPressed ? 0.10 : 0.05)
    }

    private var edge: Color {
        if !isEnabled { return Color.ds.hairline }
        if isSelected { return .clear }
        if let tone { return tone.wash(.edge) }
        return Color.white.opacity(0.10)
    }
}

/// Small monospace tag, 6pt radius — the smallest shape in the system. Its tint sits on a 12% wash.
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

    /// The fill (G11): the tint gathering strength toward the leading edge of what's spent.
    static func fill(_ tint: Color) -> LinearGradient {
        LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .leading, endPoint: .trailing)
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
                        Capsule().fill(Self.fill(tint)).frame(width: notch)
                        // Cut a gap at the target so the tick reads even when tint == caution.
                        Rectangle()
                            .frame(width: 4)
                            .offset(x: notch - 2)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                } else {
                    Capsule()
                        .fill(Self.fill(tint))
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

/// "Ask about this": a sparkle icon button in a card header that opens Ask with a question
/// already written. Iris marks it as the AI surface; while that answer is coming it carries the
/// assistant's breathing edge.
public struct DSAskButton: View {
    private let label: String
    private let isWorking: Bool
    private let action: () -> Void

    /// - Parameter label: what the question is about; VoiceOver reads "Ask about <label>".
    public init(label: String, isWorking: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.isWorking = isWorking
        self.action = action
    }

    public var body: some View {
        DSIconButton(systemImage: "sparkle", label: "Ask about \(label)", tint: Color.ds.iris, isWorking: isWorking, action: action)
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
                    .font(.system(size: DSIconSize.xs, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, DSSpace.sm)
            .padding(.vertical, DSSpace.xs)
            .frame(minHeight: DSSize.hitTarget)
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
                .font(.system(size: DSIconSize.md, weight: .semibold))
                // At the end of the range the chevron drops to disabled ink rather than fading.
                .foregroundStyle(enabled ? Color.ds.inkSoft : Color.ds.inkDisabled)
                .frame(width: DSSize.hitTarget, height: DSSize.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Press feedback for a custom view used as a button — a tile, a card row: a wash over it while
/// held and a slight give, never a fade.
public struct DSPressStyle: ButtonStyle {
    let radius: CGFloat
    let wash: Color

    public init(radius: CGFloat, wash: Color = DSState.pressed) {
        self.radius = radius
        self.wash = wash
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(configuration.isPressed ? wash : .clear)
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(DSMotion.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == DSPressStyle {
    /// `DSPressStyle` with the white state wash; tiles pass `Color.ds.surfacePressed.opacity(0.2)`.
    public static func dsPress(radius: CGFloat = DSRadius.card, wash: Color = DSState.pressed) -> DSPressStyle {
        DSPressStyle(radius: radius, wash: wash)
    }
}
