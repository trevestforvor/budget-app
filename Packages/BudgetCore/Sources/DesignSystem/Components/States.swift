import SwiftUI

/// Empty / error / offline states share one quiet layout.
public struct DSStateView: View {
    private let systemImage: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(systemImage: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: DSSpace.md) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.ds.inkSecondary)
                .accessibilityHidden(true)
            Text(title)
                .dsFont(.title)
                .foregroundStyle(Color.ds.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .dsFont(.callout)
                .foregroundStyle(Color.ds.inkSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.ds(.secondary))
                    .padding(.top, DSSpace.xs)
            }
        }
        .padding(DSSpace.xl)
        .frame(maxWidth: .infinity)
    }
}

/// Something that needs the person — a connection to sign in again, an offline copy, two rules
/// that disagree. A tinted edge and icon (caution by default) and one full-width secondary action.
public struct DSNoticeCard: View {
    private let title: String
    private let message: String
    private let systemImage: String
    private let tint: Color
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(_ title: String, message: String, systemImage: String = "exclamationmark.circle", tint: Color = Color.ds.caution,
                actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.md) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpace.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DSSpace.xxs) {
                    Text(title)
                        .dsFont(.bodyEmphasis)
                        .foregroundStyle(Color.ds.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .dsFont(.callout)
                        .foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.ds(.secondary, fullWidth: true))
            }
        }
        .padding(DSSpace.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .fill(Color.ds.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).fill(tint.opacity(0.06))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        }
    }
}

extension View {
    /// Redacts content with the system placeholder while loading.
    public func dsLoading(_ isLoading: Bool) -> some View {
        redacted(reason: isLoading ? .placeholder : [])
            .allowsHitTesting(!isLoading)
    }
}
