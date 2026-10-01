import SwiftUI

/// The workhorse container: a charcoal panel over the canvas with a barely-there border.
public struct DSCard<Content: View>: View {
    public enum Elevation: Sendable { case flat, raised }

    private let padding: CGFloat
    private let elevation: Elevation
    private let content: Content

    public init(padding: CGFloat = DSSpace.lg, elevation: Elevation = .flat, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.elevation = elevation
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .fill(elevation == .flat ? Color.ds.surface : Color.ds.surfaceRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                    .strokeBorder(Color.ds.hairline, lineWidth: 1)
            }
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

/// A thin divider matching card hairlines.
public struct DSDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(Color.ds.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

extension View {
    /// Full-bleed design-system canvas behind a screen.
    public func dsScreenBackground() -> some View {
        background(Color.ds.canvas.ignoresSafeArea())
    }
}
