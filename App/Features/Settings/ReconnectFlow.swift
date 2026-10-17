import BudgetKit
import DesignSystem
import SwiftUI

/// What Linked accounts shows for connections waiting for a sign-in: for now the notice that sends the person to the
/// dashboard, and SimpleFIN's own sign-in where a link says so. Signing in again from the phone comes later.
struct LinkRepairControls: View {
    /// The links waiting for a sign-in, in the order the list shows them.
    let links: [InstitutionLink]
    let status: ServerStatus
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !links.isEmpty {
            DSNoticeCard(links.count == 1 ? "\(links[0].institution) needs you to sign in again"
                                          : "\(links.count) connections need you to sign in again",
                         message: "The bank ended the connection, so nothing new is coming in. Reconnect on your Budget dashboard — it keeps your accounts and history.",
                         actionTitle: dashboardURL == nil ? nil : "Open dashboard") { if let dashboardURL { openURL(dashboardURL) } }
                .settingsCardRow()
            ForEach(links.filter { $0.reconnect == .providerSite }) { ProviderSiteRepairButton(link: $0) }
        }
    }

    private var dashboardURL: URL? { status.dashboardURL.flatMap(URL.init(string:)) }
}
