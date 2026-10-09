import BudgetKit
import DesignSystem
import Observation
import SwiftUI

enum AppTab: Hashable { case home, spending, ask, plan, activity }

/// App-wide state: which API we talk to, shared lookups, and cross-tab navigation.
/// Screens own their own loaded data; this only holds what several screens share.
@Observable @MainActor
final class AppModel {
    private(set) var api: any BudgetAPI
    private(set) var isDemo: Bool
    /// The demo ledger is compiled in only for the simulator. On a device the app needs a server.
    static let demoAvailable: Bool = {
        #if targetEnvironment(simulator)
        // `-noDemo` makes the simulator behave like a phone (for testing ConnectView).
        !ProcessInfo.processInfo.arguments.contains("-noDemo")
        #else
        false
        #endif
    }()

    /// A device with no server configured: the app shows ConnectView instead of the tabs.
    private(set) var needsServer = false
    private(set) var categories: [String: BudgetCategory] = [:]
    /// Decisions waiting for the person — review groups, not rows: one answer files a whole group
    /// (same account, same bank descriptor, same direction). The tab badge and Home callout show this.
    private(set) var reviewCount = 0
    /// Whether the review queue has loaded since the server was set; until it has, `reviewCount` 0 means "unknown",
    /// not "all clear".
    private(set) var reviewQueueLoaded = false
    /// Everything waiting for review, as the server ranks it; `reviewGroups` is the same, grouped.
    private(set) var reviewItems: [ReviewItem] = []
    /// Accounts by id, for "Gold Card ••1008" on rows and in a transaction's details.
    private(set) var accounts: [String: Account] = [:]
    private(set) var freshness: Freshness = .live
    /// Loads under way on screens that are showing the copy saved on the phone meanwhile; the badge says "Updating".
    private(set) var updating: Set<UUID> = []
    /// Bumped after any write so screens reload.
    private(set) var revision = 0
    var selectedTab: AppTab = .home
    var showsSettings = false
    var showsCheckup = false
    /// Opportunity cost, over whichever tab is showing.
    var showsOpportunity = false
    /// A price for opportunity cost to open with (`-price`, for screenshots); consumed by it.
    var pendingPrice: Decimal?
    /// Set by launch arguments or cross-screen actions; consumed by AskView.
    var pendingQuestion: String?
    var opensFirstReview = false
    /// Navigation requests from `navigate` actions, consumed by the target screen.
    var spendingRoute: SpendingRoute?
    var activitySearch: String?
    /// A day for Activity to show (a tap on Home's week strip); consumed by ActivityView.
    var activityDay: Date?
    var planHorizon: Int?
    /// A page for Ask to push (`-open conversations`, `-open assistantMemory`); consumed by AskView.
    var askRoute: AskRoute?
    private var configuration: (url: String?, token: String?, demo: Bool, live: String?)?
    private(set) var liveModel: String?
    /// The server's version, read the first time a write needs it (an older server drops parts of a new rule).
    private var serverVersion: String?

    struct SpendingRoute: Equatable {
        let id = UUID()
        var range: SpendingRange?
        var categoryID: String?
        /// A budget month ("2026-09") for Spending to show.
        var month: String?
        /// Open the recurring charges.
        var showsRecurring = false
    }

    init(serverURL: String?, token: String? = nil, demo: Bool, liveModelURL: String? = nil) {
        (api, isDemo) = (UnconfiguredBudgetAPI(), false)
        configure(serverURL: serverURL, token: token, demo: demo, liveModelURL: liveModelURL)
    }

    /// Rebuilds the API only when the server settings actually changed — rebuilding
    /// the demo API would otherwise discard every change applied to its ledger.
    /// - Parameter liveModelURL: with the demo ledger, run Ask and decisions on this OpenAI-compatible
    ///   endpoint (Qwen on the Olares) instead of the templated engine. A dev bridge until the server
    ///   exists: the agent loop then runs on the phone, which is not the intended thin-client shape.
    /// - Parameter token: the server's bearer token (`BUDGET_API_TOKEN`), from the Keychain.
    func configure(serverURL: String?, token: String? = nil, demo requestedDemo: Bool, liveModelURL: String? = nil) {
        let demo = requestedDemo && Self.demoAvailable
        let normalized = serverURL?.trimmingCharacters(in: .whitespaces)
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let live = demo ? liveModelURL?.trimmingCharacters(in: .whitespaces).nilIfEmpty : nil
        if let configuration, configuration.demo == demo, configuration.live == live,
           demo || (configuration.url == normalized && configuration.token == token) { return }
        configuration = (normalized, token, demo, live)
        liveModel = nil
        if !demo, let serverURL, let url = URL(string: serverURL.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true {
            api = CachingBudgetAPI(upstream: RemoteBudgetAPI(baseURL: url, token: token), cache: .appDefault(for: url)) { [weak self] freshness in
                Task { @MainActor in self?.freshness = freshness }
            }
            isDemo = false
            needsServer = false
        } else if let live, let url = URL(string: live), url.scheme?.hasPrefix("http") == true {
            api = DemoBudgetAPI.live(baseURL: url)
            liveModel = url.host()
            isDemo = true
            needsServer = false
        } else if Self.demoAvailable {
            api = DemoBudgetAPI(now: AppClock.now)
            isDemo = true
            needsServer = false
        } else {
            api = UnconfiguredBudgetAPI()
            isDemo = false
            needsServer = true
        }
        categories = [:]
        accounts = [:]
        freshness = .live
        serverVersion = nil
        reviewQueueLoaded = false
        revision += 1
    }

    func refreshShared() async {
        // Before anything answers, the saved copies: a screen showing its own saved copy needs category names, accounts
        // and the review count with it.
        if categories.isEmpty, let list: [BudgetCategory] = await saved(.categories) {
            categories = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if accounts.isEmpty, let overview: Overview = await saved(.overview) {
            accounts = Dictionary(overview.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        if !reviewQueueLoaded, reviewItems.isEmpty, let queue: [ReviewItem] = await saved(.review) {
            reviewItems = queue
            reviewCount = ReviewGroup.groups(queue).count
        }
        if let list = try? await api.categories() {
            categories = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        }
        if let queue = try? await api.reviewQueue() {
            reviewItems = queue
            reviewCount = ReviewGroup.groups(queue).count
            reviewQueueLoaded = true
        }
        if accounts.isEmpty { await refreshAccounts() }
    }

    /// Account names only change with a sync that adds an account, so they load once and again on request.
    func refreshAccounts() async {
        if let overview = try? await api.overview() {
            accounts = Dictionary(overview.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The last good answer to `read` saved on this phone (nil for the demo, which has nothing to wait for).
    func saved<T: Decodable & Sendable>(_ read: SavedRead, as type: T.Type = T.self) async -> T? {
        guard !isDemo, let copies = api as? any SavedCopies else { return nil }
        return await copies.saved(read, as: type)
    }

    /// While a screen showing a saved copy fetches the fresh one, the badge says "Updating": call this before the fetch
    /// and `endUpdating` after. (Not a closure around the fetch: with an `async let` still running, the runtime aborts.)
    func beginUpdating(showingSaved: Bool) -> UUID? {
        guard showingSaved else { return nil }
        let id = UUID()
        updating.insert(id)
        return id
    }

    func endUpdating(_ id: UUID?) {
        if let id { updating.remove(id) }
    }

    /// Call after a write so every screen reloads from the ledger.
    func didWrite() async {
        revision += 1
        await refreshShared()
    }

    /// The one way the app changes anything — the app's own editors and applied proposals both land here.
    @discardableResult
    func perform(_ action: AppAction) async throws -> String {
        if case let .navigate(destination) = action {
            route(destination)
            return "Opened."
        }
        try await checkServer(for: action)
        let result = try await api.perform(action)
        await didWrite()
        return result.message
    }

    /// Refuses a write the server is too old to store as asked, before it's sent. Every write path calls it.
    func checkServer(for action: AppAction) async throws {
        guard !isDemo, let minimum = action.minimumServer else { return }
        if serverVersion == nil { serverVersion = try await api.serverStatus().version }
        guard let serverVersion, ServerStatus.version(serverVersion, isAtLeast: minimum) else {
            throw BudgetAPIError.rejected(action.hasRuleConditions
                ? "The Budget server on your Olares is older than this app and would save a broader rule than this one. Update the server, then try again."
                : "The Budget server on your Olares is older than this app and can't keep this yet. Update the server, then try again.")
        }
    }

    /// Whether the server is `minimum` or newer, for showing a feature an older one can't answer (always in the demo;
    /// false while the server can't be asked).
    func serverSupports(_ minimum: String) async -> Bool {
        guard !isDemo else { return true }
        if serverVersion == nil { serverVersion = try? await api.serverStatus().version }
        return serverVersion.map { ServerStatus.version($0, isAtLeast: minimum) } ?? false
    }

    /// Opportunity cost from anywhere (the Home button, the Check a Price shortcut). Settings is closed first: it's
    /// a sheet too, and two can't be up at once.
    func openOpportunity() {
        showsSettings = false
        showsOpportunity = true
    }

    func route(_ destination: Navigate) {
        switch destination.screen {
        case .home: selectedTab = .home
        case .spending:
            spendingRoute = SpendingRoute(range: destination.range, categoryID: destination.categoryID, month: destination.month)
            selectedTab = .spending
        case .recurring:
            spendingRoute = SpendingRoute(showsRecurring: true)
            selectedTab = .spending
        case .ask: selectedTab = .ask
        case .plan:
            planHorizon = destination.horizonMonths
            selectedTab = .plan
        case .activity:
            activitySearch = destination.search
            selectedTab = .activity
        case .settings:
            selectedTab = .home
            showsSettings = true
        }
    }

    /// Activity with only `day`'s transactions.
    func showActivity(on day: Date) {
        activityDay = day
        selectedTab = .activity
    }

    /// Opens Ask with `question` on a fresh conversation — what every "Ask about this" button does.
    func ask(_ question: String) {
        pendingQuestion = question
        selectedTab = .ask
    }

    func category(_ id: String?) -> BudgetCategory? { id.flatMap { categories[$0] } }

    func account(_ id: String?) -> Account? { id.flatMap { accounts[$0] } }

    /// The review queue as decisions: rows one answer files together, the ones that file the most first.
    var reviewGroups: [ReviewGroup] { ReviewGroup.groups(reviewItems) }

    /// Categories to pick from — spending, then money in, then Transfer, each by name. Merged-away ones are left out
    /// (they still resolve by id for old rows).
    var sortedCategories: [BudgetCategory] {
        func rank(_ c: BudgetCategory) -> Int { c.countsAsSpending ? 0 : c.isMoneyIn ? 1 : 2 }
        return categories.values.filter { !$0.isArchived }.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }

    var privacyState: DSPrivacyBadge.State {
        if isDemo { return .demo }
        if !updating.isEmpty, freshness != .unreachable { return .updating }
        switch freshness {
        case .live: return .local
        case .cached: return .cached
        case .unreachable: return .unreachable
        }
    }
}

extension AppAction {
    /// The first server that stores this as asked, for an action older servers would drop or refuse.
    var minimumServer: String? {
        switch self {
        case .createBudgetRule where hasRuleConditions: ServerStatus.rulesWithConditionsSince
        case let .editTransactions(p) where !(p.addTags ?? []).isEmpty || !(p.removeTags ?? []).isEmpty: ServerStatus.tagsSince
        case let .editTransactions(p) where p.fileSimilar == true: ServerStatus.fileSimilarSince
        case let .editTransactions(p) where p.isYearly != nil: ServerStatus.yearlyAndRecurringSince
        case .setRecurring: ServerStatus.yearlyAndRecurringSince
        case .rememberFact: ServerStatus.assistantSince
        default: nil
        }
    }

    /// A new rule with an account, direction or amount condition — what servers before 0.2.0 drop.
    var hasRuleConditions: Bool {
        guard case let .createBudgetRule(p) = self else { return false }
        let m = p.match.normalized
        return m.direction != nil || m.minAmount != nil || m.maxAmount != nil || m.accountID != nil
    }
}

/// A screen's view of one remote read.
enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

extension LoadState {
    /// The next state after a fetch. Keeps the last value on failure so a refresh never blanks the screen;
    /// only surfaces errors when there's nothing to show.
    @MainActor
    func refreshed(_ fetch: () async throws -> Value) async -> LoadState {
        do {
            return .loaded(try await fetch())
        } catch {
            if Task.isCancelled || value != nil { return self }
            return .failed(error.localizedDescription)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Today, wherever the app means "this month", "late" or "how long ago": the device clock, except in the simulator with
/// `-demoDate YYYY-MM-DD`, which moves the whole app (and the demo ledger built from it) to noon that day. UI tests and
/// screenshots pass it so they see the same month whatever day they run; on the 1st the real month has barely begun.
enum AppClock {
    private static let offset: TimeInterval = {
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoDate"), args.indices.contains(i + 1) else { return 0 }
        let parts = args[i + 1].split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return 0 }
        return day.timeIntervalSinceNow
        #else
        0
        #endif
    }()

    static var now: Date { Date.now.addingTimeInterval(offset) }
}
