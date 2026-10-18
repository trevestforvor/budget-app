import SwiftUI

/// The workhorse container: a charcoal panel lit along its top edge, with no shadow. Give it a
/// `tone` and that tone blooms from the top-leading corner; give it a `wash` for caution or the
/// assistant's light.
public struct DSCard<Content: View>: View {
    public typealias Elevation = DSElevation

    private let padding: CGFloat
    private let elevation: Elevation
    private let wash: DSCardWash?
    private let content: Content

    public init(padding: CGFloat = DSSpace.lg, elevation: Elevation = .flat, tone: DSTone? = nil, @ViewBuilder content: () -> Content) {
        self.init(padding: padding, elevation: elevation, wash: tone.map { .tone($0) }, content: content)
    }

    public init(padding: CGFloat = DSSpace.lg, elevation: Elevation = .flat, wash: DSCardWash?, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.elevation = elevation
        self.wash = wash
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsPanel(elevation, wash: wash)
    }
}

/// A card's optional header: an eyebrow, an optional chevron when the card opens something, and a
/// divider beneath. Place it first in a `DSCard`'s content.
public struct DSCardHeader: View {
    private let title: String
    private let showsChevron: Bool

    public init(_ title: String, showsChevron: Bool = false) {
        self.title = title
        self.showsChevron = showsChevron
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                DSEyebrow(title)
                Spacer(minLength: DSSpace.xs)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DSIconSize.xs, weight: .semibold))
                        .foregroundStyle(Color.ds.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: DSSize.hitTarget)
            DSDivider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Uppercase monospace label that sits above numbers and headlines.
public struct DSEyebrow: View {
    private let text: String
    private let dot: Color?

    public init(_ text: String, dot: Color? = nil) {
        self.text = text
        self.dot = dot
    }

    public var body: some View {
        HStack(spacing: DSSpace.xs) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(text)
                .dsFont(.eyebrow)
                .foregroundStyle(Color.ds.inkSecondary)
        }
        // The eyebrow style uppercases the text, and with the iOS 26 SDK in Xcode 27 that reaches the accessibility
        // label too, even one set on the Text (it resolves inside the same text case). Set out here, the label keeps
        // the words as written for VoiceOver and UI tests.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Serif section title with an optional trailing action.
public struct DSSectionHeader: View {
    private let title: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .dsFont(.headline)
                .foregroundStyle(Color.ds.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.ds(.quiet))
            }
        }
    }
}

/// A thin divider between rows inside a card, quieter than the card's own edge.
public struct DSDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(Color.ds.divider).frame(height: 1).accessibilityHidden(true)
    }
}

extension View {
    /// Full-bleed design-system canvas behind a screen. `dsScreenBackground(bloom:)` adds a bloom.
    public func dsScreenBackground() -> some View {
        background(Color.ds.canvas.ignoresSafeArea())
    }
}
