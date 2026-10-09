import SwiftUI

/// A settings-style icon: a filled tone square with the tone's own ink, so the glyph always
/// clears AA. (White glyphs on the amber tile were 1.8:1.) Scales a little with Dynamic Type.
public struct DSIconTile: View {
    private let systemImage: String
    private let tone: DSTone
    private let size: CGFloat
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    public init(systemImage: String, tone: DSTone, size: CGFloat = 28) {
        self.systemImage = systemImage
        self.tone = tone
        self.size = size
    }

    public var body: some View {
        let side = size * min(scale, 1.5)
        // Glossed from 36pt up; smaller tiles are too small for the light to read.
        Group {
            if side >= 36 {
                DSTileFill(tone: tone, radius: DSRadius.iconTile(side: side))
            } else {
                RoundedRectangle(cornerRadius: DSRadius.iconTile(side: side), style: .continuous).fill(tone.fill)
            }
        }
        .frame(width: side, height: side)
        .overlay {
            Image(systemName: systemImage)
                .font(.system(size: side * 0.48, weight: .semibold))
                .foregroundStyle(tone.onFill)
        }
        .accessibilityHidden(true)
    }
}

/// The trailing value of a `DSListRow`: secondary text, optionally with a chevron.
/// Use it on its own inside the builder form when a row needs a value and something else.
public struct DSListValue: View {
    private let text: String?
    private let showsChevron: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ text: String?, showsChevron: Bool = false) {
        self.text = text
        self.showsChevron = showsChevron
    }

    public var body: some View {
        HStack(spacing: DSSpace.xs) {
            if let text {
                Text(text)
                    .dsFont(.body)
                    .foregroundStyle(Color.ds.inkSecondary)
                    // Stacked under the title at accessibility sizes, so it reads from the leading edge.
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: DSIconSize.xs, weight: .semibold))
                    .foregroundStyle(Color.ds.inkTertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// One line in a settings or detail list: an optional icon tile, a title over an optional
/// detail, then a value, a chevron, or any control. At least 52pt tall.
///
/// Inside a `List` (see `.dsGroupedList()`), a `NavigationLink` adds its own chevron, so leave
/// `showsChevron` off there; use it in card layouts where the row is wrapped in a `Button`.
/// At accessibility text sizes the trailing content moves under the title instead of squeezing it.
public struct DSListRow<Trailing: View>: View {
    private let title: String
    private let detail: String?
    private let systemImage: String?
    private let tone: DSTone
    private let trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ title: String, detail: String? = nil, systemImage: String? = nil, tone: DSTone = .iris,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tone = tone
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: DSSpace.sm) {
            if let systemImage {
                DSIconTile(systemImage: systemImage, tone: tone)
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DSSpace.xxs) {
                    label
                    trailing
                }
                Spacer(minLength: 0)
            } else {
                label
                Spacer(minLength: DSSpace.md)
                trailing
            }
        }
        .padding(.vertical, DSSpace.xs)
        .frame(minHeight: DSSize.listRow)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .dsFont(.body)
                .foregroundStyle(Color.ds.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension DSListRow where Trailing == DSListValue {
    /// A row with a plain trailing value and, when it opens something, a chevron.
    public init(_ title: String, detail: String? = nil, value: String? = nil, systemImage: String? = nil, tone: DSTone = .iris,
                showsChevron: Bool = false) {
        self.init(title, detail: detail, systemImage: systemImage, tone: tone) {
            DSListValue(value, showsChevron: showsChevron)
        }
    }
}

/// A setting that's on or off, with one line saying what it changes.
public struct DSToggleRow: View {
    private let title: String
    private let detail: String?
    private let systemImage: String?
    private let tone: DSTone
    @Binding private var isOn: Bool

    public init(_ title: String, detail: String? = nil, systemImage: String? = nil, tone: DSTone = .iris, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tone = tone
        _isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: DSSpace.sm) {
                if let systemImage {
                    DSIconTile(systemImage: systemImage, tone: tone)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .dsFont(.body)
                        .foregroundStyle(Color.ds.ink)
                    if let detail {
                        Text(detail)
                            .dsFont(.caption)
                            .foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(Color.ds.accent)
        .padding(.vertical, DSSpace.xs)
        .frame(minHeight: DSSize.listRow)
    }
}

/// A section of a `.dsGroupedList()`: a `DSEyebrow` header, rows on a card like `DSCard`'s — `surface` (flat: a
/// gradient would band down a long list) at `DSRadius.card` with the lit edge (G1) — quiet 5% separators and 16pt side
/// insets, and an optional caption footer. Row backgrounds, separators and insets only reach rows through their
/// section, which is why this exists rather than the list modifier doing it. Plain content (a `Text`, a `TextField`)
/// still gets the 52pt minimum.
///
/// A list draws each row's background on its own, so the card is drawn a row at a time (`DSListRowChrome`): the first
/// row carries the top corners and the brightest edge, the last the bottom corners, and every row its share of the sides.
public struct DSListSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    public init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    public var body: some View {
        Section {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    row
                        .listRowBackground(DSListRowChrome(position: .init(index: index, count: rows.count)))
                        .listRowSeparatorTint(Color.ds.divider)
                        // Rows bring their own 52pt height and padding; the list's vertical insets would double it.
                        .listRowInsets(EdgeInsets(top: 0, leading: DSSpace.md, bottom: 0, trailing: DSSpace.md))
                }
            }
        } header: {
            if let title { DSEyebrow(title) }
        } footer: {
            if let footer {
                Text(footer)
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkTertiary)
            }
        }
    }
}

/// One row's share of a `DSListSection` card.
public struct DSListRowChrome: View {
    public enum Position: Equatable, Sendable {
        case only, first, middle, last

        public init(index: Int, count: Int) {
            self = count <= 1 ? .only : index == 0 ? .first : index == count - 1 ? .last : .middle
        }

        var roundsTop: Bool { self == .only || self == .first }
        var roundsBottom: Bool { self == .only || self == .last }

        /// The lit edge's opacity at this row's top and bottom: the card's G1 gradient, bright along its top and
        /// settling down the sides.
        var edgeOpacity: (top: Double, bottom: Double) {
            switch self {
            case .only: (0.12, 0.04)
            case .first: (0.12, 0.05)
            case .middle: (0.05, 0.05)
            case .last: (0.05, 0.04)
            }
        }
    }

    let position: Position

    public init(position: Position) { self.position = position }

    public var body: some View {
        // The card's shape, run past the row's open ends and clipped to the row, so the sides meet the next row's
        // with no seam and no line across the card.
        let overrun: CGFloat = DSRadius.card * 2
        let shape = RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
        let edge = position.edgeOpacity
        Color.clear
            .overlay {
                ZStack {
                    shape.fill(Color.ds.surface)
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(edge.top), .white.opacity(edge.bottom)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
                .padding(.top, position.roundsTop ? 0 : -overrun)
                .padding(.bottom, position.roundsBottom ? 0 : -overrun)
            }
            .clipped()
            .allowsHitTesting(false)
    }
}

extension View {
    /// The one skin for settings-style `List`s — in place of mixing `Form` and cards in a
    /// `ScrollView`. Inset grouped on the canvas with 52pt rows, its sections on the page gutter like every card.
    /// Build sections with `DSListSection` so rows sit on the card under eyebrow headers.
    public func dsGroupedList() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
            .listSectionSpacing(DSSpace.lg)
            // The cards on a ScrollView screen sit on the 20pt gutter; the system's inset is 16.
            .contentMargins(.horizontal, DSSpace.gutter, for: .scrollContent)
            .modifier(DSListSkin())
        #else
        // macOS only builds the package for tests; it has no inset-grouped style.
        listStyle(.inset)
            .modifier(DSListSkin())
        #endif
    }
}

private struct DSListSkin: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.ds.canvas.ignoresSafeArea())
            .environment(\.defaultMinListRowHeight, DSSize.listRow)
            .tint(Color.ds.accent)
    }
}
