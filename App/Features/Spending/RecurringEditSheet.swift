import BudgetKit
import DesignSystem
import SwiftUI

/// One merchant's recurring charges, the person's way: how often they come, subscription or bill, or not recurring at
/// all (a restaurant that only looks like a subscription). Opened from a recurring row — Recurring, Spending's "Coming
/// up", a category — from a transaction's details, and from Recurring's add list. What Budget found is the starting
/// point; saving sends only what changed.
struct RecurringEditSheet: View {
    let merchant: String
    /// What Budget lists for the merchant now; nil when it isn't recurring.
    let current: Subscription?
    /// The charge that recurs — the one it was opened from — so only charges like it count (Prime, not every Amazon order).
    var amount: Money?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var cadence: Subscription.Cadence
    @State private var kind: Subscription.Kind
    @State private var isSaving = false
    @State private var problem: String?

    init(merchant: String, current: Subscription?, amount: Money? = nil) {
        self.merchant = merchant
        self.current = current
        self.amount = amount ?? current?.amount
        _cadence = State(initialValue: current?.cadence ?? .monthly)
        _kind = State(initialValue: current?.kind ?? .subscription)
    }

    private var changed: Bool { current == nil || cadence != current?.cadence || kind != current?.kind }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        DSEyebrow(current == nil ? "Mark as recurring" : "Recurring")
                        Text(merchant).dsFont(.display).foregroundStyle(Color.ds.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let current, current.setByPerson != true {
                            Text("Budget found this from its charges.").dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: DSSpace.sm) {
                        DSEyebrow("How often")
                        Picker("How often", selection: $cadence) {
                            ForEach(Subscription.Cadence.allCases, id: \.self) { Text(Self.label($0)).tag($0) }
                        }
                        .segmentedUnlessLargeText()
                        .accessibilityIdentifier("recurringCadence")
                        if cadence == .yearly {
                            Text("Its charges count a twelfth a month for a year instead of all in the month they land.")
                                .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: DSSpace.sm) {
                        DSEyebrow("Kind")
                        Picker("Kind", selection: $kind) {
                            Text("Subscription").tag(Subscription.Kind.subscription)
                            Text("Bill").tag(Subscription.Kind.bill)
                        }
                        .segmentedUnlessLargeText()
                        Text("Subscriptions are the ones you choose to keep; bills are rent, utilities and fees.")
                            .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DSSpace.gutter)
            }
            .safeAreaInset(edge: .bottom) { buttons }
            .dsScreenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color.ds.canvas)
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            if let problem {
                Text(problem).dsFont(.callout).foregroundStyle(Color.ds.caution).fixedSize(horizontal: false, vertical: true)
            }
            Button(isSaving ? "Saving…" : (current == nil ? "Mark as recurring" : "Save")) {
                Task {
                    let newCadence = current == nil || cadence != current?.cadence ? cadence : nil
                    await run(SetRecurring(merchant: merchant, isRecurring: true, cadence: newCadence,
                                           kind: current == nil || kind != current?.kind ? kind : nil,
                                           amount: newCadence == nil ? nil : amount.map(DecimalAmount.init)))
                }
            }
            .buttonStyle(.ds(.primary, fullWidth: true))
            .disabled(isSaving || !changed)
            .accessibilityIdentifier("recurringSave")
            if current != nil {
                Button("Not recurring") { Task { await run(SetRecurring(merchant: merchant, isRecurring: false)) } }
                    .buttonStyle(.ds(.secondary, fullWidth: true))
                    .disabled(isSaving)
                    .accessibilityIdentifier("recurringRemove")
            }
            if current?.setByPerson == true {
                Button("Let Budget decide") { Task { await run(SetRecurring(merchant: merchant, isRecurring: nil)) } }
                    .buttonStyle(.ds(.quiet, fullWidth: true))
                    .disabled(isSaving)
            }
        }
        .padding(.horizontal, DSSpace.gutter)
        .padding(.vertical, DSSpace.sm)
        .background { Color.ds.canvas.ignoresSafeArea(edges: .bottom) }
    }

    private func run(_ choice: SetRecurring) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.perform(.setRecurring(choice))
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    static func label(_ cadence: Subscription.Cadence) -> String {
        switch cadence {
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .quarterly: "Quarterly"
        case .yearly: "Yearly"
        }
    }
}

/// Recurring → Add: a merchant from the last year's charges that Budget doesn't list as recurring, then how it repeats.
struct AddRecurringSheet: View {
    /// Merchants already listed, left out here.
    let listed: Set<String>
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var merchants: LoadState<[Candidate]> = .loading
    @State private var search = ""
    @State private var chosen: Candidate?

    struct Candidate: Identifiable, Hashable {
        var merchant: String
        var latest: Money
        var lastCharged: Date
        var charges: Int
        var id: String { merchant }
    }

    var body: some View {
        NavigationStack {
            List {
                switch merchants {
                case .loading:
                    LoadingPlaceholder().listRowBackground(Color.clear)
                case let .failed(message):
                    Text(message).dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                case let .loaded(all):
                    let shown = search.isEmpty ? all : all.filter { $0.merchant.localizedCaseInsensitiveContains(search) }
                    DSListSection(footer: "Charges from the last year that Budget doesn't list as recurring. Pick one to say how often it comes.") {
                        ForEach(shown) { candidate in
                            Button { chosen = candidate } label: {
                                DSListRow(candidate.merchant,
                                          detail: "\(candidate.charges == 1 ? "1 charge" : "\(candidate.charges) charges") · last \(candidate.lastCharged.formatted(.dateTime.month(.abbreviated).day()))",
                                          value: candidate.latest.formatted(), showsChevron: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .dsGroupedList()
            .searchable(text: $search, prompt: "Merchant")
            .navigationTitle("Add recurring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $chosen, onDismiss: { if app.revision != startRevision { dismiss() } }) { candidate in
                RecurringEditSheet(merchant: candidate.merchant, current: nil, amount: candidate.latest)
            }
        }
        .presentationBackground(Color.ds.canvas)
        .task { await load() }
        .onAppear { startRevision = app.revision }
    }

    /// Closes the list once a merchant was added (the ledger changed while the choice was open).
    @State private var startRevision = 0

    private func load() async {
        let since = Calendar.current.date(byAdding: .month, value: -13, to: AppClock.now)
        let api = app.api
        let listed = Set(listed.map(RecurringChoice.key))
        merchants = await merchants.refreshed {
            let rows = try await api.transactions(TransactionFilter(since: since, direction: .moneyOut, visibility: .counted, limit: 2000))
            return Dictionary(grouping: rows.filter { !listed.contains(RecurringChoice.key($0.merchant)) }, by: \.merchant)
                .map { merchant, rows in
                    let newest = rows.max { $0.postedAt < $1.postedAt }!
                    return Candidate(merchant: merchant, latest: newest.amount.magnitude, lastCharged: newest.postedAt, charges: rows.count)
                }
                .sorted { $0.lastCharged > $1.lastCharged }
        }
    }
}
