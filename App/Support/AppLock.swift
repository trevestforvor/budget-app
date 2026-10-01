import DesignSystem
import LocalAuthentication
import SwiftUI
import UIKit

/// Face ID (or the passcode) before Budget shows any money, and a cover over the app-switcher snapshot.
/// Off by default; turned on in Settings → Privacy & security. The lock sits in its own window above
/// everything — sheets and the keyboard included — so nothing peeks out from under it.
enum AppLock {
    static let enabledKey = "appLockEnabled"

    enum Method: Equatable {
        case faceID, touchID, opticID, passcode
        /// No passcode on this phone, so there's nothing to unlock with.
        case unavailable

        var name: String {
            switch self {
            case .faceID: "Face ID"
            case .touchID: "Touch ID"
            case .opticID: "Optic ID"
            case .passcode, .unavailable: "your passcode"
            }
        }

        var systemImage: String {
            switch self {
            case .faceID: "faceid"
            case .touchID: "touchid"
            case .opticID: "opticid"
            case .passcode, .unavailable: "lock"
            }
        }
    }

    /// What this phone can unlock with right now.
    static func method() -> Method {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            switch context.biometryType {
            case .faceID: return .faceID
            case .touchID: return .touchID
            case .opticID: return .opticID
            default: return .passcode
            }
        }
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) ? .passcode : .unavailable
    }

    /// Face ID, falling back to the passcode. False when cancelled or failed.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use passcode"
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

extension View {
    /// Locks the app with Face ID when it's been away, when the setting is on. Attach once, at the root.
    func appLock() -> some View { modifier(AppLockModifier()) }
}

private struct AppLockModifier: ViewModifier {
    @AppStorage(AppLock.enabledKey) private var enabled = false
    @Environment(\.scenePhase) private var phase
    @State private var lock = AppLockState()

    func body(content: Content) -> some View {
        content
            .onAppear { lock.launch(enabled: enabled, phase: phase) }
            .onChange(of: phase) { _, next in lock.phaseChanged(next, enabled: enabled) }
            .onChange(of: enabled) { _, on in if !on { lock.open() } }
    }
}

@Observable @MainActor
final class AppLockState {
    enum Mode { case open, covered, locked }

    private(set) var mode: Mode = .open
    private(set) var isAuthenticating = false
    /// Screenshot mode (`-locked` in the simulator): Unlock opens without asking, since the simulator has no passcode.
    private var isStaged = false
    private var needsPrompt = false
    private var window: UIWindow?

    func launch(enabled: Bool, phase: ScenePhase) {
        #if targetEnvironment(simulator)
        // Screenshots of the lock screen: start locked whatever the setting says.
        if ProcessInfo.processInfo.arguments.contains("-locked") {
            isStaged = true
            show(.locked)
            return
        }
        #endif
        guard enabled else { return }
        show(.locked)
        if phase == .active { Task { await unlock() } } else { needsPrompt = true }
    }

    func phaseChanged(_ phase: ScenePhase, enabled: Bool) {
        guard enabled || mode == .locked else { return }
        switch phase {
        case .background:
            guard enabled else { return }
            needsPrompt = true
            show(.locked)
        case .inactive:
            // The app-switcher snapshot is taken now. (Face ID's own prompt makes the app inactive too; leave that alone.)
            if enabled, mode == .open, !isAuthenticating { show(.covered) }
        case .active:
            if mode == .covered { open() }
            if mode == .locked, needsPrompt {
                needsPrompt = false
                Task { await unlock() }
            }
        @unknown default:
            break
        }
    }

    func unlock() async {
        guard mode == .locked, !isAuthenticating else { return }
        // A phone whose passcode was turned off can't unlock anything; never shut the person out of their own budget.
        guard AppLock.method() != .unavailable, !isStaged else { return open() }
        isAuthenticating = true
        let ok = await AppLock.authenticate(reason: "Unlock your budget")
        isAuthenticating = false
        if ok { open() }
    }

    func open() {
        mode = .open
        window?.isHidden = true
        window = nil
    }

    private func show(_ next: Mode) {
        mode = next
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        // The keyboard sits above every app window; put it away so nothing typed shows over the lock.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let host = UIHostingController(rootView: LockView(state: self))
        host.view.backgroundColor = .clear
        // VoiceOver stays on the lock instead of reading the budget underneath.
        host.view.accessibilityViewIsModal = true
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

/// The canvas and the wordmark, and an Unlock button when locked. The same view without the button covers
/// the app-switcher snapshot.
private struct LockView: View {
    let state: AppLockState
    private let method = AppLock.method()

    var body: some View {
        ZStack {
            Color.ds.canvas.ignoresSafeArea()
            VStack(spacing: DSSpace.md) {
                Spacer()
                Text("budget.")
                    .dsFont(.display)
                    .foregroundStyle(Color.ds.ink)
                    .accessibilityLabel("Budget")
                if state.mode == .locked {
                    Label("Locked", systemImage: "lock.fill")
                        .dsFont(.callout)
                        .foregroundStyle(Color.ds.inkSecondary)
                }
                Spacer()
                if state.mode == .locked {
                    Button {
                        Task { await state.unlock() }
                    } label: {
                        Label(method == .unavailable ? "Unlock" : "Unlock with \(method.name)", systemImage: method.systemImage)
                    }
                    .buttonStyle(.ds(.primary, fullWidth: true))
                    .disabled(state.isAuthenticating)
                    .accessibilityIdentifier("unlockButton")
                }
            }
            .padding(.horizontal, DSSpace.gutter)
            .padding(.bottom, DSSpace.xl)
        }
        .preferredColorScheme(.dark)
    }
}
