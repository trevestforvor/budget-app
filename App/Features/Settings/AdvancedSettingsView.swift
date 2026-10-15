import BudgetKit
import DesignSystem
import SwiftUI

/// Settings → Advanced: what the app talks to and how the models are set up. The connection is checked live when
/// this page opens (not every time Settings does), and server changes apply when Settings closes.
struct AdvancedSettingsView: View {
    @Bindable var draft: ServerDraft
    /// Closes Settings (after "Disconnect this phone").
    let onClose: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var status: ServerStatus?
    @State private var assistant: AssistantConfig?
    @State private var check: ConnectionCheck = .idle
    @State private var confirmsDisconnect = false

    var body: some View {
        List {
            connectionSection
            if draft.demoOn { liveModelSection }
            if let status {
                DecisionModelSection(policy: status.decisionPolicy, model: status.decisionModel, sample: status.decisionSample,
                                     available: status.availableDecisionProviders) {
                    await reload()
                }
                rolesSection(status)
            }
            assistantSection
            if let url = status?.dashboardURL.flatMap(URL.init(string:)) {
                DSListSection("Dashboard", footer: "Link banks, reconnect them, import statements and change server settings there.") {
                    Button { openURL(url) } label: {
                        DSListRow("Open the Budget dashboard", detail: url.host(), systemImage: "safari", tone: .azure) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: DSIconSize.xs, weight: .semibold))
                                .foregroundStyle(Color.ds.inkTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            #if targetEnvironment(simulator) || DEBUG
            DSListSection("Developer") {
                NavigationLink {
                    DesignSystemGallery().navigationBarTitleDisplayMode(.inline)
                } label: {
                    DSListRow("Design system", systemImage: "swatchpalette", tone: .lilac)
                }
            }
            #endif
            if canDisconnect {
                DSListSection("This phone", footer: "Removes the server address and token from this phone and deletes the offline copy. Your ledger on the server isn't touched.") {
                    SettingsDestructiveRow(title: "Disconnect this phone") { confirmsDisconnect = true }
                }
            }
        }
        .dsGroupedList()
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.revision) { await reload() }
        .task {
            // A live check when this page opens, so the card never shows stale good news.
            if draft.mode == .server { await testConnection() }
        }
        .confirmationDialog("Disconnect this phone?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await draft.disconnect(app)
                    onClose()
                }
            }
        } message: {
            Text("You'll need the server address and token again to reconnect. Nothing on your server changes.")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            ConnectionCard(mode: draft.mode, host: URL(string: draft.trimmedURL)?.host(), status: status, freshness: app.freshness,
                           liveModel: app.liveModel, check: check, pendingApply: pendingApply, canTest: !draft.trimmedURL.isEmpty) {
                Task { await testConnection() }
            }
            .settingsCardRow()
        } header: {
            DSEyebrow("Connection")
        }
        // The demo ledger exists only in the simulator.
        if AppModel.demoAvailable {
            DSListSection {
                DSToggleRow("Use the demo ledger", detail: draft.useDemo ? "Turn it off to connect to your own server." : "Seeded household data on this phone, no server needed.",
                            isOn: $draft.useDemo)
            }
        }
        if !draft.demoOn {
            DSListSection("Your server", footer: "Both come from your server's dashboard: Settings → Connect your phone. The phone only talks to your own server, and the token stays in this phone's Keychain.") {
                DSField("Server address", style: .inline, isCode: true) {
                    TextField("Server address", text: $draft.serverURL, prompt: Text("https://budget.example.com"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .onChange(of: draft.serverURL) { check = .idle }
                        .accessibilityIdentifier("serverAddress")
                }
                DSField("API token", style: .inline) {
                    HStack(spacing: DSSpace.sm) {
                        SecureField("API token", text: $draft.token, prompt: Text("Paste it from the dashboard"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .onChange(of: draft.token) { check = .idle }
                        PasteButton(payloadType: String.self) { strings in
                            if let pasted = strings.first { draft.token = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .labelStyle(.titleOnly)
                        .buttonBorderShape(.capsule)
                        .tint(Color.ds.surfaceRaised)
                    }
                }
                if let problem = setupProblem {
                    SettingsNote(text: problem, tint: Color.ds.amber, systemImage: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    private var liveModelSection: some View {
        DSListSection("Live model", footer: "Ask and the categorization model run on your own model server, with the demo ledger's numbers. Only in the simulator.") {
            DSToggleRow("Use your own model", systemImage: "cpu", tone: .iris, isOn: $draft.useLiveModel)
            if draft.useLiveModel {
                DSField("Model address", style: .inline, isCode: true) {
                    TextField("Model address", text: $draft.liveModelURL, prompt: Text("https://model.example.com"))
                        .keyboardType(.URL)
                }
            }
        }
    }

    private func rolesSection(_ status: ServerStatus) -> some View {
        DSListSection("Models", footer: app.isDemo
                      ? "The demo ledger runs no chat model: answers are written around the ledger's own figures."
                      : "Set on the Budget dashboard, under Settings → Models, where Test checks that each one answers.") {
            ForEach(status.roles) { assignment in
                DSListRow(assignment.role.purpose, detail: assignment.model ?? "Not assigned") {
                    if assignment.model == nil { DSTag("Off", tint: Color.ds.inkTertiary) }
                }
            }
        }
    }

    private var assistantSection: some View {
        DSListSection("Assistant", footer: "Exactly what the chat model is given. Tools that change anything only make a proposal — nothing changes until you tap Apply.") {
            if let assistant {
                NavigationLink {
                    PromptView(config: assistant)
                } label: {
                    DSListRow("System prompt", systemImage: "text.quote", tone: .iris)
                }
                NavigationLink {
                    ToolListView(tools: assistant.tools)
                } label: {
                    DSListRow("Tools", value: "\(assistant.tools.count)", systemImage: "wrench.and.screwdriver", tone: .lilac)
                }
            } else {
                DSListRow("Loading…", systemImage: "text.quote", tone: .iris)
                    .redacted(reason: .placeholder)
            }
        }
    }

    // MARK: State

    private var canDisconnect: Bool { !app.isDemo && !draft.trimmedURL.isEmpty }

    private var setupProblem: String? {
        guard !draft.demoOn else { return nil }
        if draft.trimmedURL.isEmpty {
            return AppModel.demoAvailable ? "Add your server's address. Until then the app stays on the demo ledger."
                                          : "Add your server's address. Until then there's nothing to show."
        }
        if draft.trimmedToken.isEmpty { return "Add the API token — without it the server turns every request away." }
        return nil
    }

    /// Settings shows the typed values; the app switches when Settings closes.
    private var pendingApply: Bool {
        switch draft.mode {
        case .demo: !app.isDemo
        case .server: app.isDemo
        case .notConnected: false
        }
    }

    // MARK: Actions

    private func reload() async {
        status = try? await app.api.serverStatus()
        assistant = try? await app.api.assistantConfig()
    }

    /// Checks what's typed — not what's saved — straight against the server, past the offline copy.
    private func testConnection() async {
        guard let url = URL(string: draft.trimmedURL), let scheme = url.scheme, scheme.hasPrefix("http"), url.host() != nil else {
            check = .failed("That isn't a server address. It looks like https://budget.example.com.")
            return
        }
        check = .checking
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let remote = RemoteBudgetAPI(baseURL: url, token: draft.trimmedToken.isEmpty ? nil : draft.trimmedToken)
            let reached = try await remote.serverStatus()
            let elapsed = clock.now - start
            let ms = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            check = .ok(version: reached.version, milliseconds: ms)
        } catch let error as BudgetAPIError {
            switch error {
            case .server(status: 401, message: _):
                check = .failed("The server didn't accept the token. Copy it again from the dashboard: Settings → Connect your phone.")
            case .server(status: 421, message: _), .notFound:
                check = .failed("Something answered, but it isn't Budget. Check the address.")
            case .unreachable:
                check = .failed("Can't reach your server. Check the address, and that the server is on.")
            case .offline:
                check = .failed("This phone is offline.")
            case .timedOut:
                check = .failed("Your server took too long to answer. Try again in a moment.")
            default:
                check = .failed("Your server answered with a problem. Try again in a moment.")
            }
        } catch {
            check = .failed("Can't reach your server. Check the address, and that the server is on.")
        }
    }
}

enum ConnectionCheck: Equatable {
    case idle, checking
    case ok(version: String, milliseconds: Int)
    case failed(String)
}

/// What the app is talking to right now, whether it answers, and a way to check.
private struct ConnectionCard: View {
    let mode: ConnectionMode
    let host: String?
    let status: ServerStatus?
    let freshness: Freshness
    let liveModel: String?
    let check: ConnectionCheck
    let pendingApply: Bool
    let canTest: Bool
    let onTest: () -> Void

    var body: some View {
        DSCard(padding: DSSpace.md, elevation: .raised) {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                HStack(alignment: .top, spacing: DSSpace.sm) {
                    DSIconTile(systemImage: symbol, tone: tone, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).dsFont(.headline).foregroundStyle(Color.ds.ink)
                        Text(subtitle)
                            .dsFont(.caption)
                            .foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DSSpace.xs) {
                        statusTag
                        Spacer(minLength: 0)
                        testButton
                    }
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        statusTag
                        testButton
                    }
                }
                if case let .failed(message) = check {
                    Text(message)
                        .dsFont(.callout)
                        .foregroundStyle(Color.ds.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if pendingApply {
                    Text("Changes apply when you close Settings.")
                        .dsFont(.caption)
                        .foregroundStyle(Color.ds.inkSecondary) // inkTertiary is below AA on a raised card
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var testButton: some View {
        if mode != .demo, canTest {
            Button(action: onTest) {
                if check == .checking {
                    ProgressView().controlSize(.small).tint(Color.ds.ink)
                } else {
                    Text("Test connection")
                }
            }
            .buttonStyle(.ds(.secondary))
            .disabled(!canTest || check == .checking)
            .accessibilityLabel(check == .checking ? "Checking the connection" : "Test connection")
        }
    }

    private var title: String {
        switch mode {
        case .demo: "Demo ledger"
        case .server: "Your server"
        case .notConnected: "Not connected"
        }
    }

    private var subtitle: String {
        switch mode {
        case .demo: liveModel.map { "Seeded household data on this phone · Ask runs on \($0)" } ?? "Seeded household data on this phone"
        case .server: host ?? "Your server"
        case .notConnected: "Add your server's address below"
        }
    }

    private var symbol: String {
        switch mode {
        case .demo: "sparkles"
        case .server: "server.rack"
        case .notConnected: "bolt.horizontal.circle"
        }
    }

    private var tone: DSTone {
        switch (mode, check) {
        case (.notConnected, _), (_, .failed): .orchid
        case (.demo, _): .iris
        case (.server, _): freshness.isOffline ? .amber : .cyan
        }
    }

    @ViewBuilder
    private var statusTag: some View {
        switch check {
        case .checking:
            DSTag("Checking…", tint: Color.ds.inkSecondary)
        case let .ok(version, ms):
            DSTag("Reachable · \(version) · \(ms) ms", systemImage: "checkmark", tint: Color.ds.accent)
        case .failed:
            DSTag("Not reachable", systemImage: "xmark", tint: Color.ds.caution)
        case .idle:
            switch mode {
            case .demo: DSTag("No server needed", tint: Color.ds.iris)
            case .notConnected: DSTag("Showing the demo", tint: Color.ds.amber)
            case .server:
                if freshness == .unreachable {
                    DSTag("Not answering", systemImage: "wifi.slash", tint: Color.ds.amber)
                } else if freshness == .cached {
                    DSTag("Offline copy", systemImage: "icloud.slash", tint: Color.ds.amber)
                } else if let status {
                    DSTag("Connected · \(status.version)", systemImage: "checkmark", tint: Color.ds.accent)
                } else {
                    DSTag("Not checked yet", tint: Color.ds.inkSecondary)
                }
            }
        }
    }
}

/// Which model files uncertain transactions, and whether it may ask Jev. How sure it must be lives on the Review page.
private struct DecisionModelSection: View {
    let policy: DecisionPolicy
    let model: String?
    let sample: String?
    /// What the server can run (nil from older servers = assume everything).
    var available: [DecisionProvider]? = nil
    let onApplied: () async -> Void

    @Environment(AppModel.self) private var app
    @State private var provider: DecisionProvider = .off
    @State private var escalate = false
    @State private var isApplying = false
    @State private var message: String?

    private func isAvailable(_ p: DecisionProvider) -> Bool { available?.contains(p) ?? true }

    private var isDirty: Bool {
        provider != policy.provider || (provider.runsLocally && escalate != policy.escalateToJev)
    }

    var body: some View {
        DSListSection("Categorization model", footer: footer) {
            DSListRow("Files uncertain transactions", systemImage: "wand.and.stars", tone: .iris) {
                Picker("Model", selection: $provider) {
                    ForEach(DecisionProvider.allCases.filter { isAvailable($0) || $0 == policy.provider }, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .tint(Color.ds.inkSecondary)
            }
            if provider != .off {
                if provider.runsLocally {
                    DSToggleRow("Ask Jev when unsure", detail: isAvailable(.jev) ? nil : "Needs an OpenRouter key, added in the dashboard's server settings.",
                                isOn: $escalate)
                        .disabled(!isAvailable(.jev) && !escalate)
                }
                if let model, provider == policy.provider {
                    DSListRow("Running", detail: model)
                }
                if let sample {
                    DisclosureGroup {
                        Text(sample)
                            .dsFont(.mono)
                            .foregroundStyle(Color.ds.inkSoft)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, DSSpace.xs)
                    } label: {
                        Text("What the model sees").dsFont(.body).foregroundStyle(Color.ds.ink)
                    }
                    .tint(Color.ds.inkSecondary)
                    .frame(minHeight: DSSize.listRow)
                }
            }
            if isDirty {
                Button(isApplying ? "Applying…" : "Apply and re-check what's waiting") { Task { await apply() } }
                    .buttonStyle(.ds(.quiet))
                    .frame(minHeight: DSSize.listRow)
                    .disabled(isApplying)
            }
            if let message {
                SettingsNote(text: message)
            }
        }
        .onAppear {
            provider = policy.provider
            escalate = policy.escalateToJev
        }
    }

    private var footer: String {
        switch provider {
        case .off:
            "Off: everything Budget isn't sure about comes to you in Review."
        case .jev:
            "Jev (TypeSafe) gets only what's shown above for each uncertain transaction: no names, accounts, dates or exact amounts. How sure it must be is set in Review."
        case .localDecide, .laya:
            escalate
                ? "Runs on your server first. Anything it isn't sure of goes to Jev, which gets only what's shown above; if Jev isn't sure either, it comes to you."
                : "Runs on your server. Anything it isn't sure of comes to you in Review, and anything it filed can be changed later."
        }
    }

    private func apply() async {
        isApplying = true
        defer { isApplying = false }
        do {
            message = try await app.perform(.updateDecisionPolicy(UpdateDecisionPolicy(
                provider: provider, escalateToJev: provider.runsLocally ? escalate : nil, rerunPending: true)))
            await onApplied()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct PromptView: View {
    let config: AssistantConfig

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                DSEyebrow("Version \(config.promptVersion)")
                Text(config.systemPrompt)
                    .dsFont(.mono)
                    .foregroundStyle(Color.ds.inkSoft)
                    .textSelection(.enabled)
            }
            .padding(DSSpace.gutter)
        }
        .dsScreenBackground()
        .navigationTitle("System prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: config.systemPrompt)
        }
    }
}

private struct ToolListView: View {
    let tools: [ToolDefinition]

    var body: some View {
        List {
            ForEach([ToolKind.read, .write, .client], id: \.self) { kind in
                DSListSection(Self.title(kind)) {
                    ForEach(tools.filter { $0.kind == kind }) { tool in
                        NavigationLink {
                            ToolDetailView(tool: tool)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name).dsFont(.mono).foregroundStyle(Color.ds.ink)
                                Text(tool.description)
                                    .dsFont(.caption)
                                    .foregroundStyle(Color.ds.inkSecondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, DSSpace.xs)
                            .frame(minHeight: DSSize.listRow, alignment: .leading)
                        }
                    }
                }
            }
        }
        .dsGroupedList()
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func title(_ kind: ToolKind) -> String {
        switch kind {
        case .read: "Reads the ledger"
        case .write: "Proposes a change"
        case .client: "Handled by the app"
        }
    }
}

private struct ToolDetailView: View {
    let tool: ToolDefinition

    private var schema: String {
        (try? tool.parameters.data(pretty: true)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                DSTag(ToolListView.title(tool.kind), tint: tool.kind == .read ? Color.ds.accent : Color.ds.iris)
                Text(tool.name).dsFont(.title).foregroundStyle(Color.ds.ink)
                Text(tool.description).dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                DSEyebrow("Parameters")
                DSCard(padding: DSSpace.md) {
                    Text(schema)
                        .dsFont(.mono)
                        .foregroundStyle(Color.ds.inkSoft)
                        .textSelection(.enabled)
                }
            }
            .padding(DSSpace.gutter)
        }
        .dsScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
    }
}
