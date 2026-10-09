import BudgetKit
import DesignSystem
import SwiftUI

/// The pages Settings pushes. Rows, notices and cross-links all navigate by these, so any page can open any other.
enum SettingsRoute: Hashable {
    case categories, rules, recurring, review, targets, pay, accounts, memory, privacy, advanced
}

/// The server fields as typed in Settings. The app keeps using what it has until Settings closes; then the draft is
/// saved and applied, however the sheet was dismissed.
@Observable @MainActor
final class ServerDraft {
    var serverURL: String
    var token: String
    var useDemo: Bool
    var useLiveModel: Bool
    var liveModelURL: String

    init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: SettingsKeys.serverURL) ?? ""
        token = Keychain.string(for: SettingsKeys.apiToken) ?? ""
        useDemo = defaults.object(forKey: SettingsKeys.useDemo) as? Bool ?? true
        useLiveModel = defaults.bool(forKey: SettingsKeys.useLiveModel)
        liveModelURL = defaults.string(forKey: SettingsKeys.liveModelURL) ?? ""
    }

    var trimmedURL: String { serverURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// "Use demo ledger" only counts in the simulator, where the demo exists.
    var demoOn: Bool { useDemo && AppModel.demoAvailable }

    var mode: ConnectionMode {
        if demoOn { return .demo }
        return trimmedURL.isEmpty ? .notConnected : .server
    }

    /// Writes the draft where the app reads it at launch, then points the app at it.
    func apply(to app: AppModel) {
        let defaults = UserDefaults.standard
        defaults.set(serverURL, forKey: SettingsKeys.serverURL)
        defaults.set(useDemo, forKey: SettingsKeys.useDemo)
        defaults.set(useLiveModel, forKey: SettingsKeys.useLiveModel)
        defaults.set(liveModelURL, forKey: SettingsKeys.liveModelURL)
        Keychain.set(trimmedToken, for: SettingsKeys.apiToken)
        app.configure(serverURL: serverURL, token: token, demo: demoOn, liveModelURL: useLiveModel ? liveModelURL : nil)
    }

    /// "Disconnect this phone": forgets the server and token here and in the Keychain, and deletes the offline copy.
    func disconnect(_ app: AppModel) async {
        serverURL = ""
        token = ""
        useDemo = false
        apply(to: app)
        await ResponseCache.appDefault().clear()
    }
}

enum ConnectionMode { case demo, server, notConnected }

extension InstitutionLink {
    /// "Plaid", "Teller", or "statements" — how the data arrives, for "via …" lines.
    var sourceName: String {
        switch primary {
        case .fileImport?: "statements"
        case let source?: source.displayName
        case nil: "no connection"
        }
    }

    var fromStatements: Bool { primary == .fileImport }
    var needsSignIn: Bool { status == .needsReauth }
}

extension Account {
    /// "Credit card", or "Investments · balance only" — never counted as cash.
    var kindLabel: String { kind == .investment ? "\(kind.title) · balance only" : kind.title }
}

extension Date {
    /// "just now", "2 hours ago", "9 days ago".
    var agoPhrase: String {
        AppClock.now.timeIntervalSince(self) < 60 ? "just now" : formatted(.relative(presentation: .numeric, unitsStyle: .wide))
    }
}

extension Money {
    /// "$450" without cents when there are none.
    var shortString: String { formatted(fractionDigits: minorUnits % 100 == 0 ? 0 : 2) }
}

/// A plain line of text inside a settings list — a caption, a problem to fix, a result.
struct SettingsNote: View {
    let text: String
    var tint: Color = Color.ds.inkSecondary
    var systemImage: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(tint).accessibilityHidden(true)
            }
            Text(text)
                .dsFont(.callout)
                .foregroundStyle(tint == Color.ds.inkSecondary ? Color.ds.inkSecondary : Color.ds.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DSSpace.sm)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Says a write failure out loud to VoiceOver as it happens: the note that shows it is often off-screen (under the
    /// icon grid, at the top of a long list), and a toast elsewhere in the app is announced the same way.
    func announcesProblem(_ problem: String?) -> some View {
        onChange(of: problem) { _, problem in
            if let problem, !problem.isEmpty { AccessibilityNotification.Announcement(problem).post() }
        }
    }
}

/// A line of explanation straight on the list's canvas, lined up with the section footers.
struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .dsFont(.callout)
            .foregroundStyle(Color.ds.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DSSpace.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCardRow()
    }
}

/// A destructive action row, said in words and in the caution tone (the confirmation dialog carries the system red).
struct SettingsDestructiveRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .dsFont(.body)
                .foregroundStyle(Color.ds.caution)
                .frame(maxWidth: .infinity, minHeight: DSSize.listRow, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Puts a full-width card (a notice, a summary) straight on the list's canvas, outside the row chrome.
    func settingsCardRow() -> some View {
        listRowInsets(EdgeInsets(top: DSSpace.xs, leading: 0, bottom: DSSpace.xs, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
