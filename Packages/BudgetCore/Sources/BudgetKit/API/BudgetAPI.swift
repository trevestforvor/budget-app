import Foundation

/// Everything the iPhone app can ask of the Budget API on the Olares.
///
/// The app is a thin client: it renders what comes back and caches it. The agent loop,
/// categorization, and all math live behind this protocol. Swapping models or bank-data
/// providers happens server-side and never changes this surface.
public protocol BudgetAPI: Sendable {
    func overview() async throws -> Overview
    /// One month of the budget: the flex budget, each budget type's plan and spending with its categories, and the
    /// summary line. `month` is "2026-09"; nil is this month. A past month is worked out as of its end.
    func budget(month: String?) async throws -> BudgetMonth
    /// A spending category month by month (up to `months`, this one last) against today's target, with its average.
    func categoryHistory(id: String, months: Int) async throws -> CategoryHistory
    /// Every category, merged-away ones included (`isArchived`) so old rows still resolve; pickers leave those out.
    func categories() async throws -> [BudgetCategory]
    /// Categorization rules in the order they're tried (newest first; the first that matches files the row),
    /// each with what it filed, what it matches now, the rules it disagrees with, and whether its category is gone.
    func rules() async throws -> [RuleSummary]
    /// What merchant memory learned ("What Budget has learned"), most recently seen first.
    func rememberedMerchants() async throws -> [RememberedMerchant]
    /// `sumByCategory(range)`
    func spending(_ range: SpendingRange) async throws -> SpendingSummary
    /// `queryTransactions(filters)`: one page of the rows the filter matches, in its order.
    func transactions(_ filter: TransactionFilter) async throws -> [LedgerTransaction]
    /// One row as it is now, so a detail screen can reload after a change.
    func transaction(id: String) async throws -> LedgerTransaction
    /// Totals over every row the filter matches (paging ignored), by the Spending tab's rules.
    func transactionSummary(_ filter: TransactionFilter) async throws -> TransactionSummary
    /// Low-confidence items waiting for a person.
    func reviewQueue() async throws -> [ReviewItem]
    /// A correction: files the row and the rows waiting for review like it, and feeds merchant memory.
    /// Returns how many rows changed, with an undo.
    @discardableResult
    func confirmCategory(transactionID: String, categoryID: String) async throws -> ActionResult
    /// Natural-language question through the agent loop.
    func ask(_ question: String, conversationID: String?) async throws -> AskReply
    /// `projectBalance(account, horizon)`, optionally checking a goal.
    func projection(horizonMonths: Int, goal: GoalQuery?) async throws -> Projection
    func serverStatus() async throws -> ServerStatus
    /// Pulls every linked bank now (what the server also does on its schedule), one result per link. Connections
    /// waiting for a sign-in are skipped until they're reconnected on the dashboard.
    func syncNow() async throws -> [LinkSyncResult]
    /// Savings capacity and guidance (`savingsCapacity` + `savingsGuidance`), with monthly cash flow.
    func savingsPlan() async throws -> SavingsPlan
    /// Everything at once (`runCheckup`): month pace, categories, merchants, recurring, unusual, saving,
    /// outlook and data health, each finding marked good / watch / act.
    func checkup() async throws -> Checkup
    /// Recurring charges found in the ledger (`findSubscriptions`): subscriptions and bills, cadence, next charge.
    func subscriptions() async throws -> SubscriptionSummary
    /// Applies a change. The only write path for targets, categories, rules and re-filing —
    /// used by the app's own editors and by proposals the assistant made and the person applied.
    func perform(_ action: AppAction) async throws -> ActionResult
    /// What `perform(action)` would do, without doing it: the checks it runs, the proposal card's title, detail
    /// and effects, and the rows it reaches (a sample and counts) — for an editor's live preview.
    func preview(_ action: AppAction) async throws -> ActionPreview
    /// The system prompt and tool schemas the chat model runs with, for inspection.
    func assistantConfig() async throws -> AssistantConfig
    /// What's expected from today through `days` ahead: paychecks, bills, subscriptions and card bills, day by day
    /// (`GET /v1/upcoming`). Servers before `ServerStatus.upcomingSince` answer `.notFound`.
    func upcoming(days: Int) async throws -> Upcoming
    /// `perform(action)`, refused with a 409 when `basis` (the fingerprint an Ask proposal was made against) no longer
    /// matches the ledger. Nil checks nothing.
    func perform(_ action: AppAction, basis: String?) async throws -> ActionResult
    /// Changes an account's kind, nickname or last digits (`PATCH /v1/accounts/:id`). Servers before
    /// `ServerStatus.accountEditsSince` answer `.notFound`.
    func updateAccount(id: String, _ change: AccountChange) async throws -> AccountChangeResult
}

extension BudgetAPI {
    /// A client with no upcoming view (an older stub) has nothing to say.
    public func upcoming(days: Int) async throws -> Upcoming { throw BudgetAPIError.notFound }
    /// A client that can't check a basis applies the action as it is.
    public func perform(_ action: AppAction, basis: String?) async throws -> ActionResult { try await perform(action) }
    /// A client with no account editing (an older stub) has none.
    public func updateAccount(id: String, _ change: AccountChange) async throws -> AccountChangeResult { throw BudgetAPIError.notFound }
}

public enum BudgetAPIError: LocalizedError, Equatable {
    /// The server couldn't be found or connected to.
    case unreachable
    /// The phone has no connection at all.
    case offline
    /// The server didn't answer in time.
    case timedOut
    case server(status: Int, message: String?)
    case decoding(String)
    case notFound
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable: "Can't reach your Budget server. Check that it's on, and the server address in Settings → Advanced."
        case .offline: "You're offline."
        case .timedOut: "Your Budget server took too long to answer. Try again in a moment."
        case let .server(status, message): message ?? "The server returned \(status)."
        case let .decoding(detail): "Unexpected response from the server (\(detail))."
        case .notFound: "That item no longer exists."
        case let .rejected(reason): reason
        }
    }

    /// Nothing came back from the server — unreachable, offline or too slow — so a saved copy can stand in.
    public var isNoAnswer: Bool { self == .unreachable || self == .offline || self == .timedOut }
}
