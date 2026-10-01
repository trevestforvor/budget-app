import BudgetKit
import DesignSystem
import SwiftUI

/// Settings → Where your data goes. Every line is worked out from what the server reports, so it changes when the
/// setup does (turning on Jev, for one) instead of promising something fixed.
struct PrivacyView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<ServerStatus> = .loading
    @State private var clearedCopy = false
    @AppStorage(AppLock.enabledKey) private var lockEnabled = false

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingPlaceholder(text: "Checking your setup…")
            case let .failed(message):
                DSStateView(systemImage: "wifi.slash", title: "Can't check right now", message: message, actionTitle: "Try again") {
                    Task { await load() }
                }
            case let .loaded(status):
                list(status)
            }
        }
        .dsScreenBackground()
        .navigationTitle("Where your data goes")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.revision) { await load() }
    }

    private func list(_ status: ServerStatus) -> some View {
        List {
            Section {
                DSNoticeCard(status.rawDataStaysLocal ? "Your transactions stay on your Olares" : "Almost everything stays on your Olares",
                             message: status.rawDataStaysLocal
                                ? "Nothing about your money is sent to anyone's cloud."
                                : "Only what Jev needs to file an uncertain transaction leaves it — never names, accounts, dates or exact amounts.",
                             systemImage: "lock.shield", tint: status.rawDataStaysLocal ? Color.ds.accent : Color.ds.amber)
                    .settingsCardRow()
            }
            DSListSection("Your ledger") {
                DSListRow("Transactions and balances",
                          detail: app.isDemo ? "The demo ledger lives on this phone." : "Stored on your Olares, and nowhere else.",
                          systemImage: "externaldrive", tone: .cyan)
                DSListRow("Bank connections", detail: connectionsDetail(status), systemImage: "building.columns", tone: .iris)
            }
            DSListSection("Models") {
                DSListRow("Categorizing", detail: categorizingDetail(status), systemImage: "wand.and.stars", tone: .lilac)
                DSListRow("Ask", detail: askDetail(status), systemImage: "sparkle", tone: .azure)
            }
            DSListSection("This phone", footer: clearedCopy ? "It fills in again as you use the app." : nil) {
                if !app.isDemo {
                    DSListRow("Server token", detail: "In this phone's Keychain, and only on this phone.", systemImage: "key", tone: .amber)
                }
                DSListRow("Offline copy",
                          detail: app.isDemo ? "None: the demo already lives on this phone." : "The last answers from your Olares, encrypted while the phone is locked.",
                          systemImage: "iphone", tone: .teal)
                DSListRow("Lock", detail: lockEnabled ? "On: Budget asks for Face ID and hides your numbers in the app switcher." : "Off. Turn it on in Settings under Privacy & security.",
                          systemImage: "faceid", tone: .violet)
                if !app.isDemo {
                    Button {
                        Task {
                            await ResponseCache.appDefault().clear()
                            clearedCopy = true
                        }
                    } label: {
                        Label(clearedCopy ? "Offline copy cleared" : "Clear offline copy", systemImage: clearedCopy ? "checkmark" : "trash")
                            .dsFont(.body)
                            .foregroundStyle(clearedCopy ? Color.ds.inkSecondary : Color.ds.accent)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(clearedCopy)
                }
            }
        }
        .dsGroupedList()
    }

    // MARK: Derived lines

    private func connectionsDetail(_ status: ServerStatus) -> String {
        let providers = status.sources.filter { $0 != .fileImport }.map(\.displayName)
        let statements = status.sources.contains(.fileImport) ? " Statements you import stay there too." : ""
        guard !providers.isEmpty else { return "None linked." + statements }
        return "\(Self.list(providers)) \(providers.count == 1 ? "sends" : "send") your bank data straight to your Olares.\(statements)"
    }

    private func categorizingDetail(_ status: ServerStatus) -> String {
        let policy = status.decisionPolicy
        let jev = "Jev (TypeSafe, in the cloud) sees the merchant, the bank's description and a rough amount."
        switch policy.provider {
        case .off: return "Off. Nothing is sent anywhere; you file what Budget isn't sure of."
        case .jev: return jev
        case .localDecide, .laya:
            let local = "\(policy.provider.displayName.components(separatedBy: " · ")[0]) runs on your Olares."
            return policy.escalateToJev ? "\(local) When it's unsure, \(jev)" : local
        }
    }

    private func askDetail(_ status: ServerStatus) -> String {
        if app.isDemo, app.liveModel == nil { return "Answers are written on this phone from the ledger's own figures." }
        guard let model = status.roles.first(where: { $0.role == .chat })?.model else { return "No model is set up for questions yet." }
        return "\(model) answers on your Olares. It reads your ledger there; nothing is sent out."
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    private func load() async {
        let api = app.api
        state = await state.refreshed { try await api.serverStatus() }
    }
}
