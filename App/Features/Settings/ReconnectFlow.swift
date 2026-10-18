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
        // A SimpleFIN bank is signed in to again on SimpleFIN Bridge (its own button below), never on the dashboard.
        let elsewhere = links.filter { !phoneRepairs($0) && $0.reconnect != .providerSite }
        ForEach(onPhone) { link in
            DSNoticeCard("\(link.institution) needs you to sign in again",
                         message: "The bank ended the connection, so nothing new is coming in. Sign in again here — your accounts and history stay as they are.",
                         actionTitle: "Sign in again") { repair(link) }
                .settingsCardRow()
        }
        if !elsewhere.isEmpty {
            DSNoticeCard(elsewhere.count == 1 ? "\(elsewhere[0].institution) needs you to sign in again"
                                              : "\(elsewhere.count) connections need you to sign in again",
                         message: onDashboard(InstitutionLink.repairElsewhereMessage(elsewhere)),
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
                DSNoticeCard("\(link.institution) access \(ends)", message: onDashboard("Banks ask you to renew access now and then. Reconnect it on your Budget dashboard before then."),
                             systemImage: "clock.badge.exclamationmark", tint: Color.ds.amber,
                             actionTitle: dashboardURL == nil ? nil : "Open dashboard") { if let dashboardURL { openURL(dashboardURL) } }
                    .settingsCardRow()
            }
        }
    }

    private func phoneRepairs(_ link: InstitutionLink) -> Bool { canRepair && link.reconnect == .phone }

    /// A notice that sends the person to the dashboard, with where to find it when the server hasn't said and there's
    /// no "Open dashboard" to tap.
    private func onDashboard(_ message: String) -> String {
        dashboardURL == nil ? message + " " + DashboardDirections.text : message
    }

    private var dashboardURL: URL? { status.dashboardURL.flatMap(URL.init(string:)) }
}

extension InstitutionLink {
    /// A SimpleFIN link SimpleFIN stopped accepting as a whole: a new setup token on the dashboard fixes it.
    var needsNewSetupToken: Bool { primary == .simplefin && reconnect == .dashboard }

    /// What to say about connections the phone can't repair itself, by how each one is fixed.
    static func repairElsewhereMessage(_ links: [InstitutionLink]) -> String {
        let them = links.count == 1 ? "it" : "them"
        if links.allSatisfy({ $0.reconnect == .providerSite }) {
            return "Nothing new is coming in from \(them). Sign in again on SimpleFIN Bridge, then tap Try again — your accounts and history stay as they are."
        }
        if links.allSatisfy(\.needsNewSetupToken) {
            return "SimpleFIN stopped accepting this server's access, so nothing new is coming in. Paste a new setup token on your Budget dashboard — your accounts and history stay."
        }
        if links.allSatisfy({ $0.reconnect == .newLink }) {
            return "Access was withdrawn, so nothing new is coming in. Link \(them) again on your Budget dashboard — your accounts and history stay."
        }
        return "The bank ended the connection, so nothing new is coming in. Reconnect on your Budget dashboard — it keeps your accounts and history."
    }

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
    /// The session the browser is open for, so a return through the universal link can ask about it.
    @State private var sessionID: String?
    @State private var browserWait = BrowserWait()

    /// The scheme Hosted Link finishes on (`completion_redirect_uri`), when the server doesn't name one.
    nonisolated static let callbackScheme = "budgetapp-plaid"
    /// Seconds between checks after the browser closes: about half a minute in all, then "still checking".
    static let backoff: [Double] = [1, 2, 4, 8, 8, 8]
    /// After the browser was closed early, how long the phone keeps asking before it says nothing changed. The server
    /// asks Plaid at most every 5 s (`ReconnectSessions`), so a shorter wait can miss a sign-in that did finish.
    static let closedGrace: Double = 6

    enum Step: Equatable {
        case starting, signingIn, checking
        case done(LinkSyncResult?)
        /// Half a minute passed without an answer; the banner clears when the server sees the fix.
        case stillChecking
        case exited(String)
        case expired
        /// `setup`: the server can't do this from the phone, so the dashboard is the way.
        case failed(String, setup: Bool)
        /// The server has no such link any more (removed on the dashboard, say).
        case gone
        /// The server's own limit on how often a sign-in starts (429): trying again now would be refused too.
        case tooSoon(String)
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
        // The bank's own app handed the phone back through the universal link: ask the server now, in case the hosted
        // page doesn't carry on by itself.
        .onChange(of: ReconnectReturn.shared.count) { if step == .signingIn, let sessionID { Task { await checkAfterReturn(sessionID) } } }
        // A sync may still land after the sheet goes (swiped away mid-check, "still checking", a closed browser that
        // did finish): the screens behind reload either way. A finished one has already refreshed.
        .onDisappear {
            if case .done = step { return }
            if step != .starting { Task { await app.didWrite() } }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch step {
        case .done:
            Button("Done") { dismiss() }
                .buttonStyle(.ds(.primary, fullWidth: true))
                .accessibilityIdentifier("reconnectDone")
        case .stillChecking, .gone, .tooSoon:
            Button("OK") { dismiss() }.buttonStyle(.ds(.primary, fullWidth: true))
        case .exited, .expired, .failed(_, setup: false):
            Button("Try again") { attempt += 1 }.buttonStyle(.ds(.primary, fullWidth: true))
        case .failed(_, setup: true):
            if let dashboardURL {
                Button("Open dashboard") { openURL(dashboardURL); dismiss() }.buttonStyle(.ds(.primary, fullWidth: true))
            } else {
                Text(DashboardDirections.text)
                    .dsFont(.callout)
                    .foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("reconnectDashboardDirections")
                Button("OK") { dismiss() }.buttonStyle(.ds(.primary, fullWidth: true))
            }
        case .starting, .signingIn, .checking:
            EmptyView()
        }
    }

    private var working: Bool { [.starting, .signingIn, .checking].contains(step) }

    /// Renewing a link that still works, rather than signing in to one the bank ended.
    private var renewing: Bool { !link.needsSignIn }

    private var title: String {
        switch step {
        case .starting: "Opening \(link.institution)…"
        case .signingIn: renewing ? "Renewing \(link.institution)" : "Signing in to \(link.institution)"
        case .checking: "Checking with \(link.institution)…"
        case .done: renewing ? "\(link.institution) access renewed" : "\(link.institution) is connected again"
        case .stillChecking: "Still checking"
        case .exited: renewing ? "Not renewed" : "Not signed in"
        case .expired: "That sign-in page expired"
        case .failed: renewing ? "Couldn't renew from here" : "Couldn't sign in from here"
        case .gone: "\(link.institution) isn't linked any more"
        case .tooSoon: "Try again later"
        }
    }

    private var message: String {
        switch step {
        case .starting: "Getting a secure sign-in page from Plaid."
        case .signingIn: "Finish in the window that opened. Your bank login goes to Plaid and your bank, never to Budget."
        case .checking: renewing ? "Making sure the bank renewed access." : "Making sure the bank is sending transactions again."
        case let .done(result):
            if let result, !result.ok {
                "You're signed in. The first sync didn't finish (\(result.error ?? "no reason given")); the server tries again on its schedule."
            } else if let added = result?.report?.rowsAdded, added > 0 {
                "It's syncing again — \(added) new transaction\(added == 1 ? "" : "s") came in."
            } else if renewing {
                "It keeps syncing as before, and your accounts and history are as they were."
            } else {
                "It's syncing again, and your accounts and history are as they were."
            }
        case .stillChecking: "The server hasn't heard back from \(link.institution) yet. We'll let you know — this notice clears once it does."
        case let .exited(reason): reason
        case .expired: "Sign-in pages last 15 minutes. Start again for a fresh one."
        case let .failed(reason, _): reason
        case .gone: "It was removed on your Budget dashboard, so there's nothing to sign in to. Linked accounts shows what's linked now."
        case let .tooSoon(reason): reason
        }
    }

    private var glyph: (name: String, tone: DSTone) {
        switch step {
        case .done: ("checkmark.circle", .teal)
        case .exited, .expired, .failed, .gone, .tooSoon: ("exclamationmark.circle", .amber)
        default: ("building.columns", .iris)
        }
    }

    // MARK: The flow

    private func run() async {
        step = .starting
        sessionID = nil
        let session: ReconnectSession
        do {
            session = try await api.startReconnect(linkID: link.id)
        } catch {
            step = Self.failure(error, institution: link.institution)
            // A link removed elsewhere: the list behind drops it.
            if step == .gone { await app.didWrite() }
            return
        }
        guard session.state == .waiting else { return show(session) }
        guard let raw = session.url, let url = URL(string: raw), url.scheme == "https" else {
            step = .failed("The server didn't send a sign-in page. Reconnect \(link.institution) on your Budget dashboard.", setup: true)
            return
        }
        step = .signingIn
        sessionID = session.id
        let scheme = session.callbackScheme?.nilIfEmpty ?? Self.callbackScheme
        // Closed before the page finished (or the browser couldn't open): the person may still have finished, so the
        // server is asked before anything is said.
        let end = await browserWait.run { try await signIn(url, scheme: scheme) }
        guard !Task.isCancelled else { return }
        step = .checking
        await poll(session.id, closed: end == .closed)
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

    /// After the universal link brought the phone back with the browser still up: a few quick checks, and once the server
    /// sees the sign-in finished, the browser's wait ends so the sheet carries on instead of sitting on a stuck page.
    private func checkAfterReturn(_ session: String) async {
        for delay in [1.0, 2, 4, 8] {
            try? await Task.sleep(for: .seconds(delay))
            guard browserWait.isWaiting, sessionID == session else { return }
            guard let latest = try? await api.reconnectStatus(linkID: link.id, session: session) else { continue }
            if latest.state != .waiting {
                browserWait.finish(.serverMovedOn)
                return
            }
        }
    }

    /// Asks the server about the session with growing gaps until it settles, for about half a minute. After the browser
    /// was closed early, an answer that's still `waiting` once `closedGrace` has passed (time for the server to have
    /// asked Plaid) means the person most likely didn't finish.
    private func poll(_ session: String, closed: Bool) async {
        var waited = 0.0
        for delay in Self.backoff {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            waited += delay
            let latest: ReconnectSession
            do {
                latest = try await api.reconnectStatus(linkID: link.id, session: session)
            } catch BudgetAPIError.notFound {
                step = .failed("The server lost track of this sign-in (it may have restarted). Start again.", setup: false)
                return
            } catch {
                continue
            }
            if latest.state == .waiting, closed, waited >= Self.closedGrace {
                step = .exited("You closed the sign-in before it finished, so nothing changed. If you did finish, \(link.institution) catches up here shortly.")
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
    /// The sheet only opens on a 0.6.0 server (`ServerStatus.connectionsSince`), so a 404 means the link is gone, not
    /// that the route is missing; a 429 is the server's own limit, which "Try again" would only hit again.
    static func failure(_ error: any Error, institution: String) -> Step {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        switch error as? BudgetAPIError {
        case .rejected?: return .failed(message, setup: true)
        case .notFound?: return .gone
        case let .server(status, text)? where status == 429:
            return .tooSoon(text ?? "Signing in to \(institution) again was started too many times. Try again in an hour.")
        default: return .failed(message, setup: false)
        }
    }
}

/// How the in-app browser's wait ended.
enum BrowserEnd: Equatable {
    /// The hosted page finished and came back on the callback scheme.
    case returned
    /// The person closed it (or it couldn't open, or the sheet went away).
    case closed
    /// The server saw the sign-in finish while the page was still up (after a bank app's return).
    case serverMovedOn
}

/// The browser's wait, which a universal-link return can end early: `run` resolves on the first of the page coming back,
/// the person closing it, or `finish(.serverMovedOn)`. Ending early cancels the browser's task, which closes the
/// authentication session.
@MainActor final class BrowserWait {
    private var continuation: CheckedContinuation<BrowserEnd, Never>?
    private var browser: Task<Void, Never>?
    /// Which `run` is current, so a browser task cancelled by an earlier one can't end a later wait.
    private var generation = 0
    /// An end that came before `run` was waiting (the sheet cancelled at once).
    private var early: BrowserEnd?

    var isWaiting: Bool { continuation != nil }

    func run(_ open: @escaping @MainActor () async throws -> Void) async -> BrowserEnd {
        generation += 1
        let mine = generation
        early = nil
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<BrowserEnd, Never>) in
                if let early {
                    self.early = nil
                    continuation.resume(returning: early)
                    return
                }
                self.continuation = continuation
                browser = Task { @MainActor in
                    do {
                        try await open()
                        self.finish(.returned, of: mine)
                    } catch {
                        self.finish(.closed, of: mine)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.closed, of: mine) }
        }
    }

    /// Ends the current wait (`of` nil) or the one `of` names, if it's still current.
    func finish(_ end: BrowserEnd, of run: Int? = nil) {
        if let run, run != generation { return }
        guard let continuation else {
            early = end
            return
        }
        self.continuation = nil
        if end != .returned { browser?.cancel() }
        browser = nil
        continuation.resume(returning: end)
    }
}

/// The universal link a bank's own app returns the phone on (`/plaid/oauth-return`, the server's default
/// `PLAID_MOBILE_REDIRECT_URI`). Home hands each arrival here; an open `ReconnectSheet` then asks the server at once.
@MainActor @Observable final class ReconnectReturn {
    static let shared = ReconnectReturn()
    private(set) var count = 0

    /// Counts `url` when it's the OAuth return; anything else is left alone.
    func note(_ url: URL?) {
        guard let url, url.path.hasPrefix("/plaid/oauth-return") else { return }
        count += 1
    }
}

extension Bundle {
    /// The API host the app was built with Associated Domains for (`BUDGET_API_HOST`), or nil when it was built
    /// without: then a bank's own app can't hand the phone back to Budget, so reconnecting stays on the dashboard.
    /// Nil in a free-team build too, which can't sign Associated Domains even when a host is set.
    var appLinksHost: String? {
        guard !isFreeTeamBuild, let host = object(forInfoDictionaryKey: "BudgetAPIHost") as? String,
              !host.isEmpty, !host.hasPrefix("$(") else { return nil }
        return host
    }

    /// Built for a free Personal Team (`BUDGET_FREE_TEAM = YES`, App/BudgetFree.entitlements): no push and no
    /// Associated Domains, so the morning summary, pace alerts and reconnecting from the phone can't work.
    /// `-freeTeam` stands in for it on the simulator, for UI tests.
    var isFreeTeamBuild: Bool {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-freeTeam") { return true }
        #endif
        return object(forInfoDictionaryKey: "BudgetFreeTeam") as? String == "YES"
    }
}

/// Where the dashboard is when the server hasn't said (`BUDGET_DASHBOARD_URL` unset, as on a Mac or Docker install):
/// on the computer that runs the server, which the phone can't open.
enum DashboardDirections {
    static let localAddress = "http://budget.localhost:8081"
    static let text = "Open the dashboard on the computer that runs your server, at \(localAddress)."
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
