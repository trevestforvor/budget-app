import BudgetKit
import Foundation

/// What a device talks to before a server is set: nothing. The demo ledger exists only in the simulator,
/// so on a phone an unconfigured app refuses every call instead of showing made-up money.
struct UnconfiguredBudgetAPI: BudgetAPI {
    private var notConnected: BudgetAPIError { .rejected("Connect to your Budget server first.") }

    func overview() async throws -> Overview { throw notConnected }
    func budget(month: String?) async throws -> BudgetMonth { throw notConnected }
    func categoryHistory(id: String, months: Int) async throws -> CategoryHistory { throw notConnected }
    func categories() async throws -> [BudgetCategory] { throw notConnected }
    func rules() async throws -> [RuleSummary] { throw notConnected }
    func rememberedMerchants() async throws -> [RememberedMerchant] { throw notConnected }
    func spending(_ range: SpendingRange) async throws -> SpendingSummary { throw notConnected }
    func transactions(_ filter: TransactionFilter) async throws -> [LedgerTransaction] { throw notConnected }
    func transaction(id: String) async throws -> LedgerTransaction { throw notConnected }
    func transactionSummary(_ filter: TransactionFilter) async throws -> TransactionSummary { throw notConnected }
    func reviewQueue() async throws -> [ReviewItem] { throw notConnected }
    func confirmCategory(transactionID: String, categoryID: String) async throws -> ActionResult { throw notConnected }
    func ask(_ question: String, conversationID: String?) async throws -> AskReply { throw notConnected }
    func projection(horizonMonths: Int, goal: GoalQuery?) async throws -> Projection { throw notConnected }
    func serverStatus() async throws -> ServerStatus { throw notConnected }
    func syncNow() async throws -> [LinkSyncResult] { throw notConnected }
    func savingsPlan() async throws -> SavingsPlan { throw notConnected }
    func checkup() async throws -> Checkup { throw notConnected }
    func subscriptions() async throws -> SubscriptionSummary { throw notConnected }
    func perform(_ action: AppAction) async throws -> ActionResult { throw notConnected }
    func preview(_ action: AppAction) async throws -> ActionPreview { throw notConnected }
    func assistantConfig() async throws -> AssistantConfig { throw notConnected }
}
