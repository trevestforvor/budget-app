import BudgetKit
import DesignSystem
import SwiftUI

/// A proposal that changes more than a handful of rows: how many, and a few of the rows it reaches, before it applies.
struct ProposalReviewSheet: View {
    let proposal: ProposedAction
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// The rows it changes, and the rows it reaches (more when some of them stay as they are).
    private var count: Int { proposal.reviewCount }
    private var reach: Int { max(proposal.matchCount ?? count, count) }
    private var sample: [String] { proposal.sample ?? [] }

    var body: some View {
        NavigationStack {
            List {
                DSListSection(footer: footer) {
                    Text(proposal.title)
                        .dsFont(.headline)
                        .foregroundStyle(Color.ds.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = proposal.detail {
                        Text(detail).dsFont(.callout).foregroundStyle(Color.ds.inkSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if reach > count {
                        Text("It reaches \(reach) transactions; \(count) of them change.")
                            .dsFont(.callout).foregroundStyle(Color.ds.inkSoft).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !sample.isEmpty {
                    DSListSection(sample.count < reach ? "\(sample.count) of \(reach)" : "All \(reach)") {
                        ForEach(Array(sample.enumerated()), id: \.offset) { _, line in
                            SampleLine(line: line)
                        }
                    }
                }
            }
            .dsGroupedList()
            .navigationTitle("\(count) transactions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                    onApply()
                } label: {
                    Text(reach > count ? "Apply to \(count)" : "Apply to all \(count)").fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.ds(.ai, size: .large, fullWidth: true))
                .padding(.horizontal, DSSpace.gutter)
                .padding(.vertical, DSSpace.sm)
                .background {
                    Color.ds.canvas.overlay(alignment: .top) { DSDivider() }.ignoresSafeArea(edges: .bottom)
                }
                .accessibilityIdentifier("applyReviewedProposal")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
    }

    private var footer: String {
        "Nothing changes until you apply. If any of these change first, it won't apply, and you can refresh it."
    }
}

/// "Oct 3 · Blue Bottle · −$5.40 · Dining" as a row: the merchant, the day and category under it, the amount trailing.
private struct SampleLine: View {
    let line: String

    var body: some View {
        let parts = line.components(separatedBy: " · ")
        if parts.count == 4 {
            DSListRow(parts[1], detail: "\(parts[0]) · \(parts[3])", value: parts[2])
                .accessibilityElement(children: .combine)
        } else {
            Text(line).dsFont(.callout).foregroundStyle(Color.ds.inkSoft)
        }
    }
}
