import BudgetKit
import DesignSystem
import SwiftUI

/// Settings → Review: what's waiting, how sure the model must be to file something on its own, and what should
/// always come to you first.
struct ReviewSettingsView: View {
    /// Closes Settings and opens the first waiting transaction in Activity.
    let onOpenReview: () -> Void

    @Environment(AppModel.self) private var app
    @State private var status: ServerStatus?
    @State private var queue: [ReviewItem]?
    @State private var remembered: Int?
    @State private var ruleCount: Int?
    @State private var didLoad = false
    @State private var percent: Double = 80
    @State private var reviewNew = false
    @State private var holdPending = false
    @State private var bigAmounts = false
    @State private var bigText = "500"
    @FocusState private var editsAmount: Bool
    @State private var isApplying = false
    @State private var message: String?
    @State private var problem: String?

    private var policy: DecisionPolicy? { status?.decisionPolicy }
    private var isDirty: Bool { policy.map { Int(percent) != $0.autoAcceptPercent } ?? false }

    var body: some View {
        List {
            Section { waitingCard.settingsCardRow() }
            sureSection
            if policy != nil {
                alwaysAskSection
                holdSection
            } else if didLoad {
                // Without the settings, toggles would show defaults that aren't yours.
                Section {
                    SettingsNote(text: "Couldn't load your review settings. Pull down to try again.", tint: Color.ds.amber, systemImage: "wifi.slash")
                        .settingsCardRow()
                }
            }
            handledSection
        }
        .dsGroupedList()
        .announcesProblem(problem)
        .refreshable { await load() }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.revision) { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editsAmount = false }
            }
        }
        .onChange(of: editsAmount) { _, editing in
            if !editing { Task { await commitAmount() } }
        }
    }

    // MARK: Sections

    private var waitingCard: some View {
        DSCard(padding: DSSpace.md, elevation: .raised) {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                DSEyebrow("Waiting for you", dot: (queue?.isEmpty ?? true) ? nil : Color.ds.caution)
                if let queue {
                    if queue.isEmpty {
                        Text("Nothing waiting").dsFont(.headline).foregroundStyle(Color.ds.ink)
                        Text("New transactions Budget isn't sure about show up in Activity.")
                            .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                    } else {
                        Text(ReviewWaiting.headline(decisions: ReviewGroup.groups(queue).count, transactions: queue.count))
                            .dsFont(.headline).foregroundStyle(Color.ds.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open review", action: onOpenReview)
                            .buttonStyle(.ds(.secondary))
                            .accessibilityIdentifier("openReview")
                    }
                } else if didLoad {
                    Text("Couldn't check what's waiting").dsFont(.headline).foregroundStyle(Color.ds.ink)
                    Text("Your server didn't answer. Pull down to try again.").dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                } else {
                    Text("Counting…").dsFont(.headline).foregroundStyle(Color.ds.inkSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var sureSection: some View {
        if let policy, policy.provider != .off {
            DSListSection("File on its own when it's this sure",
                          footer: "Lower means fewer questions. Your answers and your rules always win over the model.") {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Sure enough at").dsFont(.body).foregroundStyle(Color.ds.ink)
                        Spacer()
                        Text("\(Int(percent))%").dsFont(.amountRow).foregroundStyle(Color.ds.ink)
                    }
                    Slider(value: $percent, in: Double(DecisionPolicy.allowedPercents.lowerBound)...Double(DecisionPolicy.allowedPercents.upperBound), step: 1)
                        .tint(Color.ds.accent)
                        .accessibilityLabel("Sure enough to file on its own")
                        .accessibilityValue("\(Int(percent)) percent")
                }
                .padding(.vertical, DSSpace.sm)
                if isDirty {
                    Button(isApplying ? "Applying…" : applyTitle) { Task { await applyPercent() } }
                        .buttonStyle(.ds(.quiet))
                        .frame(minHeight: DSSize.listRow)
                        .disabled(isApplying)
                        .accessibilityIdentifier("applyThreshold")
                }
                if let message { SettingsNote(text: message) }
                NavigationLink(value: SettingsRoute.advanced) {
                    DSListRow("Decided by", detail: modelLine)
                }
            }
        } else if policy != nil {
            DSListSection("Filing on its own") {
                NavigationLink(value: SettingsRoute.advanced) {
                    DSListRow("Off", detail: "Everything Budget isn't sure about comes to you. Turn on a model in Advanced.",
                              systemImage: "wand.and.stars", tone: .iris)
                }
            }
        }
    }

    private var alwaysAskSection: some View {
        DSListSection("Always ask me about", footer: problem) {
            DSToggleRow("New merchants", detail: "The first time a merchant shows up, however sure the model is.",
                        isOn: Binding(get: { reviewNew }, set: { on in
                            reviewNew = on
                            Task { await update(UpdateDecisionPolicy(reviewNewMerchants: on)) { reviewNew = !on } }
                        }))
            DSToggleRow("Big amounts", detail: bigAmounts ? "Anything over \(bigAmountLabel) that a rule doesn't cover." : "Anything over an amount you pick, unless a rule covers it.",
                        isOn: Binding(get: { bigAmounts }, set: { on in
                            bigAmounts = on
                            Task {
                                await update(UpdateDecisionPolicy(reviewAbove: on ? DecimalAmount(string: cleanedAmount) ?? DecimalAmount(minorUnits: 50_000) : DecimalAmount(minorUnits: 0))) {
                                    bigAmounts = !on
                                }
                            }
                        }))
            if bigAmounts {
                DSField("Over", style: .inline, prefix: "$", isEmpty: bigText.isEmpty, isFocused: editsAmount) {
                    TextField("Amount", text: $bigText, prompt: Text("500"))
                        .keyboardType(.decimalPad)
                        .focused($editsAmount)
                        .accessibilityLabel("Ask about amounts over, in dollars")
                }
            }
        }
    }

    private var holdSection: some View {
        DSListSection("Hold back") {
            DSToggleRow("Pending charges", detail: "Wait until a charge posts before asking. Pending amounts can still change.",
                        isOn: Binding(get: { holdPending }, set: { on in
                            holdPending = on
                            Task { await update(UpdateDecisionPolicy(holdPending: on)) { holdPending = !on } }
                        }))
        }
    }

    private var handledSection: some View {
        DSListSection("Handled for you") {
            DSListRow("Moves between your accounts", detail: "Matched on both sides and left out of spending.",
                      systemImage: "arrow.left.arrow.right", tone: .violet)
            DSListRow("Money going out is never money in", detail: "A refund or a transfer can't be filed as pay or card rewards.",
                      systemImage: "arrow.down.circle", tone: .cyan)
            DSListRow("Money in on a card is never pay", detail: "A card payment or a refund comes to you instead of landing in Income.",
                      systemImage: "creditcard", tone: .cyan)
            NavigationLink(value: SettingsRoute.memory) {
                DSListRow("Merchants Budget files on its own", detail: "What it learned from your answers, your rules and the model.", value: remembered.map(String.init),
                          systemImage: "brain", tone: .lilac)
            }
            NavigationLink(value: SettingsRoute.rules) {
                DSListRow("Your rules", detail: "They run before everything else.", value: ruleCount.map(String.init),
                          systemImage: "arrow.triangle.branch", tone: .azure)
            }
        }
    }

    // MARK: Values

    private var applyTitle: String {
        guard let count = queue?.count, count > 0 else { return "Apply" }
        return "Apply and re-check the \(count) waiting"
    }

    private var modelLine: String {
        guard let status else { return "" }
        let name = status.decisionPolicy.provider.displayName
        return "\(name) · change in Advanced"
    }

    private var cleanedAmount: String {
        bigText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
    }

    private var bigAmountLabel: String {
        DecimalAmount(string: cleanedAmount).map { $0.money().shortString } ?? "$\(bigText)"
    }

    // MARK: Actions

    private func load() async {
        let api = app.api
        async let status = try? api.serverStatus()
        async let queue = try? api.reviewQueue()
        async let remembered = try? api.rememberedMerchants()
        async let rules = try? api.rules()
        let loaded = await status
        // A threshold being dragged but not applied yet survives a reload (a toggle changed meanwhile).
        let keepsPercent = isDirty
        self.status = loaded
        self.queue = await queue
        self.remembered = await remembered?.count
        self.ruleCount = await rules?.count
        didLoad = true
        if let policy = loaded?.decisionPolicy { show(policy, keepsPercent: keepsPercent) }
    }

    private func show(_ policy: DecisionPolicy, keepsPercent: Bool = false) {
        if !keepsPercent { percent = Double(policy.autoAcceptPercent) }
        reviewNew = policy.reviewNewMerchants
        holdPending = policy.holdPending
        bigAmounts = policy.reviewAbove != nil
        if let above = policy.reviewAbove, !editsAmount {
            bigText = above.minorUnits % 100 == 0 ? "\(above.minorUnits / 100)" : above.description
        }
    }

    /// A toggle takes effect at once; if the server says no, it flips back (`revert`, then the policy as last loaded) and
    /// says why.
    private func update(_ change: UpdateDecisionPolicy, revert: () -> Void = {}) async {
        problem = nil
        do {
            try await app.perform(.updateDecisionPolicy(change))
        } catch {
            problem = error.localizedDescription
            revert()
            if let policy { show(policy) }
        }
    }

    private func commitAmount() async {
        guard bigAmounts else { return }
        guard let amount = DecimalAmount(string: cleanedAmount), amount.minorUnits > 0 else {
            problem = "Enter an amount, like 500."
            return
        }
        guard amount != policy?.reviewAbove else { return }
        await update(UpdateDecisionPolicy(reviewAbove: amount))
    }

    private func applyPercent() async {
        isApplying = true
        defer { isApplying = false }
        do {
            message = try await app.perform(.updateDecisionPolicy(UpdateDecisionPolicy(autoAcceptPercent: Int(percent), rerunPending: true)))
        } catch {
            message = error.localizedDescription
        }
    }
}
