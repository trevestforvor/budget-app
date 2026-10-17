import BudgetKit
import DesignSystem
import SwiftUI

/// How fresh one account is, under its row. Nothing yet.
struct AccountHealthLabel: View {
    let account: Account
    let health: AccountHealth?

    var body: some View { EmptyView() }
}

/// A link's recent syncs, as a row of its section. Nothing yet.
struct LinkHealthSection: View {
    let link: InstitutionLink

    var body: some View { EmptyView() }
}

/// The line under Linked accounts.
enum AccountsFooter {
    static func text(status: ServerStatus) -> String {
        "Investment balances count toward what you're worth, never as cash to spend. Link banks and import statements on your Budget dashboard."
    }
}
