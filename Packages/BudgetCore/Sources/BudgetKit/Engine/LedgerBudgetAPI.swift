import Foundation

/// Where ledger changes are written. The server's implementation is Postgres; tests use memory.
public protocol LedgerPersistence: Sendable {
    /// Called after every change with the state before and after, so implementations can write a diff.
    func save(from old: LedgerState, to new: LedgerState) async throws
}

/// Which client serves each decision provider.
public struct DecisionRouting: Sendable {
    public var local: (any DecisionModel)?
    public var laya: (any DecisionModel)?
    public var jev: (any DecisionModel)?
    /// Demo only: fall back to the deterministic stand-in when a provider isn't configured.
    public var allowDemoFallback: Bool

    public init(local: (any DecisionModel)? = nil, laya: (any DecisionModel)? = nil, jev: (any DecisionModel)? = nil, allowDemoFallback: Bool = false) {
        self.local = local
        self.laya = laya
        self.jev = jev
        self.allowDemoFallback = allowDemoFallback
    }

    public func model(for provider: DecisionProvider) throws -> (any DecisionModel)? {
        let configured: (any DecisionModel)? = switch provider {
        case .off: nil
        case .localDecide: local
        case .laya: laya
        case .jev: jev
        }
        if provider == .off { return nil }
        if let configured { return configured }
        if allowDemoFallback { return DemoDecisionModel(provider: provider) }
        throw BudgetAPIError.rejected("The \(provider.displayName) decision model isn't configured on the server.")
    }
}

/// A plain count of what the ledger holds — for the server's dashboard, not the phone.
public struct LedgerStats: Codable, Hashable, Sendable {
    public var accounts: Int
    public var rows: Int
    public var pending: Int
    public var needsReview: Int
    public var earliest: Date?
    public var latest: Date?
    /// Rows by how they were categorized (`CategorizationTier` raw values, plus "none").
    public var byTier: [String: Int]
    /// Rows by where they came from (`SourceKind` raw values).
    public var bySource: [String: Int]
    /// Normalized descriptors that now categorize themselves.
    public var rememberedMerchants: Int
    public var rules: Int
    public var targets: Int
    public var merchantCaps: Int
}

/// What `serverStatus()` reports about the deployment.
public struct DeploymentInfo: Sendable {
    public var endpoint: String
    public var version: String
    public var sources: [SourceKind]
    /// The provider links (the server's) or the demo's institution plan.
    public var institutions: [InstitutionLink]
    /// The dashboard's address, for the phone's "Open dashboard".
    public var dashboardURL: String?

    public init(endpoint: String, version: String, sources: [SourceKind], institutions: [InstitutionLink], dashboardURL: String? = nil) {
        self.endpoint = endpoint
        self.version = version
        self.sources = sources
        self.institutions = institutions
        self.dashboardURL = dashboardURL
    }
}

public typealias DemoBudgetAPI = LedgerBudgetAPI

/// The Budget API over a `Ledger`. The server runs it against Postgres-backed state with real
/// sources and models; the app's demo mode runs it over fixtures. Same code, same numbers.
public actor LedgerBudgetAPI: BudgetAPI {
    var ledger: Ledger
    private let latency: Duration
    private let clock: (@Sendable () -> Date)?
    /// When set, Ask runs the real agent loop; otherwise the templated demo engine answers.
    private var chatModel: (any ChatModel)?
    private var decisions: DecisionRouting
    private let persistence: (any LedgerPersistence)?
    var deployment: DeploymentInfo
    private var escalatedAccepts = 0
    private var escalationNote: String?
    /// Ask's conversations (`ChatSessionStore`): in memory unless the server hands over its own.
    var chatStore: any ChatSessionStore = InMemoryChatSessionStore()
    /// The demo fills its chat history with a few conversations the first time it's read.
    var seedsDemoChats = false
    /// The demo's seeding under way; every chat read waits for it, so none sees half of it.
    var demoChatSeeding: Task<Void, Never>?
    /// Chat turns are recorded one at a time (`recordingTurn`).
    var recordingChat = false
    var waitingChatRecorders: [CheckedContinuation<Void, Never>] = []
    /// Daily balances recorded at sync, for net worth history (`LedgerBudgetAPI+NetWorth.swift`). Kept apart from the
    /// ledger: it grows every day.
    var balanceHistory: any BalanceHistoryStore = MemoryBalanceHistory()

    /// Server: persisted state, the wall clock, configured models.
    public init(state: LedgerState, calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { .now },
                chatModel: (any ChatModel)?, decisions: DecisionRouting, persistence: (any LedgerPersistence)?, deployment: DeploymentInfo) {
        ledger = Ledger(state: state, now: clock(), calendar: calendar)
        latency = .zero
        self.clock = clock
        self.chatModel = chatModel
        self.decisions = decisions
        self.persistence = persistence
        self.deployment = deployment
    }

    /// Demo: fixture ledger at a fixed `now`, deterministic decisions unless live models are given.
    public init(now: Date = .now, calendar: Calendar = .current, seed: UInt64 = 7, latency: Duration = .milliseconds(300),
                chatModel: (any ChatModel)? = nil, decisionModel: (any DecisionModel)? = nil) {
        ledger = Ledger(now: now, calendar: calendar, seed: seed)
        self.latency = latency
        clock = nil
        self.chatModel = chatModel
        decisions = DecisionRouting(local: decisionModel, allowDemoFallback: true)
        persistence = nil
        // The demo's connected institutions last synced a couple of hours ago — except Tidewater, whose sign-in
        // expired twelve days ago, so the demo shows what a connection that needs you looks like.
        let institutions = Ledger.institutionPlan.map { link in
            var link = link
            if link.id == Self.demoExpiredLinkID {
                link.status = .needsReauth
                link.lastSync = now.addingTimeInterval(-12 * 86_400)
                link.lastError = "The sign-in expired."
            } else if link.status == .demo {
                link.lastSync = now.addingTimeInterval(-2 * 3600)
            }
            return link
        }
        deployment = DeploymentInfo(endpoint: "demo://ledger", version: "demo", sources: [.teller, .plaid, .fileImport], institutions: institutions)
        seedsDemoChats = true
        balanceHistory = MemoryBalanceHistory(ledger.demoBalanceSnapshots())
    }

    /// The demo connection that waits for a sign-in (balance-only, so no spending figure depends on it).
    static let demoExpiredLinkID = "tidewater"

    /// Demo ledger + live models on the Olares (chat on `baseURL`, categorizing via /v1/systemone on the same server).
    public static func live(baseURL: URL, model: String = "qwen3.8-27b") -> LedgerBudgetAPI {
        LedgerBudgetAPI(latency: .zero, chatModel: OpenAIChatModel(baseURL: baseURL, model: model),
                        decisionModel: SystemOneDecisionModel(transport: .selfHosted(baseURL: baseURL, model: "clef", apiKey: nil)))
    }

    public var state: LedgerState { ledger.state }

    /// Demo fixtures as a persistable state (seeding a test server).
    public static func demoState(now: Date = .now, calendar: Calendar = .current, seed: UInt64 = 7) -> LedgerState {
        Ledger(now: now, calendar: calendar, seed: seed).state
    }

    public func setInstitutions(_ institutions: [InstitutionLink]) { deployment.institutions = institutions }
    /// The ledger's accounts as they are, without working out an overview.
    public func accountList() -> [Account] { ledger.accounts }
    public func setSources(_ sources: [SourceKind]) { deployment.sources = sources }
    public func setEndpoint(_ endpoint: String) { deployment.endpoint = endpoint }
    public func setDashboardURL(_ url: String?) { deployment.dashboardURL = url }

    /// Swaps the models when the server's settings change; the ledger is untouched.
    public func reconfigure(chatModel: (any ChatModel)?, decisions: DecisionRouting) {
        self.chatModel = chatModel
        self.decisions = decisions
    }

    /// A new time zone moves month boundaries; the rows themselves don't change.
    public func setCalendar(_ calendar: Calendar) {
        ledger = Ledger(state: ledger.state, now: clock?() ?? ledger.now, calendar: calendar)
    }

    // MARK: Plumbing

    func tick() {
        if let clock { ledger.now = clock() }
    }

    func pause(_ factor: Double = 1) async {
        guard latency > .zero else { return }
        try? await Task.sleep(for: latency * factor)
    }

    /// Ledger writes take turns, from reading `before` to the end of the save. The save suspends, and two writes
    /// overlapping there could roll back each other's changes when one fails, or reach Postgres in the wrong order. Model
    /// calls happen before a write starts, so each holds its turn only as long as its save.
    private var writing = false
    private var waitingWriters: [CheckedContinuation<Void, Never>] = []

    /// Makes `change` (synchronous, so nothing else runs in the middle of it) and saves it, taking its turn.
    func write<T>(_ change: () throws -> T) async throws -> T {
        if writing { await withCheckedContinuation { waitingWriters.append($0) } } else { writing = true }
        defer { if waitingWriters.isEmpty { writing = false } else { waitingWriters.removeFirst().resume() } }
        let before = ledger.state
        let result = try change()
        try await commit(from: before)
        return result
    }

    /// Persists the diff since `before`. On a persistence failure the in-memory ledger is rolled back; with writes taking
    /// turns, `before` is exactly what was saved last.
    private func commit(from before: LedgerState) async throws {
        guard let persistence else { return }
        do {
            try await persistence.save(from: before, to: ledger.state)
        } catch {
            ledger = Ledger(state: before, now: ledger.now, calendar: ledger.calendar)
            throw error
        }
    }

    var toolbox: DemoToolbox {
        DemoToolbox(ledger: ledger, decisions: try? decisions.model(for: ledger.decisionPolicy.isActive ? ledger.decisionPolicy.provider : .localDecide),
                    institutions: deployment.institutions, balanceHistory: balanceHistory)
    }

    // MARK: BudgetAPI

    public func overview() async throws -> Overview {
        tick(); await pause()
        return ledger.overview(institutions: deployment.institutions)
    }

    public func budget(month: String?) async throws -> BudgetMonth {
        tick(); await pause(0.6)
        return try ledger.budgetMonth(month)
    }

    public func categoryHistory(id: String, months: Int) async throws -> CategoryHistory {
        tick(); await pause(0.4)
        return try ledger.categoryHistory(id, months: months)
    }

    public func categories() async throws -> [BudgetCategory] { ledger.categories }

    public func rules() async throws -> [RuleSummary] {
        tick(); await pause(0.4)
        return ledger.ruleSummaries()
    }

    public func rememberedMerchants() async throws -> [RememberedMerchant] {
        tick(); await pause(0.4)
        return ledger.merchantMemoryEntries()
    }

    public func preview(_ action: AppAction) async throws -> ActionPreview {
        tick(); await pause(0.3)
        try checkAvailable(action)
        var preview = try ledger.preview(action)
        preview.basis = try ledger.basis(for: action)?.fingerprint
        return preview
    }

    public func spending(_ range: SpendingRange) async throws -> SpendingSummary {
        tick(); await pause()
        return ledger.spendingSummary(range)
    }

    public func transactions(_ filter: TransactionFilter) async throws -> [LedgerTransaction] {
        tick(); await pause(0.6)
        try validate(filter)
        return ledger.query(filter)
    }

    public func transaction(id: String) async throws -> LedgerTransaction {
        tick()
        guard let row = ledger.transactions.first(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
        return ledger.presented(row)
    }

    public func transactionSummary(_ filter: TransactionFilter) async throws -> TransactionSummary {
        tick(); await pause(0.4)
        try validate(filter)
        return ledger.summary(filter)
    }

    /// A period the ledger can't read is refused rather than matching nothing.
    func validate(_ filter: TransactionFilter) throws {
        if let period = filter.period, ledger.interval(forPeriod: period) == nil { throw BudgetAPIError.rejected("Unknown period “\(period)”.") }
    }

    public func reviewQueue() async throws -> [ReviewItem] {
        tick(); await pause(0.6)
        return ledger.reviewItems
    }

    public func confirmCategory(transactionID: String, categoryID: String) async throws -> ActionResult {
        tick(); await pause(0.5)
        return try await write { try ledger.confirm(transactionID: transactionID, categoryID: categoryID) }
    }

    public func projection(horizonMonths: Int, goal: GoalQuery?) async throws -> Projection {
        tick(); await pause()
        return ledger.projection(horizonMonths: horizonMonths, goal: goal)
    }

    public func serverStatus() async throws -> ServerStatus {
        tick()
        let policy = ledger.decisionPolicy
        let decisionLabel = policy.isActive ? (try? decisions.model(for: policy.provider))??.label : nil
        let institutions = ledger.institutionLinks(deployment.institutions)
        return ServerStatus(
            endpoint: deployment.endpoint, version: deployment.version,
            // Receipts (vision) isn't built, so it isn't listed as a job.
            roles: ModelRole.allCases.filter { $0 != .vision }.map { role in
                let model: String? = switch role {
                case .chat, .plan: chatModel?.label
                case .categorize: decisions.local?.label
                case .vision: nil
                }
                return RoleAssignment(role: role, model: model, evalsPassed: false, evalScore: nil)
            },
            discoveredModels: [], sources: deployment.sources, rawDataStaysLocal: !policy.usesJev,
            lastSync: institutions.compactMap(\.lastSync).max(),
            decisionPolicy: policy, decisionModel: decisionLabel, decisionSample: decisionSample(), institutions: institutions,
            availableDecisionProviders: availableProviders(), dashboardURL: deployment.dashboardURL)
    }

    /// The ledger alone holds no provider links — on the server `SyncService` owns them, behind `POST /v1/sync` — so
    /// this is the demo's sync: each demo institution reports in with nothing new. Real links are never touched here.
    public func syncNow() async throws -> [LinkSyncResult] {
        tick(); await pause(3)
        let now = ledger.now
        var results: [LinkSyncResult] = []
        for index in deployment.institutions.indices where deployment.institutions[index].status == .demo {
            deployment.institutions[index].lastSync = now
            deployment.institutions[index].lastError = nil
            let link = deployment.institutions[index]
            results.append(LinkSyncResult(linkID: link.id, institution: link.institution, ok: true,
                                          report: IngestReport(batchID: "demo-sync-\(link.id)", source: link.primary ?? .plaid)))
        }
        return results
    }

    /// Answers within a conversation: a known `conversationID` continues it (the model sees the turns before), a new one
    /// or none starts one. Either way the turn is kept in chat history (`LedgerBudgetAPI+Assistant.swift`).
    public func ask(_ question: String, conversationID: String?) async throws -> AskReply {
        try await ask(question, conversationID: conversationID, capabilities: .all)
    }

    /// `ask`, for an app that can take back only `capabilities` (`AskCapabilities`): tools and fields it can't are never
    /// offered, and any proposal it couldn't show or apply as proposed is left out of the reply.
    public func ask(_ question: String, conversationID: String?, capabilities: AskCapabilities) async throws -> AskReply {
        tick()
        // The id names a kept conversation (and a path segment), so it's short and not blank; apps send a UUID.
        let given = conversationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let given, given.count > ChatSession.maxIDLength {
            throw BudgetAPIError.rejected("A conversation id is at most \(ChatSession.maxIDLength) characters.")
        }
        let id = given.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let (history, existed) = await chatHistory(for: id)
        var reply: AskReply
        let transcript: [ChatMessage]
        if let chatModel {
            let outcome = try await AgentLoop(model: chatModel, toolbox: toolbox, capabilities: capabilities)
                .run(question, conversationID: id, history: history)
            reply = outcome.reply
            transcript = Array(outcome.transcript.dropFirst(1 + history.count))
        } else {
            await pause(2.5)
            let recorded = (try? await balanceHistory.balanceSnapshots()) ?? []
            reply = DemoAskEngine(ledger: ledger, institutions: deployment.institutions, balanceSnapshots: recorded, capabilities: capabilities)
                .answer(question, conversationID: id)
            transcript = []
        }
        // The backstop: an app that can't decode a proposal fails the whole reply.
        reply.proposedActions.removeAll { !capabilities.allows($0.action) }
        await recordTurn(question, reply: reply, transcript: transcript, in: id, existed: existed)
        return reply
    }

    /// Runs the agent loop and returns the full outcome (steps, repairs, grounding) — for tools and tests.
    public func askLive(_ question: String, thinking: Bool = false) async throws -> AgentOutcome {
        tick()
        guard let chatModel else { throw BudgetAPIError.rejected("No chat model configured.") }
        return try await AgentLoop(model: chatModel, toolbox: toolbox, thinking: thinking).run(question)
    }

    /// Refuses a policy the server can't run, instead of failing every sync after it.
    private func checkAvailable(_ action: AppAction) throws {
        guard case let .updateDecisionPolicy(update) = action else { return }
        let next = update.applied(to: ledger.decisionPolicy)
        if next.isActive, (try? decisions.model(for: next.provider)) == nil {
            throw BudgetAPIError.rejected("\(next.provider.displayName) isn't set up on the server\(next.provider == .jev ? " — add an OpenRouter key in the dashboard's Server settings first" : "").")
        }
        if next.isActive, next.provider.runsLocally, next.escalateToJev, (try? decisions.model(for: .jev)) == nil {
            throw BudgetAPIError.rejected("Asking Jev needs an OpenRouter key on the server — add one in the dashboard's Server settings first.")
        }
    }

    public func perform(_ action: AppAction) async throws -> ActionResult { try await perform(action, basis: nil) }

    /// With a basis (the fingerprint an Ask proposal was made against), the action is refused with a 409 when the rows it
    /// reaches changed since — checked inside the same write as the change, so nothing slips in between.
    public func perform(_ action: AppAction, basis: String?) async throws -> ActionResult {
        tick(); await pause(0.5)
        try checkAvailable(action)
        // The change is saved before any model is asked. A re-run that can't reach the model used to throw with the policy
        // changed in memory but never saved, so a restart quietly undid it.
        var result = try await write {
            if let basis, let current = try ledger.basis(for: action), current.fingerprint != basis {
                throw BudgetAPIError.server(status: 409, message: "Your data changed since this was proposed (\(current.rowCount) transaction\(current.rowCount == 1 ? "" : "s") now). Refresh it to see what it would do now.")
            }
            return try ledger.perform(action)
        }
        if case let .updateDecisionPolicy(update) = action, ledger.decisionPolicy.isActive, update.reruns {
            escalatedAccepts = 0
            escalationNote = nil
            do {
                let (accepted, pending, milliseconds) = try await runDecisionsOnReviewQueue()
                if accepted + pending > 0 {
                    let byJev = escalatedAccepts > 0 ? " (\(escalatedAccepts) by Jev)" : ""
                    let time = String(format: " Model time %.1f s.", Double(milliseconds) / 1000)
                    result.message += " Auto-accepted \(accepted) of \(accepted + pending) waiting\(byJev); \(pending) still need\(pending == 1 ? "s" : "") you.\(time)"
                    if let escalationNote { result.message += " " + escalationNote }
                }
                result.affectedTransactions = accepted
            } catch {
                result.message += " Couldn't re-check the review queue (\(error.localizedDescription)); it's unchanged."
            }
        }
        return result
    }

    /// Changes an account's kind, nickname or last digits (`PATCH /v1/accounts/:id`).
    public func updateAccount(id: String, _ change: AccountChange) async throws -> AccountChangeResult {
        tick()
        return try await write { try ledger.updateAccount(id: id, change) }
    }

    public func subscriptions() async throws -> SubscriptionSummary {
        tick(); await pause(0.5)
        return ledger.subscriptions()
    }

    /// "Is this recurring?" and "Did this stop?" (`RecurringReviewAPI`).
    public func recurringReview() async throws -> RecurringReview {
        tick(); await pause(0.5)
        return ledger.recurringReview()
    }

    /// A finished month in review (`MonthlyRecapAPI`), with the month's change in net worth from the recorded balances
    /// when they cover it; otherwise (no history yet, or it can't be read) the recap shows the change in cash.
    public func monthlyRecap(month: String?) async throws -> MonthlyRecap {
        tick(); await pause(0.5)
        let snapshots = try? await balanceHistory.balanceSnapshots()
        return try ledger.monthlyRecap(month, snapshots: snapshots)
    }

    public func checkup() async throws -> Checkup {
        tick(); await pause(0.8)
        return ledger.checkup(institutions: deployment.institutions)
    }

    /// This month's pace and what's past a threshold (`Ledger.paceAlerts`). `asOf` works it out at another instant
    /// (the pace-alert scheduler's clock) without moving the ledger's own.
    public func paceAlerts(asOf: Date?) async throws -> PaceAlerts {
        tick()
        guard let asOf else { return ledger.paceAlerts() }
        var at = ledger
        at.now = asOf
        return at.paceAlerts()
    }

    public func paceAlerts() async throws -> PaceAlerts {
        try await paceAlerts(asOf: nil)
    }

    public func upcoming(days: Int) async throws -> Upcoming {
        tick(); await pause(0.4)
        return ledger.upcoming(days: days)
    }

    /// Stores each card's statement from its issuer (`SyncService`, after a Plaid sync with card bills on). Returns how
    /// many cards took one.
    @discardableResult
    public func applyCardBills(_ bills: [SourceCardBill], source: SourceKind) async throws -> Int {
        tick()
        let now = clock?() ?? ledger.now
        return try await write { ledger.applyCardBills(bills, source: source, at: now) }
    }

    /// The morning summary for `day` ("2026-09-28", a day in the ledger's calendar): the ledger's figures and facts,
    /// retold by the chat model when one is configured (`DigestWriter`), with the template otherwise. `reuse` is an
    /// earlier digest of the day: while its facts still hold, its summary is kept and the model isn't asked again —
    /// unless it's the template and there's a model now to try.
    public func dayDigest(day: String, reuse: DayDigest? = nil) async throws -> DayDigest {
        tick()
        guard let start = ledger.startOfDay(named: day) else { throw BudgetAPIError.decoding("day must be a date like 2026-09-28, got “\(day)”") }
        let facts = ledger.dayDigest(day, from: start)
        if let reuse, reuse.sameFacts(as: facts), reuse.writtenBy != nil || chatModel == nil { return reuse }
        guard let chatModel else { return facts }
        return await DigestWriter(model: chatModel).write(facts)
    }

    public func savingsPlan() async throws -> SavingsPlan {
        tick(); await pause(0.5)
        let c = ledger.capacity()
        let g = ledger.guidance()
        let f = ledger.flexBudget()
        return SavingsPlan(monthsAveraged: c.months, averageIncome: c.income, canSaveTypical: c.typical, canSaveStretch: c.stretch,
                           alreadySaving: c.alreadySaving, plannedSavings: f.plannedSavings, plannedSavingsIsSet: f.plannedSavingsIsSet,
                           essentialMonthly: c.essentialMonthly, cashOnHand: c.cashOnHand, monthsCovered: c.emergencyMonths,
                           emergencyTargetLow: g.threeMonths, emergencyTargetHigh: g.sixMonths, twentyPercentOfIncome: g.twentyPercent,
                           history: ledger.cashFlowHistory(months: 6), averageCashChange: ledger.averageCashChange)
    }

    public func assistantConfig() async throws -> AssistantConfig {
        tick()
        return AssistantConfig(promptVersion: AssistantPrompt.version, systemPrompt: AssistantPrompt.system(ledger.assistantContext),
                               tools: ToolCatalog.definitions(for: ledger.activeCategories))
    }

    // MARK: Ingest (server)

    // MARK: - [lane L] ingest flagging
    /// Adds a source snapshot to the ledger: accounts upserted, rows deduplicated and tagged with
    /// `batchID`, then categorized (rules → merchant memory → decision model → review).
    public func ingest(_ snapshot: SourceSnapshot, batchID: String, into targetAccountID: String? = nil) async throws -> IngestReport {
        tick()
        // Categorizing is worked out on a copy. Asking a model takes a while and other writes (a confirm on the phone, a
        // file import) go on meanwhile, so the ledger itself isn't touched until the answers are back. The rows used to be
        // added first, and a model error then left them in memory unsaved: a replay skipped them as known and moved the
        // cursor past them.
        var working = ledger
        var report = try working.prepareIngest(snapshot, batchID: batchID, into: targetAccountID)
        let (model, jev, warnings) = resolvedModels()
        report.warnings += warnings
        let asked = working
        let outcome = await Categorizer.categorize(newRowIDs: report.newRowIDs, in: asked, model: model, escalation: jev)
        working.apply(outcome)
        let retry = outcome.modelUnreachable ? nil : await categorizeAwaiting(in: working, model: model, escalation: jev)

        // Then it's written in one step with no suspension before the save: the rows are added to the ledger as it is now,
        // and answers are kept only for rows nobody changed while the model was asked.
        let written = try await write {
            var written = try ledger.prepareIngest(snapshot, batchID: batchID, into: targetAccountID)
            let kept = outcome.unchanged(since: asked, in: ledger)
            ledger.apply(kept)
            written.warnings = report.warnings
            written.record(kept)
            if let retry {
                let kept = retry.outcome.unchanged(since: retry.asked, in: ledger)
                ledger.apply(kept)
                let asked = Set(retry.ids)
                let settled = kept.categorizations.filter { asked.contains($0.key) }
                let filed = settled.values.filter { !$0.needsReview }.count
                let changed = asked.count - settled.count
                if retry.outcome.modelUnreachable {
                    written.warnings.append("Still couldn't reach the decision model for \(asked.count) transaction\(asked.count == 1 ? "" : "s") waiting from an earlier sync; they're asked again in \(Int(Self.awaitingPause / 60)) minutes.")
                } else {
                    written.notes = (written.notes ?? []) + ["Asked again about \(asked.count) transaction\(asked.count == 1 ? "" : "s") an earlier sync couldn't file: \(filed) filed, \(settled.count - filed) waiting for you\(changed > 0 ? ", \(changed) changed meanwhile" : "")."]
                }
            }
            return written
        }
        await recordBalances(from: snapshot, into: targetAccountID)
        return written
    }
    // MARK: - [end lane L] ingest flagging

    /// At most this many waiting rows are asked about again per ingest.
    static let awaitingLimit = 200
    /// After a re-ask can't reach the model, re-asks pause this long, so each link's sync doesn't send the backlog again.
    static let awaitingPause: TimeInterval = 15 * 60
    private var awaitingPausedUntil: Date?
    /// Set while a re-ask is out, so an overlapping ingest (a sync and a file import) doesn't send the same rows again.
    private var awaitingInFlight = false

    /// Asks again about rows an earlier sync couldn't file (`Ledger.awaitingModel`), on the copy `working`. With no model
    /// configured they go through rules and memory and then become ordinary review rows, so they stop being re-asked.
    private func categorizeAwaiting(in working: Ledger, model: (any DecisionModel)?, escalation: (any DecisionModel)?) async
        -> (outcome: Categorizer.Outcome, asked: Ledger, ids: [String])? {
        if awaitingInFlight { return nil }
        if let until = awaitingPausedUntil, Date() < until { return nil }
        // Rows still waiting now (another sync may have filed some since this one started), and unchanged in `working`.
        let live = Set(ledger.awaitingModel)
        let ids = Array(working.awaitingModel.filter { live.contains($0) }.prefix(Self.awaitingLimit))
        guard !ids.isEmpty else { return nil }
        awaitingInFlight = true
        defer { awaitingInFlight = false }
        let outcome = await Categorizer.categorize(newRowIDs: ids, in: working, model: model, escalation: escalation)
        awaitingPausedUntil = outcome.modelUnreachable ? Date().addingTimeInterval(Self.awaitingPause) : nil
        return (outcome, working, ids)
    }

    /// What `ingest` would do — rows added, duplicates skipped (with samples), the dates covered — worked
    /// out on a copy of the ledger. Nothing is saved and no model is asked.
    public func previewIngest(_ snapshot: SourceSnapshot, into targetAccountID: String? = nil) throws -> IngestReport {
        try previewIngest([(snapshot, targetAccountID)])[0]
    }

    /// Several files previewed in order on one copy, so rows two files share count once — as they
    /// would when imported one after another.
    public func previewIngest(_ files: [(snapshot: SourceSnapshot, into: String?)]) throws -> [IngestReport] {
        tick()
        var copy = ledger
        return try files.enumerated().map { index, file in try copy.prepareIngest(file.snapshot, batchID: "preview-\(index)", into: file.into) }
    }

    // MARK: - [lane L] importDuplicates
    /// Imported rows a synced row also has. With `apply`, the imported copies are removed (the synced
    /// rows stay); without, it only lists them.
    public func importDuplicates(apply: Bool) async throws -> DuplicateSweep {
        tick()
        let pairs = ledger.crossSourceDuplicates()
        let listed = pairs.map { DuplicateSweep.Pair(accountID: $0.file.accountID, amount: $0.file.amount, fileDate: $0.file.postedAt,
                                                      fileDescription: $0.file.rawDescription, syncedDate: $0.synced.postedAt,
                                                      syncedDescription: $0.synced.rawDescription, syncedSource: $0.synced.source) }
        guard apply, !pairs.isEmpty else { return DuplicateSweep(applied: false, pairs: listed, removed: 0) }
        let removed = try await write { ledger.removeDuplicates(ledger.crossSourceDuplicates()) }
        return DuplicateSweep(applied: true, pairs: listed, removed: removed)
    }
    // MARK: - [end lane L] importDuplicates

    /// Removes rows the provider deleted (Plaid `removed`), by provider row id.
    @discardableResult
    public func removeSourceRows(_ source: SourceKind, externalIDs: [String]) async throws -> Int {
        guard !externalIDs.isEmpty else { return 0 }
        tick()
        return try await write { ledger.removeRows(Set(externalIDs.map { "\(source.rawValue):\($0)" })) }
    }

    public func stats() -> LedgerStats {
        let rows = ledger.transactions
        return LedgerStats(
            accounts: ledger.accounts.count, rows: rows.count, pending: rows.filter(\.isPending).count,
            needsReview: rows.filter(ledger.isWaitingForReview).count,
            earliest: rows.map(\.postedAt).min(), latest: rows.map(\.postedAt).max(),
            byTier: Dictionary(grouping: rows, by: { $0.categorization?.tier.rawValue ?? "none" }).mapValues(\.count),
            bySource: Dictionary(grouping: rows, by: { $0.source.rawValue }).mapValues(\.count),
            rememberedMerchants: ledger.merchantMemory(excluding: []).count, rules: ledger.rules.count,
            targets: ledger.monthlyTargets.count, merchantCaps: ledger.merchantTargets.count)
    }

    /// Swaps state in without writing it back — for loading what persistence already holds.
    public func replaceStateWithoutPersisting(_ state: LedgerState) {
        ledger = Ledger(state: state, now: clock?() ?? ledger.now, calendar: ledger.calendar)
    }

    /// Writes back what loading `loaded` filled in (transfer pairs found for older matched transfers, categories
    /// added to the defaults), once, so later diffs start from it. Nothing is written when loading changed nothing.
    public func persistUpgrades(from loaded: LedgerState) async throws {
        guard let persistence else { return }
        let upgraded = ledger.state
        // Row order isn't part of what's stored, so rows compare by id.
        func rows(_ state: LedgerState) -> [String: LedgerTransaction] {
            Dictionary(state.transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        var (a, b) = (upgraded, loaded)
        (a.transactions, b.transactions) = ([], [])
        guard a != b || rows(upgraded) != rows(loaded) else { return }
        try await persistence.save(from: loaded, to: upgraded)
    }

    /// Replaces the whole ledger (admin reset / seed). Persisted like any other change.
    public func replaceState(_ state: LedgerState) async throws {
        try await write { ledger = Ledger(state: state, now: clock?() ?? ledger.now, calendar: ledger.calendar) }
    }

    // MARK: - [lane L] rollback
    /// Removes every row a batch added and re-anchors the affected accounts. Returns the rows removed. The plan
    /// (`rollbackPlan`) is worked out inside the same write, so no sync slips in between: a batch it refuses (Plaid's)
    /// is a 409 and changes nothing, and one whose rows partly come back (`nextWindowStart`, the next sync's window) is
    /// a 409 until `acknowledgeReturning`.
    @discardableResult
    public func rollback(batchID: String, nextWindowStart: Date? = nil, acknowledgeReturning: Bool = false) async throws -> Int {
        tick()
        return try await write {
            let plan = ledger.rollbackPlan(batchID: batchID, nextWindowStart: nextWindowStart)
            if plan.verdict == .refuse || (plan.verdict == .undoReturns && !acknowledgeReturning) {
                throw BudgetAPIError.server(status: 409, message: plan.message)
            }
            return ledger.rollback(batchID: batchID)
        }
    }
    // MARK: - [end lane L] rollback

    // MARK: Decisions over the review queue

    /// Exactly what a decision model receives for one real uncertain row.
    private func decisionSample() -> String? {
        guard let row = ledger.transactions.first(where: { $0.merchant == "Venmo" }) ?? ledger.reviewItems.first?.transaction ?? ledger.transactions.first else { return nil }
        let request = CategoryDecisions.request(for: row, categories: ledger.activeCategories)
        return (try? JSONValue.parse(Data(request.state.utf8)).data(pretty: true)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The configured decision model and escalation, with a warning for anything the policy asks for that
    /// the server doesn't have (a sync keeps going with what's available).
    private func resolvedModels() -> (model: (any DecisionModel)?, escalation: (any DecisionModel)?, warnings: [String]) {
        let policy = ledger.decisionPolicy
        guard policy.isActive else { return (nil, nil, []) }
        var warnings: [String] = []
        let model = (try? decisions.model(for: policy.provider)) ?? nil
        if model == nil { warnings.append("\(policy.provider.displayName) isn't set up on the server, so new transactions went to review.") }
        var escalation: (any DecisionModel)?
        if policy.provider.runsLocally, policy.escalateToJev {
            escalation = (try? decisions.model(for: .jev)) ?? nil
            if escalation == nil { warnings.append("“Ask Jev when unsure” is on, but Jev isn't set up (no OpenRouter key), so only the local model decided.") }
        }
        return (model, escalation, warnings)
    }

    private func availableProviders() -> [DecisionProvider] {
        DecisionProvider.allCases.filter { $0 == .off || ((try? decisions.model(for: $0)) ?? nil) != nil }
    }

    /// What `recheckModelFiled` did.
    public struct RecheckResult: Codable, Sendable {
        public struct Move: Codable, Sendable {
            public var merchant: String
            public var from: String
            public var to: String
            public var transactions: Int
            public var confidence: Double?
        }
        /// False for a preview: the moves are listed but nothing changed.
        public var applied: Bool
        public var moves: [Move]
        public var merchants: Int
        public var movedMerchants: Int
        public var movedTransactions: Int
        public var modelMilliseconds: Int
        public var message: String
    }

    /// Re-decides what the model filed — never the person's confirmations or rules — under the current
    /// categories and prompt, one question per merchant. A merchant moves only when the new answer clears
    /// the bar (or agrees with the bank's category); unsure answers leave it where it is.
    public func recheckModelFiled(apply: Bool = true) async throws -> RecheckResult {
        tick()
        // What the model is asked about is this copy; after it answers, only rows still as they were here are moved.
        let asked = ledger
        let (resolved, _, warnings) = resolvedModels()
        guard let model = resolved else { throw BudgetAPIError.rejected(warnings.first ?? "The decision model is off.") }
        let policy = ledger.decisionPolicy
        let known = Set(ledger.activeCategories.map(\.id))
        let byDescriptor = Dictionary(grouping: ledger.transactions, by: ledger.decisionKey)
        let groups = byDescriptor.filter { _, rows in
            // Only merchants the person never weighed in on and the bank data didn't settle, and nothing waiting
            // for review (re-check handles those).
            rows.allSatisfy { row in
                guard let c = row.categorization else { return false }
                return !c.needsReview && !c.tier.isSettledByPersonOrData
            }
        }
        guard !groups.isEmpty else { return RecheckResult(applied: apply, moves: [], merchants: 0, movedMerchants: 0, movedTransactions: 0, modelMilliseconds: 0, message: "Nothing the model filed to re-check.") }
        let keys = Array(groups.keys)
        let requests = keys.map { let row = groups[$0]![0]
            return CategoryDecisions.request(for: row, categories: ledger.activeCategories, accountKind: ledger.accountKind(row.accountID)) }
        var timing = Categorizer.Outcome()
        let responses = try await Categorizer.timed(&timing) { try await model.decide(requests) }
        var movedMerchants = 0, movedRows = 0
        var moves: [RecheckResult.Move] = []
        var planned: [(ids: [String], to: Categorization)] = []
        for (key, response) in zip(keys, responses) {
            let rows = groups[key]!
            // Money going out is never re-filed as money in, nor money coming in on a card as Income (a group is one
            // direction, and card money in is its own group).
            let answer = Categorizer.guarded(response.answers[CategoryDecisions.questionID], for: rows[0], in: ledger).answer
            let pick: String?
            switch CategoryDecisions.outcome(answer, policy: policy, knownCategoryIDs: known) {
            case let .accept(categoryID, _): pick = categoryID
            case .review: pick = Categorizer.agreement(answer, bankCategory: rows[0].providerCategory, known: known)
            }
            guard let pick, rows.contains(where: { $0.categorization?.categoryID != pick }) else { continue }
            movedMerchants += 1
            let from = rows.compactMap { $0.categorization?.categoryID }.first ?? "none"
            moves.append(.init(merchant: rows[0].merchant, from: from, to: pick, transactions: rows.count, confidence: answer?.confidence))
            movedRows += rows.count
            planned.append((rows.map(\.id), Categorization(categoryID: pick, confidence: answer?.confidence ?? Categorizer.agreementFloor,
                                                           tier: .decisionModel, needsReview: false, decidedBy: "\(model.label) · re-checked")))
        }
        if apply {
            // Only rows still as they were when the model was asked move; anything the person changed meanwhile stays.
            (movedMerchants, movedRows) = try await write {
                let untouched = ledger.unchanged(planned.flatMap(\.ids), since: asked)
                var merchants = 0, rows = 0
                for plan in planned {
                    let ids = Set(plan.ids).intersection(untouched)
                    for index in ledger.transactions.indices where ids.contains(ledger.transactions[index].id) {
                        ledger.transactions[index].categorization = plan.to
                        rows += 1
                    }
                    if !ids.isEmpty { merchants += 1 }
                }
                return (merchants, rows)
            }
        }
        let seconds = String(format: "%.1f", Double(timing.modelMilliseconds) / 1000)
        moves.sort { $0.transactions > $1.transactions }
        return RecheckResult(applied: apply, moves: moves, merchants: keys.count, movedMerchants: movedMerchants, movedTransactions: movedRows, modelMilliseconds: timing.modelMilliseconds,
                             message: movedMerchants == 0 ? "Re-checked \(keys.count) merchants; everything stays where it is (\(seconds) s)."
                                 : apply ? "Re-checked \(keys.count) merchants and moved \(movedMerchants) (\(movedRows) transactions) in \(seconds) s."
                                         : "Would move \(movedMerchants) of \(keys.count) merchants (\(movedRows) transactions). Nothing has changed yet.")
    }

    /// Re-decides the review queue: one question per merchant and direction (as at ingest), escalation for the
    /// unsure ones, the bank-agreement rule, and every row of a merchant gets its merchant's answer.
    /// Asks about the ledger as it was when the re-run started, and then, with no suspension before the save, writes
    /// answers only to rows nobody filed or changed meanwhile.
    private func runDecisionsOnReviewQueue() async throws -> (Int, Int, Int) {
        let asked = ledger
        let items = ledger.reviewItems
        guard !items.isEmpty else { return (0, 0, 0) }
        let policy = ledger.decisionPolicy
        let (resolved, jev, _) = resolvedModels()
        guard let model = resolved else { return (0, items.count, 0) }
        let known = Set(ledger.activeCategories.map(\.id))
        let groups = Dictionary(grouping: items) { ledger.decisionKey($0.transaction) }
        let keys = Array(groups.keys)
        let requests = keys.map { let row = groups[$0]![0].transaction
            return CategoryDecisions.request(for: row, categories: ledger.activeCategories, accountKind: ledger.accountKind(row.accountID)) }
        var timing = Categorizer.Outcome()
        let responses = try await Categorizer.timed(&timing) { try await model.decide(requests) }
        var answers: [String: (answer: DecisionAnswer?, label: String)] = [:]
        // Merchants the model refused on their own are left as they are.
        let refused = Set(zip(keys, responses).filter { $0.1.failure != nil }.map(\.0))
        for (key, response) in zip(keys, responses) where response.failure == nil { answers[key] = (response.answers[CategoryDecisions.questionID], model.label) }

        // Escalation: re-ask Jev about what the local model wasn't sure of; keep Jev's answer only if it clears the bar.
        if let jev {
            let unsure = keys.indices.filter { !refused.contains(keys[$0]) && (answers[keys[$0]]?.answer?.confidence ?? 0) < policy.threshold }
            if !unsure.isEmpty {
                do {
                    let second = try await Categorizer.timed(&timing) { try await jev.decide(unsure.map { requests[$0] }) }
                    escalationNote = "Asked Jev about \(unsure.count) unsure merchant\(unsure.count == 1 ? "" : "s")."
                    for (index, response) in zip(unsure, second) {
                        if let answer = response.answers[CategoryDecisions.questionID], (answer.confidence ?? 0) >= policy.threshold {
                            answers[keys[index]] = (answer, "\(jev.label) · escalated")
                            escalatedAccepts += 1
                        }
                    }
                } catch {
                    escalationNote = "Couldn't reach Jev (\(error.localizedDescription)); kept the local answers."
                }
            }
        }
        var perRow: [(transactionID: String, answer: DecisionAnswer?, label: String)] = []
        var agreed: [String: String] = [:]
        for (key, members) in groups where !refused.contains(key) {
            let decided = answers[key]
            for item in members {
                perRow.append((item.id, decided?.answer, decided?.label ?? model.label))
                if case .review = CategoryDecisions.outcome(decided?.answer, policy: policy, knownCategoryIDs: known),
                   let pick = Categorizer.agreement(decided?.answer, bankCategory: item.transaction.providerCategory, known: known) {
                    agreed[item.id] = pick
                }
            }
        }
        let outcome = try await write {
            let keep = ledger.unchanged(perRow.map(\.transactionID), since: asked)
            return ledger.applyDecisions(perRow.filter { keep.contains($0.transactionID) }, agreed: agreed.filter { keep.contains($0.key) })
        }
        let refusedRows = groups.filter { refused.contains($0.key) }.values.reduce(0) { $0 + $1.count }
        return (outcome.accepted, outcome.pending + refusedRows, timing.modelMilliseconds)
    }
}
