import BudgetKit
import Foundation

extension SyncService {
    /// SimpleFIN: per-bank windows within a daily request budget (`SimpleFINSync`).
    func syncSimpleFIN(_ link: inout StoredLink, token: String, batchID: String, trigger: SyncTrigger) async throws -> ProviderSyncOutcome {
        guard let url = URL(string: token) else { throw BudgetAPIError.rejected("Stored SimpleFIN access URL is invalid.") }
        return try await SimpleFINSync.run(link: &link, url: url, trigger: trigger, batchID: batchID, api: api, transport: providers.transport,
                                           automaticPerDay: await settings.simplefinDailyPulls, timeZone: await settings.timeZone, logger: logger)
    }

    /// Swaps in the access a new setup token gives, for a link SimpleFIN stopped accepting, and syncs it. The link keeps
    /// its id, so its accounts and history carry on. Whether SimpleFIN keeps its account ids across tokens isn't known;
    /// when none of the old ones come back, `note` says so instead of letting the person find two of everything.
    public func replaceSimpleFINToken(linkID: String, setupToken: String) async throws -> (result: LinkSyncResult, note: String?) {
        guard let link = try await store.links().first(where: { $0.id == linkID }) else { throw BudgetAPIError.notFound }
        guard link.provider == .simplefin else {
            throw BudgetAPIError.rejected("Only SimpleFIN links take a new setup token; \(link.institution) connects through \(link.provider.displayName).")
        }
        guard let sealer else { throw BudgetAPIError.rejected("Set BUDGET_TOKEN_KEY on the server before linking accounts.") }
        // Claimed before the link is touched: a refused token changes nothing.
        let accessURL = try await SimpleFINSync.claim(setupToken, transport: providers.transport)
        let sealed = try sealer.seal(accessURL.absoluteString)
        let before = Set(link.simplefin?.connections.values.flatMap(\.accountIDs) ?? [])
        try await updateLink(linkID) { link in
            link.sealedToken = sealed
            // A new setup token is the repair: the failure run ends, so a later failure starts a new episode (and push).
            LinkHealthBook.recordRepaired(&link)
        }
        let result = try await sync(linkID: linkID, trigger: .reconnect)
        guard result.ok, !before.isEmpty else { return (result, nil) }
        let stored = try await store.links().first { $0.id == linkID }
        let after = Set(stored?.simplefin?.connections.values.flatMap(\.accountIDs) ?? [])
        guard !after.isEmpty, before.isDisjoint(with: after) else { return (result, nil) }
        // New ids came in as new banks: the sync already gave each its history from the fresh pull's start back two years
        // (`SimpleFINPlanner.newBankGap`), filled on the next scheduled runs. Nothing to reset here.
        return (result, "These accounts came in as new ones; your old ones keep their history.")
    }
}
