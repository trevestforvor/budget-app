import SwiftUI

/// What a toast says and, optionally, the one thing it lets you do about it — nearly always Undo.
/// Present with `.dsToast($toast)`; setting a new message replaces the one showing.
public struct DSToastMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let message: String
    public let actionTitle: String?
    public let action: (@MainActor () -> Void)?
    public let duration: Duration

    public init(_ message: String, actionTitle: String? = nil, duration: Duration = .seconds(4), action: (@MainActor () -> Void)? = nil) {
        self.id = UUID()
        self.message = message
        self.actionTitle = action == nil ? nil : actionTitle
        self.action = action
        self.duration = duration
    }

    /// "Filed 12 as Transfer · Undo".
    public static func undo(_ message: String, duration: Duration = .seconds(4), action: @escaping @MainActor () -> Void) -> DSToastMessage {
        DSToastMessage(message, actionTitle: "Undo", duration: duration, action: action)
    }

    /// How long it stays up. Anyone reaching Undo through an assistive technology — VoiceOver, Switch Control — gets
    /// longer, so there's time to get to it.
    func visibleDuration(voiceOver: Bool, switchControl: Bool = false) -> Duration {
        voiceOver || switchControl ? max(duration * 5 / 2, .seconds(10)) : duration
    }

    public static func == (lhs: DSToastMessage, rhs: DSToastMessage) -> Bool { lhs.id == rhs.id }
}

/// A floating card near the bottom edge, on the overlay layer with its shadow: the message, an
/// optional action, and a thin line that runs down while it's showing. Usually shown by `.dsToast(_:)` rather than placed directly.
public struct DSToast: View {
    private let message: String
    private let actionTitle: String?
    private let countdown: Duration?
    private let action: (() -> Void)?
    private let tint: Color?
    @State private var remaining: CGFloat = 1

    /// - Parameters:
    ///   - countdown: when set, the line empties over this long; nil hides the line.
    ///   - tint: a status colour that blooms faintly from the corner (caution for a failure); nil for none.
    public init(_ message: String, actionTitle: String? = nil, countdown: Duration? = nil, tint: Color? = nil, action: (() -> Void)? = nil) {
        self.message = message
        self.actionTitle = actionTitle
        self.countdown = countdown
        self.tint = tint
        self.action = action
    }

    public var body: some View {
        HStack(spacing: DSSpace.sm) {
            Text(message)
                .dsFont(.callout)
                .foregroundStyle(Color.ds.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DSSpace.xs)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.ds(.quiet))
                    .frame(minWidth: DSSize.hitTarget, minHeight: DSSize.hitTarget)
            }
        }
        .padding(.leading, DSSpace.md)
        .padding(.trailing, actionTitle == nil ? DSSpace.md : DSSpace.sm)
        .padding(.vertical, DSSpace.xxs)
        .frame(minHeight: DSSize.listRow)
        .overlay(alignment: .bottomLeading) {
            if countdown != nil {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.ds.inkSecondary)
                        .frame(width: max(proxy.size.width * remaining, 0), height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, DSSpace.md)
                .padding(.bottom, 5)
                .accessibilityHidden(true)
            }
        }
        .dsPanel(.overlay, wash: tint.map { .tint($0, intensity: 0.12) })
        .dsShadow(.overlay)
        .onAppear {
            guard let countdown else { return }
            let seconds = Double(countdown.components.seconds) + Double(countdown.components.attoseconds) / 1e18
            withAnimation(.linear(duration: seconds)) { remaining = 0 }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Who is using a screen's bottom edge — a toast, a selection bar — so a button floating over its bottom-trailing
/// corner can step aside. Whatever floats puts one in the environment; toasts (and any view) mark themselves on it.
/// Handed down rather than reported up, so it reaches through navigation stacks.
@Observable @MainActor
public final class DSBottomEdge {
    public private(set) var users: Set<String> = []
    public var isBusy: Bool { !users.isEmpty }

    public init() {}

    public func mark(_ user: String, _ busy: Bool) {
        if busy { users.insert(user) } else { users.remove(user) }
    }
}

extension EnvironmentValues {
    @Entry public var dsBottomEdge: DSBottomEdge? = nil
}

extension View {
    /// Shows `toast` over the bottom edge, announces it to VoiceOver, and clears it after its
    /// duration (longer while VoiceOver runs). Swipe down or the escape gesture dismisses it.
    public func dsToast(_ toast: Binding<DSToastMessage?>) -> some View {
        modifier(DSToastPresenter(toast: toast))
    }
}

private struct DSToastPresenter: ViewModifier {
    @Binding var toast: DSToastMessage?
    @Environment(\.dsBottomEdge) private var bottomEdge
    /// This presenter's mark on the bottom edge (a screen can have more than one toast presenter).
    @State private var edgeUser = "toast-\(UUID().uuidString)"
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onChange(of: toast?.id, initial: true) { _, id in bottomEdge?.mark(edgeUser, id != nil) }
            .onDisappear { bottomEdge?.mark(edgeUser, false) }
            .overlay(alignment: .bottom) {
                if let current = toast {
                    let duration = current.visibleDuration(voiceOver: voiceOver, switchControl: switchControl)
                    DSToast(current.message, actionTitle: current.actionTitle, countdown: duration,
                            action: current.action.map { action in { action(); dismiss(current) } })
                        .id(current.id)
                        .padding(.horizontal, DSSpace.gutter)
                        .padding(.bottom, DSSpace.sm)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                            if value.translation.height > 24 { dismiss(current) }
                        })
                        .accessibilityAction(.escape) { dismiss(current) }
                        .task(id: current.id) {
                            let spoken = current.actionTitle.map { "\(current.message). \($0) available." } ?? current.message
                            AccessibilityNotification.Announcement(spoken).post()
                            try? await Task.sleep(for: duration)
                            guard !Task.isCancelled else { return }
                            dismiss(current)
                        }
                }
            }
            .animation(reduceMotion ? nil : DSMotion.standard, value: toast?.id)
    }

    /// Clears only the toast that asked, so a newer one isn't swept away by an older timer.
    private func dismiss(_ shown: DSToastMessage) {
        guard toast?.id == shown.id else { return }
        toast = nil
    }
}
