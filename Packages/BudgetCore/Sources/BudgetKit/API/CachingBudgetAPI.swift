import Foundation

/// Stores the last good response for each read so the app still renders offline.
/// Writes (confirmations, questions) always go to the server.
public actor ResponseCache {
    nonisolated let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Every server's copies; clearing it clears them all.
    public static func appDefault() -> ResponseCache { ResponseCache(directory: root) }

    /// One server's copies, apart from any other's: a phone moved to another server never shows the old one's numbers,
    /// and moving back finds its own.
    public static func appDefault(for server: URL) -> ResponseCache {
        let name = [server.host(), server.port.map(String.init)].compactMap { $0 }.joined(separator: "-")
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        return ResponseCache(directory: root.appending(path: safe.isEmpty ? "server" : safe, directoryHint: .isDirectory))
    }

    private static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "BudgetResponses", directoryHint: .isDirectory)
    }

    func store(_ data: Data, for key: String) {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        // Encrypted at rest while the phone is locked. macOS rejects this option outright,
        // which silently disabled the cache on the Mac before.
        options.insert(.completeFileProtection)
        #endif
        try? data.write(to: url(for: key), options: options)
    }

    func load(_ key: String) -> Data? { try? Data(contentsOf: url(for: key)) }

    /// Forgets one read's copy, after a write that changed it.
    func remove(_ key: String) { try? FileManager.default.removeItem(at: url(for: key)) }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for key: String) -> URL {
        directory.appending(path: key.replacingOccurrences(of: "/", with: "_") + ".json")
    }
}

/// Reports whether the last read came from the network, from the offline copy, or couldn't be answered at all (the
/// server didn't answer and nothing was saved for it).
public enum Freshness: Sendable, Equatable {
    case live, cached, unreachable

    /// Whether the server isn't answering, whatever the phone could still show.
    public var isOffline: Bool { self != .live }
}

/// A read whose last good answer the phone keeps: shown offline, and shown at once while the fresh one loads.
public enum SavedRead: Hashable, Sendable {
    case overview, categories, rules, memory, review, transactions, status, savings, checkup, subscriptions, assistant
    case budget(month: String?)
    case spending(SpendingRange)
    case categoryHistory(id: String, months: Int)
    case projection(horizonMonths: Int)
    /// `GET /v1/networth?range=` ("3M").
    case netWorth(range: String)
    case scenarios(horizonMonths: Int)
    case cashFlowSankey(month: String?)
    case monthlyRecap(month: String?)
    case upcoming(days: Int)
    /// `GET /v1/holdings` (server 0.6.0).
    case holdings

    var key: String {
        switch self {
        case .overview: "overview"
        case .categories: "categories"
        case .rules: "rules"
        case .memory: "memory"
        case .review: "review"
        case .transactions: "transactions"
        case .status: "status"
        case .savings: "savings"
        case .checkup: "checkup"
        case .subscriptions: "subscriptions"
        case .assistant: "assistant"
        case let .budget(month): "budget-\(month ?? "current")"
        case let .spending(range): "spending-\(range.rawValue)"
        case let .categoryHistory(id, months): "category-history-\(id)-\(months)"
        case let .projection(horizon): "projection-\(horizon)"
        case let .netWorth(range): "networth-\(range)"
        case let .scenarios(horizon): "scenarios-\(horizon)"
        case let .cashFlowSankey(month): "flow-\(month ?? "current")"
        case let .monthlyRecap(month): "monthly-recap-\(month ?? "last")"
        case let .upcoming(days): "upcoming-\(days)"
        case .holdings: "holdings"
        }
    }
}

/// An API that keeps the last good answer to its reads on the phone.
public protocol SavedCopies: Sendable {
    /// The last good answer to `read` saved on this phone, or nil.
    func saved<T: Decodable & Sendable>(_ read: SavedRead, as type: T.Type) async -> T?
}

public struct CachingBudgetAPI: BudgetAPI {
    let upstream: any BudgetAPI
    private let cache: ResponseCache
    private let onFreshness: @Sendable (Freshness) -> Void

    public init(upstream: any BudgetAPI, cache: ResponseCache, onFreshness: @escaping @Sendable (Freshness) -> Void = { _ in }) {
        self.upstream = upstream
        self.cache = cache
        self.onFreshness = onFreshness
    }

    func read<T: Codable & Sendable>(_ saved: SavedRead, _ fetch: () async throws -> T) async throws -> T {
        let key = saved.key
        do {
            let value = try await fetch()
            if let data = try? RemoteBudgetAPI.encoder.encode(value) { await cache.store(data, for: key) }
            onFreshness(.live)
            return value
        } catch let error as BudgetAPIError where error.isNoAnswer {
            guard let data = await cache.load(key), let value = try? RemoteBudgetAPI.decoder.decode(T.self, from: data) else {
                onFreshness(.unreachable)
                throw error
            }
            onFreshness(.cached)
            return value
        }
    }

    public func overview() async throws -> Overview { try await read(.overview) { try await upstream.overview() } }
    public func budget(month: String?) async throws -> BudgetMonth {
        try await read(.budget(month: month)) { try await upstream.budget(month: month) }
    }
    public func categoryHistory(id: String, months: Int) async throws -> CategoryHistory {
        try await read(.categoryHistory(id: id, months: months)) { try await upstream.categoryHistory(id: id, months: months) }
    }
    public func categories() async throws -> [BudgetCategory] { try await read(.categories) { try await upstream.categories() } }
    public func rules() async throws -> [RuleSummary] { try await read(.rules) { try await upstream.rules() } }
    public func rememberedMerchants() async throws -> [RememberedMerchant] { try await read(.memory) { try await upstream.rememberedMerchants() } }
    public func spending(_ range: SpendingRange) async throws -> SpendingSummary {
        try await read(.spending(range)) { try await upstream.spending(range) }
    }

    public func transactions(_ filter: TransactionFilter) async throws -> [LedgerTransaction] {
        // Only the unfiltered first page is worth keeping offline.
        guard filter.isDefault else { return try await upstream.transactions(filter) }
        return try await read(.transactions) { try await upstream.transactions(filter) }
    }

    /// Offline, a row is found in the cached list when it's there.
    public func transaction(id: String) async throws -> LedgerTransaction {
        do {
            let row = try await upstream.transaction(id: id)
            onFreshness(.live)
            return row
        } catch let error as BudgetAPIError where error.isNoAnswer {
            guard let data = await cache.load(SavedRead.transactions.key), let rows = try? RemoteBudgetAPI.decoder.decode([LedgerTransaction].self, from: data),
                  let row = rows.first(where: { $0.id == id }) else {
                onFreshness(.unreachable)
                throw error
            }
            onFreshness(.cached)
            return row
        }
    }

    public func transactionSummary(_ filter: TransactionFilter) async throws -> TransactionSummary {
        try await upstream.transactionSummary(filter)
    }

    public func reviewQueue() async throws -> [ReviewItem] { try await read(.review) { try await upstream.reviewQueue() } }
    public func confirmCategory(transactionID: String, categoryID: String) async throws -> ActionResult {
        try await upstream.confirmCategory(transactionID: transactionID, categoryID: categoryID)
    }

    public func ask(_ question: String, conversationID: String?) async throws -> AskReply {
        try await upstream.ask(question, conversationID: conversationID)
    }

    public func projection(horizonMonths: Int, goal: GoalQuery?) async throws -> Projection {
        guard goal == nil else { return try await upstream.projection(horizonMonths: horizonMonths, goal: goal) }
        return try await read(.projection(horizonMonths: horizonMonths)) { try await upstream.projection(horizonMonths: horizonMonths, goal: nil) }
    }

    public func serverStatus() async throws -> ServerStatus { try await read(.status) { try await upstream.serverStatus() } }
    /// A sync is a write: it always goes to the server.
    public func syncNow() async throws -> [LinkSyncResult] { try await upstream.syncNow() }
    public func perform(_ action: AppAction) async throws -> ActionResult { try await upstream.perform(action) }
    public func perform(_ action: AppAction, basis: String?) async throws -> ActionResult { try await upstream.perform(action, basis: basis) }
    /// A write: the saved overview and status name the account the old way, so they're dropped.
    public func updateAccount(id: String, _ change: AccountChange) async throws -> AccountChangeResult {
        let result = try await upstream.updateAccount(id: id, change)
        await cache.remove(SavedRead.overview.key)
        await cache.remove(SavedRead.status.key)
        return result
    }
    /// A preview is worked out on the ledger as it is now, so it's never served from the offline copy.
    public func preview(_ action: AppAction) async throws -> ActionPreview { try await upstream.preview(action) }
    public func savingsPlan() async throws -> SavingsPlan { try await read(.savings) { try await upstream.savingsPlan() } }
    public func checkup() async throws -> Checkup { try await read(.checkup) { try await upstream.checkup() } }
    public func subscriptions() async throws -> SubscriptionSummary { try await read(.subscriptions) { try await upstream.subscriptions() } }
    /// Questions about the recurring list are only worth asking against the ledger as it is: never from the saved copy.
    public func recurringReview() async throws -> RecurringReview {
        guard let upstream = upstream as? any RecurringReviewAPI else { throw BudgetAPIError.notFound }
        return try await upstream.recurringReview()
    }
    public func monthlyRecap(month: String?) async throws -> MonthlyRecap {
        guard let api = upstream as? any MonthlyRecapAPI else { throw BudgetAPIError.notFound }
        return try await read(.monthlyRecap(month: month)) { try await api.monthlyRecap(month: month) }
    }
    public func upcoming(days: Int) async throws -> Upcoming { try await read(.upcoming(days: days)) { try await upstream.upcoming(days: days) } }
    public func assistantConfig() async throws -> AssistantConfig { try await read(.assistant) { try await upstream.assistantConfig() } }
}

extension CachingBudgetAPI: SavedCopies {
    public func saved<T: Decodable & Sendable>(_ read: SavedRead, as type: T.Type) async -> T? {
        guard let data = await cache.load(read.key) else { return nil }
        return try? RemoteBudgetAPI.decoder.decode(T.self, from: data)
    }
}

/// The morning summary is a write to the server's device list: it always goes upstream.
extension CachingBudgetAPI: MorningSummaryAPI {
    public func registerDevice(_ registration: DeviceRegistration) async throws -> DeviceStatus {
        try await morningSummary().registerDevice(registration)
    }

    public func sendTestSummary(token: String) async throws -> DeviceStatus {
        try await morningSummary().sendTestSummary(token: token)
    }

    private func morningSummary() throws -> any MorningSummaryAPI {
        guard let api = upstream as? any MorningSummaryAPI else { throw BudgetAPIError.rejected("This connection can't send notifications.") }
        return api
    }
}

/// Pace alerts are worked out on the server at the moment they're asked for: no saved copy.
extension CachingBudgetAPI: PaceAlertsAPI {
    public func paceAlerts() async throws -> PaceAlerts {
        guard let api = upstream as? any PaceAlertsAPI else { throw BudgetAPIError.notFound }
        return try await api.paceAlerts()
    }
}
