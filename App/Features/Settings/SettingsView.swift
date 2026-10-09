import BudgetKit
import DesignSystem
import SwiftUI

/// Settings, from the gear on Home. The root is about your money — the budget's categories, rules, recurring charges,
/// review and targets, your pay and accounts, what Budget has learned, and privacy. Server, models and the assistant's internals sit
/// behind Advanced.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ServerDraft()
    @State private var path: [SettingsRoute] = []
    @State private var status: ServerStatus?
    @State private var rules: [RuleSummary]?
    @State private var remembered: Int?
    @State private var accounts: [Account]?
    @AppStorage(AppLock.enabledKey) private var lockEnabled = false
    @State private var lockMethod = AppLock.method()
    @State private var lockProblem: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                notices
                budgetSection
                accountsSection
                assistantSection
                notificationsSection
                privacySection
                advancedSection
            }
            .dsGroupedList()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                destination(route)
            }
            .task(id: app.revision) { await load() }
        }
        .presentationBackground(Color.ds.canvas)
        // However the sheet closes — Done or a swipe — what it shows is what the app uses.
        .onDisappear { draft.apply(to: app) }
        .onAppear { lockMethod = AppLock.method() }
    }

    @ViewBuilder
    private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .categories: CategoriesView()
        case .rules: RulesView()
        case .recurring: RecurringView()
        case .review: ReviewSettingsView { openReview() }
        case .targets: TargetsView()
        case .pay: EarningsSettingsView()
        case .accounts: AccountsView()
        case .memory: MemoryView()
        case .assistantMemory: AssistantMemoryView()
        case .privacy: PrivacyView()
        case .advanced: AdvancedSettingsView(draft: draft) { dismiss() }
        }
    }

    // MARK: Sections

    /// What needs the person, above everything else: a connection to sign in to again, an offline copy.
    @ViewBuilder
    private var notices: some View {
        let signIn = status?.institutions.filter(\.needsSignIn) ?? []
        if !signIn.isEmpty || (!app.isDemo && app.freshness.isOffline) {
            Section {
                if !signIn.isEmpty {
                    DSNoticeCard(signIn.count == 1 ? "\(signIn[0].institution) needs you to sign in again"
                                                   : "\(signIn.count) connections need you to sign in again",
                                 message: "Nothing new is coming in from \(signIn.count == 1 ? "it" : "them"). Reconnect on your Budget dashboard — your accounts and history stay as they are.",
                                 actionTitle: "See accounts") { path.append(.accounts) }
                        .settingsCardRow()
                }
                if !app.isDemo, app.freshness == .unreachable {
                    DSNoticeCard("Can't reach your Olares",
                                 message: "Nothing has loaded, and the phone has no saved copy to show yet. Check the server address and that your Olares is on.",
                                 systemImage: "wifi.slash", tint: Color.ds.amber,
                                 actionTitle: "Check the connection") { path.append(.advanced) }
                        .settingsCardRow()
                } else if !app.isDemo, app.freshness == .cached {
                    DSNoticeCard("Showing the offline copy",
                                 message: "Your Olares didn't answer, so this is what the phone saved last. Changes wait until it's back.",
                                 systemImage: "icloud.slash", tint: Color.ds.amber,
                                 actionTitle: "Check the connection") { path.append(.advanced) }
                        .settingsCardRow()
                }
            }
        }
    }

    private var budgetSection: some View {
        DSListSection("Budget") {
            NavigationLink(value: SettingsRoute.categories) {
                // Says you can add your own: people found Rules and missed that categories aren't a fixed list.
                DSListRow("Categories", detail: "Add your own", value: categoryCount.map(String.init),
                          systemImage: "square.grid.2x2", tone: .orchid)
            }
            .accessibilityIdentifier("settingsCategories")
            NavigationLink(value: SettingsRoute.rules) {
                DSListRow("Rules", systemImage: "arrow.triangle.branch", tone: .azure) {
                    if let conflicts = conflictCount, conflicts > 0 {
                        DSTag("\(conflicts) conflict\(conflicts == 1 ? "" : "s")", systemImage: "exclamationmark", tint: Color.ds.caution)
                    } else if let rules {
                        DSListValue(rules.isEmpty ? "None yet" : "\(rules.count)")
                    }
                }
            }
            .accessibilityIdentifier("settingsRules")
            NavigationLink(value: SettingsRoute.recurring) {
                DSListRow("Recurring", detail: "Subscriptions and bills: change, add or take off", systemImage: "repeat", tone: .violet)
            }
            .accessibilityIdentifier("settingsRecurring")
            NavigationLink(value: SettingsRoute.review) {
                DSListRow("Review", value: reviewValue, systemImage: "checklist", tone: .amber)
            }
            .accessibilityIdentifier("settingsReview")
            NavigationLink(value: SettingsRoute.targets) {
                DSListRow("Targets & caps", systemImage: "target", tone: .cyan)
            }
            .accessibilityIdentifier("settingsTargets")
            NavigationLink(value: SettingsRoute.pay) {
                DSListRow("Your pay", detail: "For checking a price", systemImage: "banknote", tone: .teal)
            }
            .accessibilityIdentifier("settingsPay")
        }
    }

    private var accountsSection: some View {
        DSListSection("Accounts") {
            NavigationLink(value: SettingsRoute.accounts) {
                DSListRow("Linked accounts", detail: accountsDetail, systemImage: "building.columns", tone: .iris) {
                    if status?.institutions.contains(where: \.needsSignIn) == true {
                        DSTag("Sign in", systemImage: "exclamationmark", tint: Color.ds.caution)
                    }
                }
            }
            .accessibilityIdentifier("settingsAccounts")
        }
    }

    private var assistantSection: some View {
        DSListSection("Assistant") {
            NavigationLink(value: SettingsRoute.memory) {
                DSListRow("What Budget has learned", detail: remembered.map { "\($0) merchant\($0 == 1 ? "" : "s") it files on its own" },
                          systemImage: "brain", tone: .lilac)
            }
            .accessibilityIdentifier("settingsMemory")
            NavigationLink(value: SettingsRoute.assistantMemory) {
                DSListRow("Assistant memory", detail: "What Ask keeps in mind about you", systemImage: "sparkles", tone: .iris)
            }
            .accessibilityIdentifier("settingsAssistantMemory")
        }
    }

    private var morning: MorningSummaryModel { .shared }

    /// The morning summary, with a server of your own (the demo has nothing to send from).
    @ViewBuilder
    private var notificationsSection: some View {
        if morning.available {
            DSListSection("Notifications", footer: morning.problem ?? morningNote) {
                DSToggleRow("Morning summary", detail: morningDetail, systemImage: "sun.horizon", tone: .amber,
                            isOn: Binding(get: { morning.enabled }, set: { on in Task { await morning.setEnabled(on) } }))
                    .disabled(morning.working)
                    .accessibilityIdentifier("settingsMorningSummary")
                if morning.enabled {
                    HStack(spacing: DSSpace.sm) {
                        DSListRow("Time", detail: "Wherever your phone is", systemImage: "clock", tone: .amber)
                        DatePicker("Time", selection: morningTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .fixedSize()
                            .disabled(morning.working)
                            .accessibilityIdentifier("settingsMorningSummaryTime")
                    }
                    Button { Task { await morning.sendTest() } } label: {
                        DSListRow("Send one now", detail: "Yesterday's summary, to this phone", systemImage: "paperplane", tone: .azure)
                    }
                    .buttonStyle(.plain)
                    .disabled(morning.working)
                    .accessibilityIdentifier("settingsMorningSummaryTest")
                }
            }
            .task { await morning.refreshPermission() }
        }
    }

    /// The summary's time as a date today, for the picker; setting it tells the server.
    private var morningTime: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: morning.minuteOfDay / 60, minute: morning.minuteOfDay % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            Task { await morning.setTime(hour: parts.hour ?? 9, minute: parts.minute ?? 30) }
        })
    }

    private var morningTimeText: String {
        let date = Calendar.current.date(bySettingHour: morning.minuteOfDay / 60, minute: morning.minuteOfDay % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var morningDetail: String {
        guard morning.enabled else { return "Yesterday's spending each morning, wherever you are" }
        let zone = morning.status?.timeZone ?? TimeZone.current.identifier
        let place = zone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone
        return "Every day at \(morningTimeText), \(place) time"
    }

    /// What's in the way of the summary arriving, or when it last did.
    private var morningNote: String? {
        guard morning.enabled else { return nil }
        if morning.blockedInSettings { return "Notifications are off for Budget in iOS Settings, so nothing will show." }
        guard let status = morning.status else { return nil }
        if !status.pushConfigured { return "Your server can't send yet: add an APNs key on the dashboard, under Notifications." }
        if let error = status.lastError { return error }
        return status.lastSentDay.map { "It follows your phone's time zone when you travel. Last sent \($0)." }
            ?? "It follows your phone's time zone when you travel."
    }

    private var privacySection: some View {
        DSListSection("Privacy & security", footer: lockProblem) {
            DSToggleRow(lockTitle, detail: lockDetail, systemImage: lockMethod == .touchID ? "touchid" : "faceid", tone: .teal,
                        isOn: Binding(get: { lockEnabled }, set: { turnLock($0) }))
                .disabled(lockMethod == .unavailable && !lockEnabled)
            NavigationLink(value: SettingsRoute.privacy) {
                DSListRow("Where your data goes", systemImage: "lock.shield", tone: .violet)
            }
            .accessibilityIdentifier("settingsPrivacy")
        }
    }

    private var advancedSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.advanced) {
                DSListRow("Advanced", detail: "Server, models, assistant", systemImage: "gearshape.2", tone: .irisDeep) {
                    connectionTag
                }
            }
            .listRowBackground(Color.ds.surface)
            .listRowInsets(EdgeInsets(top: 0, leading: DSSpace.md, bottom: 0, trailing: DSSpace.md))
            .accessibilityIdentifier("settingsAdvanced")
        } footer: {
            Text(aboutLine)
                .dsFont(.caption)
                .foregroundStyle(Color.ds.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, DSSpace.md)
        }
    }

    @ViewBuilder
    private var connectionTag: some View {
        if app.isDemo {
            DSTag("Demo", tint: Color.ds.iris)
        } else if app.freshness.isOffline {
            DSTag("Offline", systemImage: app.freshness == .cached ? "icloud.slash" : "wifi.slash", tint: Color.ds.amber)
        } else if status != nil {
            DSTag("Connected", systemImage: "checkmark", tint: Color.ds.accent)
        }
    }

    // MARK: Values

    /// "All clear" only once the queue has actually loaded; nothing while it's unknown.
    private var reviewValue: String? {
        guard app.reviewQueueLoaded else { return nil }
        return app.reviewCount == 0 ? "All clear" : "\(app.reviewCount) waiting"
    }

    /// The categories the person shapes: spending ones and the money-in ones they made (not Income or Transfer).
    private var categoryCount: Int? {
        let count = app.sortedCategories.filter { !$0.isSystem }.count
        return count == 0 ? nil : count
    }

    /// Pairs of rules that disagree (each pair lists the other, so count pairs, not rules).
    private var conflictCount: Int? {
        rules.map { rules in Set(rules.flatMap { rule in rule.conflicts.map { [rule.id, $0].sorted().joined(separator: "|") } }).count }
    }

    private var accountsDetail: String? {
        guard let accounts else { return nil }
        var parts = ["\(accounts.count) account\(accounts.count == 1 ? "" : "s")"]
        if let lastSync = status?.lastSync { parts.append("updated \(lastSync.agoPhrase)") }
        return parts.joined(separator: " · ")
    }

    private var lockTitle: String {
        switch lockMethod {
        case .touchID: "Touch ID lock"
        case .opticID: "Optic ID lock"
        case .passcode: "Passcode lock"
        case .faceID, .unavailable: "Face ID lock"
        }
    }

    private var lockDetail: String {
        switch lockMethod {
        case .unavailable: "Set a passcode on this iPhone to use it."
        default: "Asks for \(lockMethod.name) when you open Budget, and hides your numbers in the app switcher."
        }
    }

    private var aboutLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        var parts = ["Budget \(version)\(build)"]
        if app.isDemo {
            parts.append("Demo ledger on this phone")
        } else if let status {
            parts.append("Server \(status.version)")
            if let host = URL(string: draft.trimmedURL)?.host() { parts.append(host) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func load() async {
        let api = app.api
        async let status = try? api.serverStatus()
        async let rules = try? api.rules()
        async let remembered = try? api.rememberedMerchants()
        async let overview = try? api.overview()
        self.status = await status
        self.rules = await rules
        // The same count What Budget has learned heads its list with: moves between your own accounts aren't merchants.
        self.remembered = await remembered?.filter { $0.categoryID != "transfer" }.count
        self.accounts = await overview?.accounts
    }

    /// Turning the lock on asks for Face ID first, so the person knows it works before it can lock them out.
    private func turnLock(_ on: Bool) {
        lockProblem = nil
        guard on else {
            lockEnabled = false
            return
        }
        Task {
            if await AppLock.authenticate(reason: "Turn on the lock for Budget") {
                lockEnabled = true
            } else {
                lockProblem = "The lock stays off: \(lockMethod.name) didn't confirm it's you."
            }
        }
    }

    /// Review → "Open review": back to the app, on Activity, with the first transaction waiting open.
    private func openReview() {
        dismiss()
        app.selectedTab = .activity
        app.opensFirstReview = true
    }
}
