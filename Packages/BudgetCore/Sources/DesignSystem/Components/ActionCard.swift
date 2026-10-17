import SwiftUI

/// A change the assistant proposes. While pending it carries the AI edge and an iris glow rising
/// from the bottom-trailing corner; nothing happens until Apply.
public struct DSActionCard: View {
    public enum Phase: Equatable, Sendable {
        case proposed, applying, applied(String), dismissed, failed(String)
        /// From a conversation reopened later: shown for the record, no longer offered.
        case earlier
        /// The data it was worked out from changed before it applied; nothing changed. Refresh shows what it would do now.
        case stale(String)
        /// Stale, while Refresh works it out again: no Apply until it's back.
        case refreshing(String)
        /// Refresh found it can't be done any more (what it changes is gone, or it's refused now): shown, not offered.
        case unavailable(String)
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
    private let onRefresh: () -> Void

    public init(eyebrow: String = "Proposed change", title: String, detail: String? = nil, effects: [Effect] = [],
                trace: (name: String, arguments: String)? = nil, phase: Phase, applyTitle: String = "Apply",
                onApply: @escaping () -> Void, onDismiss: @escaping () -> Void, onRefresh: @escaping () -> Void = {}) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.effects = effects
        self.trace = trace
        self.phase = phase
        self.applyTitle = applyTitle
        self.onApply = onApply
        self.onDismiss = onDismiss
        self.onRefresh = onRefresh
    }

    private var isPending: Bool { phase == .proposed || phase == .applying }

    private var isRetired: Bool {
        switch phase {
        case .dismissed, .earlier, .unavailable: true
        default: false
        }
    }

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
        .background { DSPanelBackground(wash: isPending ? .ai : nil) }
        .overlay {
            // Pending: the assistant's edge, breathing while it applies. Settled: the plain lit edge.
            if isPending {
                Color.clear.dsAIEdge(radius: DSRadius.card, isWorking: phase == .applying)
            } else {
                Color.clear.dsLitEdge(radius: DSRadius.card)
            }
        }
        .opacity(isRetired ? 0.55 : 1)
        .animation(DSMotion.standard, value: phase)
    }

    @ViewBuilder
    private var statusTag: some View {
        switch phase {
        case .proposed: DSTag("Not applied", tint: Color.ds.inkTertiary)
        case .applying, .refreshing: ProgressView().controlSize(.small).tint(Color.ds.iris)
        case .applied: DSTag("Applied", systemImage: "checkmark", tint: Color.ds.accent)
        case .dismissed: DSTag("Dismissed", tint: Color.ds.inkTertiary)
        case .earlier: DSTag("Earlier", tint: Color.ds.inkTertiary)
        case .failed: DSTag("Didn't apply", systemImage: "exclamationmark", tint: Color.ds.caution)
        case .stale: DSTag("Out of date", systemImage: "arrow.clockwise", tint: Color.ds.caution)
        case .unavailable: DSTag("Not possible now", tint: Color.ds.inkTertiary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .proposed, .applying:
            HStack(spacing: DSSpace.md) {
                // The assistant's action: iris, not the white primary. While it applies it shows a spinner
                // and breathes, and ignores taps rather than greying out.
                Button(applyTitle, action: onApply)
                    .buttonStyle(.ds(.ai, isLoading: phase == .applying))
                    .allowsHitTesting(phase != .applying)
                Button("Not now", action: onDismiss)
                    .buttonStyle(.ds(.quiet))
                    .disabled(phase == .applying)
            }
            .padding(.top, DSSpace.xxs)
        case let .applied(message):
            Text(message).dsFont(.callout).foregroundStyle(Color.ds.inkSoft)
        case let .failed(message):
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text(message).dsFont(.callout).foregroundStyle(Color.ds.caution)
                Button("Try again", action: onApply).buttonStyle(.ds(.secondary))
            }
        case let .stale(message), let .refreshing(message):
            let isRefreshing = phase == .refreshing(message)
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text(message).dsFont(.callout).foregroundStyle(Color.ds.inkSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DSSpace.md) {
                    // While it refreshes, Refresh spins and ignores taps; there's nothing to apply until it's back.
                    Button("Refresh", action: onRefresh)
                        .buttonStyle(.ds(.secondary, isLoading: isRefreshing))
                        .allowsHitTesting(!isRefreshing)
                    Button("Not now", action: onDismiss)
                        .buttonStyle(.ds(.quiet))
                        .disabled(isRefreshing)
                }
            }
        case let .unavailable(message):
            Text(message).dsFont(.callout).foregroundStyle(Color.ds.inkSecondary).fixedSize(horizontal: false, vertical: true)
        case .dismissed:
            EmptyView()
        case .earlier:
            Text("From an earlier visit. Ask again if you still want it.").dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
        }
    }
}
