import BudgetKit
import DesignSystem
import SwiftUI

/// How fresh one account is, under its row: "Balance as of Oct 16", and a tag when it's behind ("Stale since Oct 14",
/// "Waiting for sign-in", "Statement overdue"). Nothing from a server before 0.6.0, which sends neither.
struct AccountHealthLabel: View {
    let account: Account
    let health: AccountHealth?

    var body: some View {
        let tag = Self.tag(health)
        let asOf = Self.asOf(account: account, health: health)
        if tag != nil || asOf != nil {
            HStack(spacing: DSSpace.xs) {
                if let tag { DSTag(tag.text, systemImage: tag.symbol, tint: tag.tint) }
                if let asOf {
                    Text(asOf).dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, DSSpace.sm)
            .accessibilityElement(children: .combine)
        }
    }

    /// "Balance as of Oct 16", from the bank's own date for it. None for a statement account: its import stamps the
    /// day it ran, not the statement's.
    static func asOf(account: Account, health: AccountHealth?) -> String? {
        guard account.source != .fileImport else { return nil }
        return (health?.balanceAsOf ?? account.balanceAsOf).map { "Balance as of \($0.formatted(.dateTime.month(.abbreviated).day()))" }
    }

    static func tag(_ health: AccountHealth?) -> (text: String, symbol: String, tint: Color)? {
        switch health?.state {
        case .stale:
            let since = health?.staleSince.map { " since \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
            return ("Stale\(since)", "clock", Color.ds.caution)
        case .waitingForSignIn: return ("Waiting for sign-in", "person.crop.circle.badge.exclamationmark", Color.ds.caution)
        case .statementsOverdue: return ("Statement overdue", "doc.text", Color.ds.amber)
        case .current, .notSynced, nil: return nil
        }
    }
}

/// A link's last few syncs, as a "Recent syncs" disclosure in its section: when, and what came in or why it didn't.
/// Nothing when the server sends none (before 0.6.0, or a link from statements).
struct LinkHealthSection: View {
    let link: InstitutionLink

    var body: some View {
        if let syncs = link.recentSyncs, !syncs.isEmpty {
            DisclosureGroup {
                ForEach(Array(syncs.prefix(5).enumerated()), id: \.offset) { _, sync in
                    HStack(alignment: .firstTextBaseline, spacing: DSSpace.sm) {
                        Image(systemName: sync.ok ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(sync.ok ? Color.ds.accent : Color.ds.caution)
                            .accessibilityHidden(true)
                        Text(sync.at.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            .dsFont(.callout).foregroundStyle(Color.ds.inkSoft)
                        Spacer(minLength: DSSpace.sm)
                        Text(Self.outcome(sync)).dsFont(.callout).foregroundStyle(sync.ok ? Color.ds.inkSecondary : Color.ds.caution)
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(.vertical, DSSpace.xs)
                    .accessibilityElement(children: .combine)
                }
            } label: {
                Text("Recent syncs").dsFont(.body).foregroundStyle(Color.ds.ink)
            }
            .tint(Color.ds.inkSecondary)
            .frame(minHeight: DSSize.listRow)
        }
    }

    /// "+12", "Nothing new", or the plain reason by kind.
    static func outcome(_ sync: SyncOutcome) -> String {
        if sync.ok { return sync.rowsAdded > 0 ? "+\(sync.rowsAdded)" : "Nothing new" }
        switch sync.kind {
        case .needsSignIn: return "Bank needs sign-in"
        case .revoked: return "Access was withdrawn"
        case .providerSetup: return "Server's provider setup needs fixing"
        case .rateLimited: return "Rate limited; tries again later"
        case .transient, nil: return "Couldn't reach the bank"
        }
    }
}

/// The line under Linked accounts.
enum AccountsFooter {
    static func text(status: ServerStatus) -> String {
        var parts = ["Investment balances count toward what you're worth, never as cash to spend."]
        if ServerStatus.version(status.version, isAtLeast: ServerStatus.connectionsSince) {
            parts.append("Accounts not heard from in \(Int(syncStaleDays)) days are marked stale; statement accounts after \(Int(statementDays)) days.")
        }
        parts.append("Link banks and import statements on your Budget dashboard.")
        return parts.joined(separator: " ")
    }

    /// The server's thresholds (`Ledger.syncStaleAfterDays`, `statementStaleAfterDays`), for the copy.
    static let syncStaleDays = 2.0
    static let statementDays = 40.0
}
