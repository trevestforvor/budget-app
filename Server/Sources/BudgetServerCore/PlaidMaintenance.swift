import BudgetKit
import Foundation
import Logging

/// Once a day per Plaid Item: `/item/get` (errors, consent dates, billed products), the webhook URL, holdings when due.
///
/// `/item/get` is Plaid's ground truth for an Item: its current error (over a stale webhook or an old sync failure),
/// what Plaid bills it for, and when the bank's consent runs out. Once a day isn't polling for data: transactions come
/// from webhooks and the sync schedule. It's the reconcile that catches what a missed webhook would have said, and the
/// only place the consent date comes from.
///
/// Every check runs in the Item's turn (`SyncService.updateLink`), so it never overlaps a sync of the same Item, and the
/// Plaid calls for one Item go one at a time.
public actor PlaidMaintenance {
    let api: LedgerBudgetAPI
    let store: any ServerStore
    let sync: SyncService
    let providers: Providers
    let sealer: TokenSealer?
    let settings: ServerSettings
    let logger: Logger
    let clock: @Sendable () -> Date
    /// Holdings for one Item: `HoldingsSync.refresh`, or a stand-in in tests.
    let holdings: HoldingsRefresh

    /// `enabled`, the Item's source, its last holdings check, whether a webhook marked it due, its institution, now.
    typealias HoldingsRefresh = @Sendable (Bool, PlaidSource, HoldingsCheck?, Bool, String, Date) async -> HoldingsCheck?

    /// How often the scheduler looks for Items due a check.
    static let tick: TimeInterval = 15 * 60
    /// An Item is checked again this long after its last check, give or take `jitter`.
    static let checkEvery: TimeInterval = 24 * 3600
    static let jitter: TimeInterval = 3600
    /// Holdings are asked again this long after the last time, so a daily check that comes round an hour early still asks.
    static let holdingsEvery: TimeInterval = 20 * 3600
    /// Where Plaid sends this server's webhooks, after the public URL.
    static let webhookPath = "/v1/plaid/webhook"

    public init(api: LedgerBudgetAPI, store: any ServerStore, sync: SyncService, providers: Providers, sealer: TokenSealer?, settings: ServerSettings,
                logger: Logger, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(api: api, store: store, sync: sync, providers: providers, sealer: sealer, settings: settings, logger: logger, clock: clock, holdings: nil)
    }

    init(api: LedgerBudgetAPI, store: any ServerStore, sync: SyncService, providers: Providers, sealer: TokenSealer?, settings: ServerSettings,
         logger: Logger, clock: @escaping @Sendable () -> Date, holdings: HoldingsRefresh?) {
        self.api = api; self.store = store; self.sync = sync; self.providers = providers; self.sealer = sealer; self.settings = settings
        self.logger = logger; self.clock = clock
        self.holdings = holdings ?? { enabled, source, previous, webhookDue, institution, now in
            await HoldingsSync.refresh(enabled: enabled, source: source, previous: previous, requestedByPerson: false, webhookDue: webhookDue,
                                       api: api, now: now, institution: institution, logger: logger)
        }
    }

    /// What one check did.
    enum Outcome: Sendable, Equatable {
        /// `/item/get` answered (an Item Plaid no longer has counts: it's settled).
        case checked
        /// It answered with no error on a link that was waiting for a sign-in: the link is connected again.
        case healed
        /// `/item/get` failed; the next day's check tries again.
        case failed
        /// Not asked: not due, no live Item, Plaid not set up, or a token that won't open (the sync reports those).
        case skipped
    }

    /// Looks every 15 minutes for Items due their daily check, for the life of the process. The first look comes a
    /// minute after start, so the server settles first; `lastItemCheckAt` is stored, so a restart doesn't check again.
    public func runScheduler() async {
        var wait: TimeInterval = 60
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(wait))
            await checkDueItems()
            wait = Self.tick
        }
    }

    /// Checks each Item whose last check is a day old, one at a time. Returns how many were asked.
    @discardableResult
    func checkDueItems() async -> Int {
        let now = clock()
        // Without Plaid keys or the token key no check can ask, and the sync already says why: don't take each Item's
        // turn (a store read and write) every 15 minutes just to skip it.
        guard sealer != nil, (try? await providers.plaid()) != nil else { return 0 }
        var asked = 0
        for link in (try? await store.links()) ?? [] where Self.isDue(link, now: now) {
            if await check(link.id, force: false) != .skipped { asked += 1 }
        }
        if asked > 0 { await sync.publishInstitutions() }
        return asked
    }

    /// Checks one Item now (a webhook said something changed). It takes the Item's turn itself: never call it from inside
    /// `SyncService.updateLink`, `serialized` or a sync (the queue isn't re-entrant, and that waits forever). A webhook
    /// queue calls it after its own turn.
    public func checkItem(_ linkID: String) async {
        await checkItem(linkID, syncIfHealed: true)
    }

    /// The same, saying what the check did. With `syncIfHealed` false a link it heals gets no sync from here: the caller
    /// (the webhook queue, which spaces its syncs) runs that one itself.
    @discardableResult
    func checkItem(_ linkID: String, syncIfHealed: Bool) async -> Outcome {
        let outcome = await check(linkID, force: true, syncIfHealed: syncIfHealed)
        if outcome != .skipped { await sync.publishInstitutions() }
        return outcome
    }

    /// One check, in the Item's turn. A link it heals gets one sync, queued after the check (never inside it: the queue
    /// isn't re-entrant), unless the caller syncs it itself.
    @discardableResult
    func check(_ linkID: String, force: Bool, syncIfHealed: Bool = true) async -> Outcome {
        let outcome: Outcome
        do {
            outcome = try await sync.updateLink(linkID) { link in await self.inspect(&link, force: force) }
        } catch {
            logger.error("item check for link \(linkID) didn't run: \(error)")
            return .skipped
        }
        if outcome == .healed, syncIfHealed { await sync.requestSync(linkID: linkID, trigger: .webhook("LOGIN_REPAIRED")) }
        return outcome
    }

    /// Whether `link` is due its daily check: a live Plaid Item never checked, or last checked a day ago. The day varies
    /// by an hour either way, the same for a given check, so Items linked together spread out instead of asking at once.
    static func isDue(_ link: StoredLink, now: Date) -> Bool {
        guard link.hasLiveItem else { return false }
        guard let last = link.plaid?.lastItemCheckAt else { return true }
        return now.timeIntervalSince(last) >= checkEvery + jitter(link.id, last)
    }

    /// Between −1 h and +1 h, fixed for one link and one last check.
    static func jitter(_ linkID: String, _ last: Date) -> TimeInterval {
        let hash = StableHash.fnv1a64("\(linkID)|\(Int(last.timeIntervalSince1970))")
        return (Double(hash % 2001) / 1000 - 1) * jitter
    }

    /// The check itself, on the stored link. Due is asked again here: a check that ran while this one waited its turn
    /// already counts.
    nonisolated func inspect(_ link: inout StoredLink, force: Bool) async -> Outcome {
        let now = clock()
        guard link.hasLiveItem, force || Self.isDue(link, now: now) else { return .skipped }
        guard let plaid = try? await providers.plaid(), let sealer else { return .skipped }
        var state = link.plaid ?? PlaidLinkState()
        // Stamped whatever the answer: a failed check waits for the next day too (a webhook can ask sooner). So does a token
        // that won't open (the sync reports that), rather than being tried every 15 minutes.
        state.lastItemCheckAt = now
        link.plaid = state
        guard let token = try? sealer.open(link.sealedToken) else { return .skipped }
        let source = PlaidSource(environment: plaid.environment, credentials: .init(clientID: plaid.clientID, secret: plaid.secret),
                                 accessToken: token, institution: link.institution, transport: providers.transport)

        let item: PlaidSource.Item
        do {
            item = try await source.item()
        } catch {
            let plaidError = PlaidErrors.plaidError(error)
            if plaidError?.errorCode == "ITEM_NOT_FOUND" {
                // Unrecoverable: the Item is gone at Plaid. Drop the token, keep the link with its accounts and rows; never
                // /item/remove it. Linking the bank again is the only way back.
                link.sealedToken = ""
                LinkHealthBook.recordFailure(&link, LinkFailure(kind: .revoked, code: "ITEM_NOT_FOUND", requestID: plaidError?.requestID,
                                                                message: SyncService.itemGoneMessage(link)), now: now)
                logger.warning("Plaid no longer has the Item for \(link.institution) (request_id \(plaidError?.requestID ?? "none")); its token is dropped, its rows kept")
                return .checked
            }
            logger.error("item check for \(link.institution) failed: code \(plaidError?.errorCode ?? "none"), request_id \(plaidError?.requestID ?? "none")")
            return .failed
        }

        state.institutionID = item.institutionID ?? state.institutionID
        state.consentExpiresAt = item.consentExpiresAt
        state.billedProducts = item.billedProducts
        state.availableProducts = item.availableProducts
        if let updated = item.transactionsUpdatedAt { state.lastTransactionsUpdate = max(updated, state.lastTransactionsUpdate ?? updated) }
        if Self.pendingDisconnectIsOver(state, item: item, now: now) { state.pendingDisconnectAt = nil }
        link.plaid = state

        var outcome = Outcome.checked
        if let error = item.error {
            let kind = PlaidErrors.kind(type: error.errorType, code: error.errorCode)
            // Only what waits for the person changes the link: an Item error the bank may clear by itself (it's down, a
            // product isn't ready) is left for the next sync to find, rather than holding syncs back on its say.
            let code = error.errorCode ?? error.errorType
            if kind == .needsSignIn || kind == .revoked, link.errorKind != kind || link.errorCode != code || link.status != .needsReauth {
                // The check isn't a sync attempt: it leaves a webhook its three sign-in tries (they count refused syncs).
                let signInTries = link.plaid?.signInFailures
                LinkHealthBook.recordFailure(&link, LinkFailure(kind: kind, code: code, requestID: item.requestID ?? error.requestID,
                                                                message: SyncService.describe(error)), now: now)
                link.plaid?.signInFailures = signInTries
            }
            logger.warning("item check for \(link.institution): \(kind.rawValue), code \(code ?? "none"), request_id \(item.requestID ?? "none")")
        } else if LinkHealthBook.waitsForPerson(link) {
            // Plaid says the Item is fine (signed in again elsewhere, or LOGIN_REPAIRED): clear the prompts and sync.
            LinkHealthBook.recordRepaired(&link)
            // Signing in again (update mode) is also what a PENDING_DISCONNECT asked for, consent date or not.
            link.plaid?.pendingDisconnectAt = nil
            outcome = .healed
            logger.info("item check for \(link.institution): healthy again (request_id \(item.requestID ?? "none")); a sync is queued")
        }

        await reconcileWebhook(&link, item: item, source: source, sandbox: plaid.environment == .sandbox)

        if item.error?.endsItemAccess != true, Self.holdingsDue(link.holdings, now: now) {
            let mode = await settings.holdingsMode
            // `auto`: only an Item Plaid already bills for Investments, so holdings never start a new charge on their own.
            let enabled = mode == .on || (mode == .auto && item.billedProducts.contains("investments"))
            link.holdings = await holdings(enabled, source, link.holdings, link.holdings?.due ?? false, link.institution, now)
        }
        return outcome
    }

    /// Points the Item's webhooks at this server when they go elsewhere (an Item linked before webhooks, or a public URL
    /// that changed). Only to an https public URL (http only for a sandbox test server), compared without a trailing
    /// slash. Plaid confirms with WEBHOOK_UPDATE_ACKNOWLEDGED. A failure is logged and tried again the next day.
    nonisolated func reconcileWebhook(_ link: inout StoredLink, item: PlaidSource.Item, source: PlaidSource, sandbox: Bool) async {
        guard let wanted = await Self.webhookURL(settings, sandbox: sandbox) else { return }
        if item.webhook.map(ServerConfig.withoutTrailingSlash) == wanted {
            // Already Plaid's (sent when the Item was linked): just note it.
            if link.plaid?.webhookURL != wanted { link.plaid?.webhookURL = wanted }
            return
        }
        do {
            let requestID = try await source.updateWebhook(wanted)
            link.plaid?.webhookURL = wanted
            link.plaid?.webhookAcknowledgedAt = nil
            logger.info("webhook URL registered for \(link.institution) (request_id \(requestID ?? "none"))")
        } catch {
            let plaidError = PlaidErrors.plaidError(error)
            logger.error("webhook URL update for \(link.institution) failed: code \(plaidError?.errorCode ?? "none"), request_id \(plaidError?.requestID ?? "none")")
        }
    }

    /// Whether holdings are asked this check: never asked, a webhook marked them due, or the last ask is most of a day old.
    static func holdingsDue(_ previous: HoldingsCheck?, now: Date) -> Bool {
        guard let previous else { return true }
        return previous.due == true || now.timeIntervalSince(previous.checkedAt) >= holdingsEvery
    }

    /// A PENDING_DISCONNECT warning is over once the Item is healthy and either its consent now runs a month past the
    /// warning (it was renewed) or the warning is a month old. While Plaid reports an error, it stays.
    static func pendingDisconnectIsOver(_ state: PlaidLinkState, item: PlaidSource.Item, now: Date) -> Bool {
        guard let warned = state.pendingDisconnectAt, item.error == nil else { return false }
        let month: TimeInterval = 30 * 86_400
        if let expires = item.consentExpiresAt, expires > warned.addingTimeInterval(month) { return true }
        return now.timeIntervalSince(warned) > month
    }
}
