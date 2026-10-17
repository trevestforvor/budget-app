import BudgetKit
import DesignSystem
import SafariServices
import SwiftUI

/// Signing in at a provider's own site in an in-app browser, then trying the link again: one bank behind a SimpleFIN
/// link that needs a sign-in. The page opens only on SimpleFIN Bridge (`InstitutionLink.providerSiteURL`); a row with
/// any other address shows nothing, so a tampered answer can't open some other page inside the app.
struct ProviderSiteRepairButton: View {
    let link: InstitutionLink
    @Environment(AppModel.self) private var app
    @State private var browsing: BrowserPage?
    /// The person came back from the bridge: "Try again" is the next step.
    @State private var returned = false
    @State private var isRetrying = false
    @State private var outcome: String?

    var body: some View {
        if let url = link.providerSiteURL {
            DSCard {
                VStack(alignment: .leading, spacing: DSSpace.md) {
                    Text("\(link.institution) needs you to sign in again on SimpleFIN Bridge. Nothing new comes in from \(link.institution) until then; your other banks keep syncing.")
                        .dsFont(.callout)
                        .foregroundStyle(Color.ds.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let outcome {
                        Text(outcome)
                            .dsFont(.caption)
                            .foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Sign in on SimpleFIN Bridge") { browsing = BrowserPage(url: url) }
                        .buttonStyle(.ds(returned ? .secondary : .tinted, fullWidth: true))
                        .accessibilityHint("Opens SimpleFIN Bridge in Budget")
                    if returned, app.api is any LinkRetryAPI {
                        Button("Try again") { Task { await retry() } }
                            .buttonStyle(.ds(.tinted, fullWidth: true, isLoading: isRetrying))
                            .disabled(isRetrying)
                            .accessibilityHint("Asks the server to sync \(link.institution) now")
                    }
                }
            }
            .settingsCardRow()
            .sheet(item: $browsing, onDismiss: { returned = true }) { InAppBrowser(url: $0.url).ignoresSafeArea() }
        }
    }

    /// Syncs the whole link the bank belongs to; it counts against SimpleFIN's daily requests, like any sync.
    private func retry() async {
        guard let api = app.api as? any LinkRetryAPI else { return }
        isRetrying = true
        defer { isRetrying = false }
        do {
            let result = try await api.syncLink(id: link.retryLinkID)
            outcome = result.ok ? (result.skipped ?? "Synced. If \(link.institution) still needs a sign-in, SimpleFIN hasn't seen it yet; try again in a few minutes.")
                                : (result.error ?? "The sync didn't go through.")
            await app.didWrite()
        } catch {
            outcome = error.localizedDescription
        }
    }
}

/// A page to show in `InAppBrowser`, for `.sheet(item:)`.
struct BrowserPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// `SFSafariViewController`: the provider's page in Budget, with Safari's own address bar, so the person sees where
/// they're signing in. Budget never sees what's typed there.
struct InAppBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
