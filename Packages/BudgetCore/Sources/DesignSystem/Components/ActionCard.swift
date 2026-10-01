import SwiftUI

/// A change the assistant proposes. Iris-edged while pending; nothing happens until Apply.
public struct DSActionCard: View {
    public enum Phase: Equatable, Sendable {
        case proposed, applying, applied(String), dismissed, failed(String)
    }

    public struct Effect: Identifiable, Hashable, Sendable {
        public let id: String
        public let label: String
        public let value: String
        public let emphasized: Bool

        public init(id: String, label: String, value: String, emphasized: Bool = false) {
            self.id = id
            self.label = label
            self.value = value
            self.emphasized = emphasized
        }
    }

    private let eyebrow: String
    private let title: String
    private let detail: String?
    private let effects: [Effect]
    private let trace: (name: String, arguments: String)?
    private let phase: Phase
    private let applyTitle: String
    private let onApply: () -> Void
    private let onDismiss: () -> Void

    public init(eyebrow: String = "Proposed change", title: String, detail: String? = nil, effects: [Effect] = [],
                trace: (name: String, arguments: String)? = nil, phase: Phase, applyTitle: String = "Apply",
                onApply: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.effects = effects
        self.trace = trace
        self.phase = phase
        self.applyTitle = applyTitle
        self.onApply = onApply
        self.onDismiss = onDismiss
    }

    private var isPending: Bool { phase == .proposed || phase == .applying }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack {
                DSEyebrow(eyebrow, dot: Color.ds.iris)
                Spacer()
                statusTag
            }
            Text(title)
                .dsFont(.headline)
                .foregroundStyle(Color.ds.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).dsFont(.callout).foregroundStyle(Color.ds.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if !effects.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(effects.enumerated()), id: \.element.id) { index, effect in
                        HStack(alignment: .firstTextBaseline) {
                            Text(effect.label).dsFont(.callout).foregroundStyle(Color.ds.inkSoft)
                            Spacer()
                            Text(effect.value)
                                .dsFont(effect.emphasized ? .amountRow : .callout)
                                .foregroundStyle(effect.emphasized ? Color.ds.ink : Color.ds.inkSecondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 7)
                        .accessibilityElement(children: .combine)
                        if index < effects.count - 1 { DSDivider() }
                    }
                }
            }
            if let trace {
                DSToolTrace(name: trace.name, arguments: trace.arguments)
            }
            footer
        }
        .padding(DSSpace.md + 2)
        .background {
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).fill(Color.ds.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .strokeBorder(isPending ? Color.ds.iris.opacity(0.45) : Color.ds.hairline, lineWidth: 1)
        }
        .opacity(phase == .dismissed ? 0.55 : 1)
        .animation(DSMotion.standard, value: phase)
    }

    @ViewBuilder
    private var statusTag: some View {
        switch phase {
        case .proposed: DSTag("Not applied", tint: Color.ds.inkTertiary)
        case .applying: ProgressView().controlSize(.small).tint(Color.ds.iris)
        case .applied: DSTag("Applied", systemImage: "checkmark", tint: Color.ds.accent)
        case .dismissed: DSTag("Dismissed", tint: Color.ds.inkTertiary)
        case .failed: DSTag("Didn't apply", systemImage: "exclamationmark", tint: Color.ds.caution)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .proposed, .applying:
            HStack(spacing: DSSpace.md) {
                Button(applyTitle, action: onApply).buttonStyle(.ds(.primary))
                Button("Not now", action: onDismiss).buttonStyle(.ds(.quiet))
            }
            .disabled(phase == .applying)
            .padding(.top, DSSpace.xxs)
        case let .applied(message):
            Text(message).dsFont(.callout).foregroundStyle(Color.ds.inkSoft)
        case let .failed(message):
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text(message).dsFont(.callout).foregroundStyle(Color.ds.caution)
                Button("Try again", action: onApply).buttonStyle(.ds(.secondary))
            }
        case .dismissed:
            EmptyView()
        }
    }
}
