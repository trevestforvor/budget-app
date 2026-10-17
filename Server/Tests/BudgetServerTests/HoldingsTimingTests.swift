import BudgetKit
@testable import BudgetServerCore
import Foundation
import Logging
import Testing

/// When a holdings check asks Plaid, given how the daily Item check calls it (every 24 h, give or take an hour).
@Suite("Holdings checks: timing")
struct HoldingsTimingTests {
    @Test("A daily check that comes an hour early still asks; one the same evening doesn't")
    func earlyDailyCheckStillAsks() async throws {
        let service = try await HoldingsScript.service()
        let plaid = ScriptedProvider([HoldingsScript.path: [HoldingsScript.ok]])
        let now = Date()
        let last = HoldingsCheck(access: .ok, checkedAt: now.addingTimeInterval(-23 * 3600), accounts: 1, requestID: "req-earlier")
        let next = try #require(await HoldingsScript.refresh(service, plaid, previous: last, now: now))
        #expect(next.checkedAt == now && next.requestID == "req-hold-ok")
        #expect(plaid.count(HoldingsScript.path) == 1)
        let evening = HoldingsCheck(access: .ok, checkedAt: now.addingTimeInterval(-12 * 3600), accounts: 1)
        #expect(await HoldingsScript.refresh(service, plaid, previous: evening, now: now) == evening)
        #expect(plaid.count(HoldingsScript.path) == 1)
    }

    @Test("No investment accounts, then one appears: the next check asks Plaid at once")
    func investmentAccountAppearsAskedAtOnce() async throws {
        let plaid = ScriptedProvider([HoldingsScript.path: [HoldingsScript.ok]])
        // The first check came before the first sync (or before the person marked the account as an investment).
        let before = try await HoldingsScript.service([.checking])
        let none = try #require(await HoldingsScript.refresh(before, plaid, previous: nil))
        #expect(none.access == .noInvestmentAccounts && none.requestID == nil)
        // An hour later the ledger holds the brokerage.
        let after = try await HoldingsScript.service()
        let first = try #require(await HoldingsScript.refresh(after, plaid, previous: none, now: Date().addingTimeInterval(3600)))
        #expect(first.access == .ok && plaid.count(HoldingsScript.path) == 1)
        #expect(try await after.api.holdings().accounts.count == 1)
    }

    @Test("Plaid's own NO_INVESTMENT_ACCOUNTS waits for the next day like any other answer")
    func plaidsNoInvestmentAccountsWaits() async throws {
        let service = try await HoldingsScript.service()
        let plaid = ScriptedProvider([HoldingsScript.path: [HoldingsScript.error("NO_INVESTMENT_ACCOUNTS"), HoldingsScript.ok]])
        let said = try #require(await HoldingsScript.refresh(service, plaid, previous: nil))
        #expect(said.access == .noInvestmentAccounts && said.requestID != nil)
        #expect(await HoldingsScript.refresh(service, plaid, previous: said) == said)
        #expect(plaid.count(HoldingsScript.path) == 1)
    }

    @Test("A failure that isn't Plaid's logs only its status; the check keeps the provider's words")
    func failureLogNamesOnlyTheStatus() async throws {
        let service = try await HoldingsScript.service()
        let proxy = ScriptedProvider([HoldingsScript.path: [(502, "<html>Bad gateway for access-sandbox-echo</html>")]])
        let log = LinesLogHandler()
        let failed = try #require(await HoldingsScript.refresh(service, proxy, previous: nil, log: log))
        #expect(failed.access == .failed && failed.message?.contains("Bad gateway") == true)
        #expect(log.lines.contains { $0.contains("HTTP 502") })
        #expect(!log.lines.contains { $0.contains("Bad gateway") || $0.contains("access-sandbox") })
    }
}
