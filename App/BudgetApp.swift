import AppIntents
import BudgetKit
import DesignSystem
import SwiftUI
import TipKit

@main
struct BudgetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var app: AppModel

    init() {
        let defaults = UserDefaults.standard
        let args = ProcessInfo.processInfo.arguments
        // `-server URL [-token T]` is the same as entering them in Settings (saved, token in the
        // Keychain), so Settings always shows what the app is actually talking to.
        #if targetEnvironment(simulator)
        // `-resetSettings` (simulator only): start as a first run — no saved server, token, demo choice or pay.
        if args.contains("-resetSettings") {
            for key in [SettingsKeys.serverURL, SettingsKeys.useDemo, SettingsKeys.useLiveModel, AppLock.enabledKey, EarningsProfile.storageKey] { defaults.removeObject(forKey: key) }
            Keychain.set(nil, for: SettingsKeys.apiToken)
        }
        #endif
        let server = Self.value(after: "-server", in: args)
        // `-demo` likewise sticks, so Settings never shows a server setup the app isn't using.
        // The demo ledger exists only in the simulator; on a device `-demo` and `-live` are ignored.
        if server == nil, args.contains("-demo"), AppModel.demoAvailable { defaults.set(true, forKey: SettingsKeys.useDemo) }
        if let server {
            defaults.set(server, forKey: SettingsKeys.serverURL)
            defaults.set(false, forKey: SettingsKeys.useDemo)
            if let token = Self.value(after: "-token", in: args) { Keychain.set(token, for: SettingsKeys.apiToken) }
        }
        let demo = AppModel.demoAvailable && server == nil
            && ((defaults.object(forKey: SettingsKeys.useDemo) as? Bool ?? true) || args.contains("-demo"))
        // `-live` runs the demo on the model saved in Settings, or on `-liveModel URL`.
        let live = (defaults.bool(forKey: SettingsKeys.useLiveModel) || args.contains("-live"))
            ? (Self.value(after: "-liveModel", in: args) ?? defaults.string(forKey: SettingsKeys.liveModelURL)) : nil
        let model = AppModel(serverURL: server ?? defaults.string(forKey: SettingsKeys.serverURL),
                             token: Keychain.string(for: SettingsKeys.apiToken),
                             demo: demo, liveModelURL: live)
        Self.applyLaunchArguments(args, to: model)
        // The Check a Price shortcut opens opportunity cost through the model.
        AppDependencyManager.shared.add(dependency: model)
        // Tips (the price-check button's) show on a phone; in the simulator only with `-tips`, so screenshots and UI
        // tests never find a popover in the way.
        #if targetEnvironment(simulator)
        if args.contains("-tips") { try? Tips.configure() }
        #else
        try? Tips.configure()
        #endif
        _app = State(initialValue: model)
        MorningSummaryModel.shared.attach(model)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("-gallery") {
                    NavigationStack { DesignSystemGallery() }
                } else {
                    RootView()
                }
            }
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Color.ds.accent)
                // The morning summary goes out at 9:30 where the phone is: tell the server whenever that may have changed.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    Task { await MorningSummaryModel.shared.report() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await MorningSummaryModel.shared.report() }
            case .background: MorningSummaryModel.shared.scheduleRefresh()
            default: break
            }
        }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// `-tab spending|ask|plan|activity`, `-ask "question"`, `-open …`, `-review`, `-settings`, `-opportunity [-price]`, `-networth`, `-tips`, `-gallery` — used for screenshots and UI tests.
    private static func applyLaunchArguments(_ args: [String], to model: AppModel) {
        func value(after flag: String) -> String? { Self.value(after: flag, in: args) }
        switch value(after: "-tab") {
        case "spending": model.selectedTab = .spending
        case "ask": model.selectedTab = .ask
        case "plan": model.selectedTab = .plan
        case "activity": model.selectedTab = .activity
        default: break
        }
        if let question = value(after: "-ask") {
            model.selectedTab = .ask
            model.pendingQuestion = question
        }
        // `-open recurring`, `-open spending/2026-08`, `-open category/dining[/2026-08]` — the same routes Ask's
        // navigate proposals take.
        if let open = value(after: "-open") {
            let parts = open.split(separator: "/").map(String.init)
            switch parts.first {
            case "recurring": model.route(Navigate(screen: .recurring))
            case "spending": model.route(Navigate(screen: .spending, month: parts.dropFirst().first))
            case "category" where parts.count > 1:
                model.route(Navigate(screen: .spending, categoryID: parts[1], month: parts.dropFirst(2).first))
            default: break
            }
        }
        if args.contains("-settings") { model.showsSettings = true }
        #if targetEnvironment(simulator)
        // `-pushToken HEX`: the morning summary registers with this instead of waiting on APNs.
        if let token = value(after: "-pushToken") { MorningSummaryModel.shared.useToken(token) }
        #endif
        // `-opportunity [-price 499]`: opportunity cost, with a price already in.
        if args.contains("-opportunity") { model.showsOpportunity = true }
        if let price = value(after: "-price") { model.pendingPrice = Decimal(string: price) }
        if args.contains("-networth") {
            model.selectedTab = .home
            model.showsNetWorth = true
        }
        if args.contains("-checkup") {
            model.selectedTab = .home
            model.showsCheckup = true
        }
        if args.contains("-review") {
            model.selectedTab = .activity
            model.opensFirstReview = true
        }
    }
}

enum SettingsKeys {
    static let serverURL = "serverURL"
    /// Keychain account for the bearer token.
    static let apiToken = "apiToken"
    static let useDemo = "useDemo"
    static let useLiveModel = "useLiveModel"
    static let liveModelURL = "liveModelURL"
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        if app.needsServer {
            ConnectView()
        } else {
            tabs
        }
    }

    @ViewBuilder
    private var tabs: some View {
        @Bindable var app = app
        TabView(selection: $app.selectedTab) {
            // Every place but Ask carries the price-check button, stacked above Ask's circle.
            Tab("Home", systemImage: "circle.grid.2x2", value: AppTab.home) { HomeView().priceCheckButton() }
            Tab("Spending", systemImage: "chart.pie", value: AppTab.spending) { SpendingView().priceCheckButton() }
            Tab("Activity", systemImage: "list.bullet.rectangle", value: AppTab.activity) { ActivityView().priceCheckButton() }
                .badge(app.reviewCount)
            Tab("Plan", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.plan) { PlanView().priceCheckButton() }
            // The search role sets Ask apart at the trailing end of the bar: one tap away from every
            // screen without taking a slot among the places.
            Tab("Ask", systemImage: "sparkle", value: AppTab.ask, role: .search) { AskView() }
        }
        .tint(Color.ds.ink)
        .sheet(isPresented: $app.showsOpportunity) { OpportunityView() }
        .task(id: app.revision) { await app.refreshShared() }
        .appLock()
    }
}
