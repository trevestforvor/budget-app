import BudgetKit
import Foundation
import Logging

/// Once a day per Plaid Item: `/item/get` (errors, consent dates, billed products), the webhook URL, holdings when due.
/// Not built yet: nothing runs.
public actor PlaidMaintenance {
    let api: LedgerBudgetAPI
    let store: any ServerStore
    let sync: SyncService
    let providers: Providers
    let sealer: TokenSealer?
    let settings: ServerSettings
    let logger: Logger
    let clock: @Sendable () -> Date

    public init(api: LedgerBudgetAPI, store: any ServerStore, sync: SyncService, providers: Providers, sealer: TokenSealer?, settings: ServerSettings,
                logger: Logger, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api; self.store = store; self.sync = sync; self.providers = providers; self.sealer = sealer; self.settings = settings
        self.logger = logger; self.clock = clock
    }

    public func runScheduler() async {}

    /// Checks one Item now (a webhook said something changed).
    public func checkItem(_ linkID: String) async {}
}
