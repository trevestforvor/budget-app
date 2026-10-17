import BudgetKit
import Foundation
import Logging

/// Signing in to a bank again from the phone: Hosted Link sessions in Plaid's update mode, in memory only (a link token
/// is never stored). Not built yet.
public actor ReconnectSessions {
    let store: any ServerStore
    let sync: SyncService
    let providers: Providers
    let sealer: TokenSealer?
    let settings: ServerSettings
    let logger: Logger
    let clock: @Sendable () -> Date

    public init(store: any ServerStore, sync: SyncService, providers: Providers, sealer: TokenSealer?, settings: ServerSettings, logger: Logger,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.sync = sync; self.providers = providers; self.sealer = sealer; self.settings = settings
        self.logger = logger; self.clock = clock
    }

    /// A LINK/SESSION_FINISHED webhook for the Link session whose token hashes to `linkTokenHash` (SHA-256, lowercase
    /// hex): a reconnect waiting on it can look sooner than its next poll. The webhook's tokens are never passed in.
    /// Sessions aren't built yet, so nothing is waiting.
    func check(linkTokenHash: String) async {}
}
