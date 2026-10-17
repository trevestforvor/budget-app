import BudgetKit
import DesignSystem
import SwiftUI

/// Settings → Linked accounts: each institution with its accounts and balances, how its data arrives and when it
/// last did, and what to do when a bank ends a connection. Linking and reconnecting happen on the dashboard.
struct AccountsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var state: LoadState<ServerStatus> = .loading
    @State private var accounts: [Account] = []
    /// Each account's freshness by id (`Overview.accountHealth`); empty from servers before 0.6.0.
    @State private var health: [String: AccountHealth] = [:]
    @State private var isSyncing = false
    @State private var toast: DSToastMessage?
    @State private var showsAdd = false

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingPlaceholder(text: "Reading your accounts…")
            case let .failed(message):
                DSStateView(systemImage: "wifi.slash", title: "Can't load accounts", message: message, actionTitle: "Try again") {
                    Task { await load() }
                }
            case let .loaded(status) where status.institutions.isEmpty && accounts.isEmpty:
                DSStateView(systemImage: "building.columns", title: "No accounts yet",
                            message: "Link a bank or import a statement on your Budget dashboard, and your accounts show up here.",
                            actionTitle: dashboardURL(status) == nil ? nil : "Open dashboard") { openDashboard(status) }
                    .frame(maxHeight: .infinity)
            case let .loaded(status):
                list(status)
            }
        }
        // Every state fills the page, so a loading or error state never sits in a band of another colour.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsScreenBackground()
        .navigationTitle("Linked accounts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await sync() } } label: {
                    if isSyncing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(isSyncing || state.value == nil)
                .accessibilityLabel(isSyncing ? "Syncing" : "Sync now")
                .accessibilityIdentifier("syncNow")
                Button { showsAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add an account")
            }
        }
        .task(id: app.revision) { await load() }
        .sheet(isPresented: $showsAdd) { AddAccountSheet(dashboardURL: state.value.flatMap(dashboardURL)) }
        .dsToast($toast)
    }

    private func list(_ status: ServerStatus) -> some View {
        let signIn = status.institutions.filter(\.needsSignIn)
        let ordered = signIn + status.institutions.filter { !$0.needsSignIn && !$0.fromStatements } + status.institutions.filter(\.fromStatements)
        let claimed = Set(ordered.flatMap { held(by: $0).map(\.id) })
        let unclaimed = accounts.filter { !claimed.contains($0.id) }
        return List {
            if !signIn.isEmpty {
                Section {
                    LinkRepairControls(links: signIn, status: status)
                }
            }
            ForEach(ordered) { link in
                DSListSection {
                    header(link)
                    let held = held(by: link)
                    if held.isEmpty {
                        SettingsNote(text: link.fromStatements ? "No statements imported yet." : "No accounts from it yet.")
                    }
                    ForEach(held) { accountRow($0) }
                    LinkHealthSection(link: link)
                }
            }
            // Accounts no connection claims (one whose bank was unlinked, say), still grouped by institution.
            ForEach(Dictionary(grouping: unclaimed, by: \.institution).sorted { $0.key < $1.key }, id: \.key) { group in
                DSListSection {
                    header(group.key, line: ("Not connected", Color.ds.inkTertiary), glyph: "building.columns", tone: .irisDeep, lastSync: nil)
                    ForEach(group.value) { accountRow($0) }
                }
            }
            Section {
                Text(AccountsFooter.text(status: status))
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DSSpace.sm)
                    .settingsCardRow()
            }
        }
        .dsGroupedList()
        .refreshable { await load() }
    }

    private func header(_ link: InstitutionLink) -> some View {
        header(link.institution, line: statusLine(link), glyph: link.fromStatements ? "doc.text" : "building.columns",
               tone: link.fromStatements ? .amber : .iris, lastSync: link.needsSignIn ? link.lastSync : nil)
    }

    private func header(_ institution: String, line: (text: String, tint: Color), glyph: String, tone: DSTone, lastSync: Date?) -> some View {
        HStack(alignment: .top, spacing: DSSpace.sm) {
            DSGlyph(systemImage: glyph, tone: tone)
            VStack(alignment: .leading, spacing: 4) {
                Text(institution).dsFont(.headline).foregroundStyle(Color.ds.ink)
                DSEyebrow(line.text, dot: line.tint)
                if let lastSync {
                    Text("Last updated \(lastSync.agoPhrase)").dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DSSpace.sm)
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func accountRow(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DSListRow(account.shortLabel, detail: account.kindLabel) {
                HStack(spacing: DSSpace.xs) {
                    DSAmountText(account.balance.decimal, currencyCode: account.balance.currencyCode)
                    AccountEditButton(account: account)
                }
            }
            AccountHealthLabel(account: account, health: health[account.id])
        }
    }

    /// "Updated 2 hours ago · via Plaid", "Sign in again · via Plaid", "From statements · through Sep 12".
    private func statusLine(_ link: InstitutionLink) -> (text: String, tint: Color) {
        if link.needsSignIn { return ("Sign in again · via \(link.sourceName)", Color.ds.caution) }
        if link.fromStatements {
            let through = link.coversThrough.map { " · through \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
            return ("From statements\(through)", Color.ds.inkTertiary)
        }
        if link.lastError != nil { return ("Last sync didn't finish · via \(link.sourceName)", Color.ds.amber) }
        guard let lastSync = link.lastSync else { return ("Not synced yet · via \(link.sourceName)", Color.ds.inkTertiary) }
        return ("Updated \(lastSync.agoPhrase) · via \(link.sourceName)", Color.ds.accent)
    }

    /// The institution's accounts: by id when the server says which, else by name (older servers).
    private func held(by link: InstitutionLink) -> [Account] {
        if let ids = link.accountIDs { return accounts.filter { ids.contains($0.id) } }
        return accounts.filter { $0.institution.caseInsensitiveCompare(link.institution) == .orderedSame }
    }

    private func dashboardURL(_ status: ServerStatus) -> URL? { status.dashboardURL.flatMap(URL.init(string:)) }

    private func openDashboard(_ status: ServerStatus) {
        if let url = dashboardURL(status) { openURL(url) }
    }

    // MARK: Actions

    private func load() async {
        let api = app.api
        async let overview = try? api.overview()
        state = await state.refreshed { try await api.serverStatus() }
        let loaded = await overview
        accounts = loaded?.accounts ?? accounts
        if let list = loaded?.accountHealth { health = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }

    /// Pulls every connected bank now, then says what came in.
    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let results = try await app.api.syncNow()
            await app.didWrite()
            let summary = Self.summary(results, waiting: state.value?.institutions.filter(\.needsSignIn).map(\.institution) ?? [])
            toast = DSToastMessage(summary.text, duration: .seconds(summary.failed ? 8 : 5))
        } catch {
            toast = DSToastMessage("Couldn't sync: \(error.localizedDescription)", duration: .seconds(8))
        }
    }

    /// "Harbor +12 · Summit +3", or "Everything's up to date", and who couldn't sync.
    static func summary(_ results: [LinkSyncResult], waiting: [String]) -> (text: String, failed: Bool) {
        let failed = results.filter { !$0.ok }.map(\.institution)
        let added = results.filter { $0.ok && ($0.report?.rowsAdded ?? 0) > 0 }
            .map { "\($0.institution) +\($0.report?.rowsAdded ?? 0)" }
        var parts: [String] = []
        if results.isEmpty {
            parts.append("Nothing to sync right now")
        } else {
            parts.append(added.isEmpty ? "Everything's up to date" : "Synced · " + added.joined(separator: " · "))
        }
        if !failed.isEmpty { parts.append("\(failed.joined(separator: " and ")) couldn't sync; the server tries again on its schedule") }
        if !waiting.isEmpty { parts.append("\(waiting.joined(separator: " and ")) waits for you to sign in again") }
        return (parts.joined(separator: ". ") + ".", !failed.isEmpty)
    }
}

/// "+": linking a bank happens on the dashboard, so bank logins never touch the phone.
private struct AddAccountSheet: View {
    let dashboardURL: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    DSGlyph(systemImage: "building.columns", tone: .iris, size: 56)
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Text("Add accounts on your dashboard").dsFont(.title).foregroundStyle(Color.ds.ink)
                        Text("Banks are linked on your server's dashboard, so your bank logins never pass through this phone.")
                            .dsFont(.callout)
                            .foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DSCard(padding: DSSpace.md) {
                        VStack(alignment: .leading, spacing: DSSpace.md) {
                            step(1, "Open the Budget dashboard on your server.")
                            step(2, "Go to Accounts, then Connect a bank — or import a statement file.")
                            step(3, "Come back here. New accounts show up after the first sync.")
                        }
                    }
                    if let dashboardURL {
                        Button("Open dashboard") {
                            openURL(dashboardURL)
                            dismiss()
                        }
                        .buttonStyle(.ds(.primary, fullWidth: true))
                    } else {
                        Text("Open the dashboard on your server to get there.")
                            .dsFont(.caption)
                            .foregroundStyle(Color.ds.inkTertiary)
                    }
                }
                .padding(DSSpace.gutter)
            }
            .dsScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpace.sm) {
            Text("\(number)").dsFont(.mono).foregroundStyle(Color.ds.accent)
            Text(text).dsFont(.body).foregroundStyle(Color.ds.inkSoft).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
