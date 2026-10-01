import AppIntents

/// "Check a Price": opens Budget straight to the opportunity-cost camera. It's listed in Shortcuts and Spotlight, and
/// under Settings → Action Button → Shortcut, so the Action button can open it in one press.
struct CheckPriceIntent: AppIntent {
    static let title: LocalizedStringResource = "Check a Price"
    static let description = IntentDescription("Open the camera and see what a price costs in hours of work and in growth given up.")
    static let supportedModes: IntentModes = .foreground

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        app.openOpportunity()
        return .result()
    }
}

struct BudgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CheckPriceIntent(),
                    phrases: ["Check a price in \(.applicationName)", "What does this cost in \(.applicationName)"],
                    shortTitle: "Check a Price", systemImageName: "tag")
    }
}
