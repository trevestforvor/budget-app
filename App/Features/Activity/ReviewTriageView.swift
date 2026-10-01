import BudgetKit
import DesignSystem
import SwiftUI

/// Review one decision at a time: each group's first row in full, its answer filing the whole group, then the
/// next group. Skipped groups stay in the queue for later. Ends on "All caught up".
struct ReviewTriageView: View {
    /// Start here (a group's id) instead of at the top of the queue.
    var startingAt: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var total = 0
    @State private var skipped: [String] = []
    @State private var toast: DSToastMessage?

    /// Not skipped yet, in the queue's order, the chosen group first.
    private var remaining: [ReviewGroup] {
        let groups = app.reviewGroups.filter { !skipped.contains($0.id) }
        guard let startingAt, let index = groups.firstIndex(where: { $0.id == startingAt }) else { return groups }
        return [groups[index]] + groups.filter { $0.id != startingAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let group = remaining.first {
                    let position = min(max(total - remaining.count + 1, 1), max(total, 1))
                    TransactionDetailView(transaction: group.first.transaction, presentation: .triage(position: "\(position) of \(max(total, remaining.count))"),
                                          toast: $toast, onFiled: {}, onSkip: { skipped.append(group.id) })
                        .id(group.id)
                        // With Reduce Motion the next decision fades in instead of sliding the whole screen.
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                } else {
                    caughtUp
                }
            }
            .animation(DSMotion.standard, value: remaining.first?.id)
            .navigationDestination(for: LedgerTransaction.self) { TransactionDetailView(transaction: $0) }
        }
        .dsToast(remaining.isEmpty ? $toast : .constant(nil))
        .presentationBackground(Color.ds.canvas)
        .onAppear { if total == 0 { total = app.reviewGroups.count } }
    }

    private var caughtUp: some View {
        VStack(spacing: DSSpace.lg) {
            DSStateView(systemImage: "checkmark.circle",
                        title: skipped.isEmpty ? "All caught up" : "That's the lot for now",
                        message: skipped.isEmpty ? "Nothing is waiting for an answer. New transactions Budget isn't sure about will show up here."
                                                 : "You skipped \(skipped.count == 1 ? "one" : "\(skipped.count)"). They're still in Activity when you want them.")
            Button("Done") { dismiss() }
                .buttonStyle(.ds(.primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsScreenBackground()
    }
}
