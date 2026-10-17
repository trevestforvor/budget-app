import AuthenticationServices
import BudgetKit
import DesignSystem
import SwiftUI

/// What Linked accounts shows above the list for connections that need the person: each one the phone can repair
/// with its own button ("Sign in again", "Renew access"), a notice that sends the rest to the dashboard, and SimpleFIN's
/// own sign-in where a link says so.
struct LinkRepairControls: View {
    /// The links waiting for a sign-in, in the order the list shows them.
    let links: [InstitutionLink]
    /// Links still working whose consent runs out soon (`InstitutionLink.consentEndsSoon`).
    var expiring: [InstitutionLink] = []
    let status: ServerStatus
    /// The server is 0.6.0 or newer and the API can start a reconnect (`LinkRepairAPI`).
    var canRepair = false
    /// Starts the reconnect flow for a link the phone can repair.
    var repair: (InstitutionLink) -> Void = { _ in }
    @Environment(\.openURL) private var openURL

    var body: some View {
        let onPhone = links.filter(phoneRepairs)
        let elsewhere = links.filter { !phoneRepairs($0) }
        ForEach(onPhone) { link in
            DSNoticeCard("\(link.institution) needs you to sign in again",
                         message: "The bank ended the connection, so nothing new is coming in. Sign in again here — your accounts and history stay as they are.",
                         actionTitle: "Sign in again") { repair(link) }
                .settingsCardRow()
        }
        if !elsewhere.isEmpty {
            DSNoticeCard(elsewhere.count == 1 ? "\(elsewhere[0].institution) needs you to sign in again"
                                              : "\(elsewhere.count) connections need you to sign in again",
                         message: elsewhere.allSatisfy { $0.reconnect == .newLink }
                            ? "Access was withdrawn, so nothing new is coming in. Link \(elsewhere.count == 1 ? "it" : "them") again on your Budget dashboard — your accounts and history stay."
                            : "The bank ended the connection, so nothing new is coming in. Reconnect on your Budget dashboard — it keeps your accounts and history.",
                         actionTitle: dashboardURL == nil ? nil : "Open dashboard") { if let dashboardURL { openURL(dashboardURL) } }
                .settingsCardRow()
        }
        ForEach(links.filter { $0.reconnect == .providerSite }) { ProviderSiteRepairButton(link: $0) }
        ForEach(expiring) { link in
            let ends = link.consentExpiresAt.map { $0 > .now ? "ends \($0.formatted(.dateTime.month(.abbreviated).day()))" : "has ended" } ?? "ends soon"
            if phoneRepairs(link) {
                DSNoticeCard("\(link.institution) access \(ends)", message: "Banks ask you to renew access now and then. Renew it now and new transactions keep coming in.",
                             systemImage: "clock.badge.exclamationmark", tint: Color.ds.amber, actionTitle: "Renew access") { repair(link) }
                    .settingsCardRow()
            } else {
                DSNoticeCard("\(link.institution) access \(ends)", message: "Banks ask you to renew access now and then. Reconnect it on your Budget dashboard before then.",
                             systemImage: "clock.badge.exclamationmark", tint: Color.ds.amber,
                             actionTitle: dashboardURL == nil ? nil : "Open dashboard") { if let dashboardURL { openURL(dashboardURL) } }
                    .settingsCardRow()
            }
        }
    }

    private func phoneRepairs(_ link: InstitutionLink) -> Bool { canRepair && link.reconnect == .phone }

    private var dashboardURL: URL? { status.dashboardURL.flatMap(URL.init(string:)) }
}

extension InstitutionLink {
    /// Still working, but the bank's consent runs out within two weeks (or already has): time to renew access.
    func consentEndsSoon(now: Date = .now) -> Bool {
        guard !needsSignIn, let ends = consentExpiresAt else { return false }
        return ends.timeIntervalSince(now) <= 14 * 86_400
    }
}

/// Signing in to a bank again from the phone: the server starts a Plaid Hosted Link session in update mode, the
/// person finishes it in an in-app browser, and the phone asks the server how it went. The browser's return only
/// says the page closed; the server's `/item/get` check says whether the bank is back.
struct ReconnectSheet: View {
    let link: InstitutionLink
    let api: any LinkRepairAPI
    let dashboardURL: URL?
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var browser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var step: Step = .starting
    /// Bumped by "Try again", which starts a fresh session.
    @State private var attempt = 0

    /// The scheme Hosted Link finishes on (`completion_redirect_uri`), when the server doesn't name one.
    nonisolated static let callbackScheme = "budgetapp-plaid"
    /// Seconds between checks after the browser closes: about half a minute in all, then "still checking".
    static let backoff: [Double] = [1, 2, 4, 8, 8, 8]

    enum Step: Equatable {
        case starting, signingIn, checking
        case done(LinkSyncResult?)
        /// Half a minute passed without an answer; the banner clears when the server sees the fix.
        case stillChecking
        case exited(String)
        case expired
        /// `setup`: the server can't do this from the phone, so the dashboard is the way.
        case failed(String, setup: Bool)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    DSGlyph(systemImage: glyph.name, tone: glyph.tone, size: 56)
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Text(title)
                            .dsFont(.title)
                            .foregroundStyle(Color.ds.ink)
                            .accessibilityIdentifier("reconnectTitle")
                        Text(message)
                            .dsFont(.callout)
                            .foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if working { ProgressView().frame(maxWidth: .infinity) }
                    actions
                }
                .padding(DSSpace.gutter)
            }
            .dsScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
        .interactiveDismissDisabled(step == .signingIn)
        .task(id: attempt) { await run() }
        // A sync may still land after "still checking": the screens behind reload either way.
        .onDisappear { if step == .stillChecking { Task { await app.didWrite() } } }
    }

    @ViewBuilder
    private var actions: some View {
        switch step {
        case .done:
            Button("Done") { dismiss() }
                .buttonStyle(.ds(.primary, fullWidth: true))
                .accessibilityIdentifier("reconnectDone")
        case .stillChecking:
            Button("OK") { dismiss() }.buttonStyle(.ds(.primary, fullWidth: true))
        case .exited, .expired, .failed(_, setup: false):
            Button("Try again") { attempt += 1 }.buttonStyle(.ds(.primary, fullWidth: true))
        case .failed(_, setup: true):
            if let dashboardURL {
                Button("Open dashboard") { openURL(dashboardURL); dismiss() }.buttonStyle(.ds(.primary, fullWidth: true))
            }
        case .starting, .signingIn, .checking:
            EmptyView()
        }
    }

    private var working: Bool { [.starting, .signingIn, .checking].contains(step) }

    private var title: String {
        switch step {
        case .starting: "Opening \(link.institution)…"
        case .signingIn: "Signing in to \(link.institution)"
        case .checking: "Checking with \(link.institution)…"
        case .done: "\(link.institution) is connected again"
        case .stillChecking: "Still checking"
        case .exited: "Not signed in"
        case .expired: "That sign-in page expired"
        case .failed: "Couldn't sign in from here"
        }
    }

    private var message: String {
        switch step {
        case .starting: "Getting a secure sign-in page from Plaid."
        case .signingIn: "Finish in the window that opened. Your bank login goes to Plaid and your bank, never to Budget."
        case .checking: "Making sure the bank is sending transactions again."
        case let .done(result):
            if let result, !result.ok {
                "You're signed in. The first sync didn't finish (\(result.error ?? "no reason given")); the server tries again on its schedule."
            } else if let added = result?.report?.rowsAdded, added > 0 {
                "It's syncing again — \(added) new transaction\(added == 1 ? "" : "s") came in."
            } else {
                "It's syncing again, and your accounts and history are as they were."
            }
        case .stillChecking: "The server hasn't heard back from \(link.institution) yet. We'll let you know — this notice clears once it does."
        case let .exited(reason): reason
        case .expired: "Sign-in pages last 15 minutes. Start again for a fresh one."
        case let .failed(reason, _): reason
        }
    }

    private var glyph: (name: String, tone: DSTone) {
        switch step {
        case .done: ("checkmark.circle", .teal)
        case .exited, .expired, .failed: ("exclamationmark.circle", .amber)
        default: ("building.columns", .iris)
        }
    }

    // MARK: The flow

    private func run() async {
        step = .starting
        let session: ReconnectSession
        do {
            session = try await api.startReconnect(linkID: link.id)
        } catch {
            step = Self.failure(error, institution: link.institution)
            return
        }
        guard session.state == .waiting else { return show(session) }
        guard let raw = session.url, let url = URL(string: raw), url.scheme == "https" else {
            step = .failed("The server didn't send a sign-in page. Reconnect \(link.institution) on your Budget dashboard.", setup: true)
            return
        }
        step = .signingIn
        var closed = false
        do {
            try await signIn(url, scheme: session.callbackScheme?.nilIfEmpty ?? Self.callbackScheme)
        } catch {
            // Closed before the page finished (or the browser couldn't open): the person may still have finished, so
            // the server is asked once.
            closed = true
        }
        guard !Task.isCancelled else { return }
        step = .checking
        await poll(session.id, closed: closed)
    }

    /// The hosted page in an in-app browser, until it returns on `scheme`. Ephemeral: no "wants to sign in" alert, and
    /// no bank cookies left in Safari.
    private func signIn(_ url: URL, scheme: String) async throws {
        #if targetEnvironment(simulator)
        // UI tests: the stub's page doesn't exist, so the browser "returns" at once.
        if ReconnectStub.isOn { return }
        #endif
        _ = try await browser.authenticate(using: url, callback: .customScheme(scheme), preferredBrowserSession: .ephemeral,
                                           additionalHeaderFields: [:])
    }

    /// Asks the server about the session with growing gaps until it settles, for about half a minute. After the browser
    /// was closed early, one answer that's still `waiting` means the person didn't finish.
    private func poll(_ session: String, closed: Bool) async {
        for delay in Self.backoff {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            let latest: ReconnectSession
            do {
                latest = try await api.reconnectStatus(linkID: link.id, session: session)
            } catch BudgetAPIError.notFound {
                step = .failed("The server lost track of this sign-in (it may have restarted). Start again.", setup: false)
                return
            } catch {
                continue
            }
            if latest.state == .waiting, closed {
                step = .exited("You closed the sign-in before it finished, so nothing changed.")
                return
            }
            if latest.state != .waiting, latest.state != .syncing { return show(latest) }
        }
        step = .stillChecking
    }

    /// A settled session on screen; a finished one refreshes the app.
    private func show(_ session: ReconnectSession) {
        switch session.state {
        case .done:
            step = .done(session.result)
            Task { await app.didWrite() }
        case .exited: step = .exited(session.message ?? "You left the sign-in before it finished, so nothing changed.")
        case .expired: step = .expired
        case .failed: step = .failed(session.message ?? "Plaid couldn't finish signing in to \(link.institution). Try again in a moment.", setup: false)
        case .waiting, .syncing: step = .stillChecking
        }
    }

    /// The server's refusal in its own words. A setup problem (or a link only the dashboard can repair) points there.
    static func failure(_ error: any Error, institution: String) -> Step {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if case .rejected = error as? BudgetAPIError { return .failed(message, setup: true) }
        if case .notFound = error as? BudgetAPIError {
            return .failed("Your server can't sign in to banks again from the phone yet. Update it, or reconnect \(institution) on your Budget dashboard.", setup: true)
        }
        return .failed(message, setup: false)
    }
}

#if targetEnvironment(simulator)
/// `-reconnectStub` (simulator only, for UI tests): the demo ledger stands in for a 0.6.0 server whose Plaid links the
/// phone can repair. The links waiting for a sign-in say `.phone`, a working one's access ends in nine days, and a
/// reconnect goes waiting → syncing → done without a browser, after which the link reads as connected.
actor ReconnectStub: LinkRepairAPI {
    static let shared = ReconnectStub()
    static let isOn = ProcessInfo.processInfo.arguments.contains("-reconnectStub")
    private var healed: Set<String> = []
    private var polls = 0

    func startReconnect(linkID: String) async throws -> ReconnectSession {
        polls = 0
        return ReconnectSession(id: "stub-session", linkID: linkID, institution: linkID, state: .waiting, url: "https://example.invalid/hl",
                                callbackScheme: ReconnectSheet.callbackScheme, expiresAt: .now.addingTimeInterval(900))
    }

    func reconnectStatus(linkID: String, session: String) async throws -> ReconnectSession {
        polls += 1
        guard polls > 1 else {
            return ReconnectSession(id: session, linkID: linkID, institution: linkID, state: .syncing, expiresAt: .now.addingTimeInterval(900))
        }
        healed.insert(linkID)
        var report = IngestReport(batchID: "stub", source: .plaid)
        report.rowsAdded = 3
        return ReconnectSession(id: session, linkID: linkID, institution: linkID, state: .done, expiresAt: .now.addingTimeInterval(900),
                                result: LinkSyncResult(linkID: linkID, institution: linkID, ok: true, report: report))
    }

    /// The demo's links as a 0.6.0 server with phone reconnect would send them.
    func decorate(_ status: ServerStatus) -> ServerStatus {
        var status = status
        var expiringSet = false
        for i in status.institutions.indices where !status.institutions[i].fromStatements {
            let id = status.institutions[i].id
            if healed.contains(id) {
                status.institutions[i].status = .connected
                status.institutions[i].lastError = nil
                status.institutions[i].errorKind = nil
                status.institutions[i].consentExpiresAt = nil
            } else if status.institutions[i].status == .needsReauth {
                status.institutions[i].errorKind = .needsSignIn
            } else if !expiringSet, status.institutions[i].status == .connected || status.institutions[i].status == .demo {
                status.institutions[i].consentExpiresAt = .now.addingTimeInterval(9 * 86_400)
                expiringSet = true
            }
            status.institutions[i].reconnect = .phone
        }
        return status
    }
}
#endif
