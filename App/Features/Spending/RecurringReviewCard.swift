import BudgetKit
import DesignSystem
import SwiftUI

/// The top of Recurring when Budget has a question: "Is this recurring?" for charges that have only begun to repeat,
/// "Did this stop?" for a listed one gone quiet, and the ones the person said stopped, with a way back. Every answer
/// goes through `RowEdits` (the one write path, with Undo on the toast).
struct RecurringReviewCard: View {
    let review: RecurringReview
    @Binding var toast: DSToastMessage?
    @Environment(AppModel.self) private var app
    /// Rows answered here and waiting for the ledger's next answer, so a tap takes them away at once.
    @State private var answered: Set<String> = []

    var body: some View {
        let candidates = review.candidates.filter { !answered.contains($0.merchant) }
        let stopped = review.maybeStopped.filter { !answered.contains($0.merchant) }
        let ended = (review.ended ?? []).filter { !answered.contains($0) }
        if !candidates.isEmpty || !stopped.isEmpty || !ended.isEmpty {
            DSCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        DSEyebrow("To review", dot: candidates.isEmpty && stopped.isEmpty ? nil : Color.ds.amber)
                        Spacer(minLength: DSSpace.xs)
                        if candidates.count + stopped.count > 0 {
                            DSTag("\(candidates.count + stopped.count)", tint: Color.ds.amber)
                                .accessibilityLabel("\(candidates.count + stopped.count) to review")
                        }
                    }
                    .padding(.top, DSSpace.md)
                    .padding(.bottom, DSSpace.xs)
                    ForEach(stopped) { item in
                        DSDivider()
                        question(item, tags: ["Recurring"], detail: Self.stoppedDetail(item), ask: "Did this stop?") {
                            Button("Yes, I canceled it") { answer(item.merchant, .stopped) }
                                .buttonStyle(.ds(.tinted, size: .compact))
                                .accessibilityIdentifier("recurringStopped")
                            Button("No, still active") { answer(item.merchant, .stillActive) }
                                .buttonStyle(.ds(.secondary, size: .compact))
                                .accessibilityIdentifier("recurringStillActive")
                        }
                    }
                    ForEach(candidates) { item in
                        DSDivider()
                        question(item, tags: ["Recurring", "Review"], detail: Self.candidateDetail(item), ask: "Is this recurring?") {
                            Button("Yes, it repeats") { confirm(item) }
                                .buttonStyle(.ds(.tinted, size: .compact))
                                .accessibilityIdentifier("recurringConfirm")
                            Button("Not recurring") { dismiss(item) }
                                .buttonStyle(.ds(.secondary, size: .compact))
                                .accessibilityIdentifier("recurringDismiss")
                        }
                    }
                    ForEach(ended, id: \.self) { merchant in
                        DSDivider()
                        DSListRow(merchant, detail: "You said it stopped") {
                            Button("Put back") { putBack(merchant) }
                                .buttonStyle(.ds(.quiet))
                                .accessibilityIdentifier("recurringPutBackStopped")
                                .accessibilityLabel("Put \(merchant) back on recurring")
                        }
                    }
                }
                // Padding on the stack, not each row, so the dividers are inset like the text (as Home's Recent).
                .padding(.horizontal, DSSpace.md)
                .padding(.bottom, DSSpace.xs)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("recurringReview")
        }
    }

    private func question<Buttons: View>(_ item: Subscription, tags: [String], detail: String, ask: String,
                                         @ViewBuilder buttons: () -> Buttons) -> some View {
        let category = app.category(item.categoryID)
        return VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack(alignment: .top, spacing: DSSpace.sm) {
                DSGlyph(systemImage: category?.symbol ?? "repeat",
                        tone: CategoryStyle.tone(for: category ?? app.category("subscriptions")))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.merchant).dsFont(.bodyEmphasis).foregroundStyle(Color.ds.ink)
                    HStack(spacing: DSSpace.xxs) {
                        ForEach(tags, id: \.self) { tag in DSTag(tag, tint: tag == "Review" ? Color.ds.amber : Color.ds.accent) }
                    }
                    Text(detail).dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DSSpace.xs)
                DSAmountText(item.amount.decimal, currencyCode: item.amount.currencyCode, sign: .magnitude)
            }
            .accessibilityElement(children: .combine)
            Text(ask).dsFont(.callout).foregroundStyle(Color.ds.inkSoft)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DSSpace.xs) { buttons() }
                VStack(alignment: .leading, spacing: DSSpace.xs) { buttons() }
            }
        }
        .padding(.vertical, DSSpace.md)
    }

    /// "Monthly · no charge since Aug 22".
    static func stoppedDetail(_ item: Subscription) -> String {
        "\(cadence(item.cadence)) · no charge since \(item.lastCharged.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// "Charged twice, about a month apart · next around Oct 14".
    static func candidateDetail(_ item: Subscription) -> String {
        let times = item.charges == 2 ? "twice" : "\(item.charges) times"
        let apart = switch item.cadence {
        case .weekly: "about a week apart"
        case .monthly: "about a month apart"
        case .quarterly: "about 3 months apart"
        case .yearly: "about a year apart"
        }
        return "Charged \(times), \(apart) · next around \(item.nextExpected.formatted(.dateTime.month(.abbreviated).day()))"
    }

    static func cadence(_ cadence: Subscription.Cadence) -> String {
        switch cadence {
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .quarterly: "Every 3 months"
        case .yearly: "Yearly"
        }
    }

    // MARK: Answers

    private func answer(_ merchant: String, _ answer: ReviewRecurring.Answer) {
        send(merchant, .reviewRecurring(ReviewRecurring(merchant: merchant, answer: answer)))
    }

    /// Yes: on the list at the cadence and size Budget found.
    private func confirm(_ item: Subscription) {
        send(item.merchant, .setRecurring(SetRecurring(merchant: item.merchant, isRecurring: true, cadence: item.cadence,
                                                       amount: DecimalAmount(item.amount))))
    }

    private func dismiss(_ item: Subscription) {
        send(item.merchant, .setRecurring(SetRecurring(merchant: item.merchant, isRecurring: false)))
    }

    private func putBack(_ merchant: String) {
        send(merchant, .reviewRecurring(ReviewRecurring(merchant: merchant, answer: nil, restores: true, mark: nil)))
    }

    private func send(_ merchant: String, _ action: AppAction) {
        withAnimation(DSMotion.standard) { _ = answered.insert(merchant) }
        Task {
            if !(await RowEdits(app: app, toast: $toast).run(action)) {
                withAnimation(DSMotion.standard) { _ = answered.remove(merchant) }
            }
        }
    }
}
