import Foundation

// The recurring review queue (docs/BUDGETING.md, "Recurring review"). The recurring search stays strict — three monthly
// charges, four weekly — so nothing lands on the list by chance. Below that bar Budget asks instead: "Is this
// recurring?" for a series that's only begun, and "Did this stop?" for one that's gone quiet, well before the silent
// drop about three missed charges in (`Subscription.Cadence.staleAfter`).

extension Subscription.Cadence {
    /// How long after its last charge a series on the list prompts "Did this stop?": about a cycle and a half — half a
    /// cycle past the charge that didn't come. A yearly one asks about 45 days late, well before it drops off.
    var askStoppedAfter: Double { switch self { case .weekly: 11; case .monthly: 46; case .quarterly: 137; case .yearly: 410 } }
}

extension Ledger {
    /// Questions waiting for the person on the recurring list.
    func recurringReview() -> RecurringReview {
        let series = recurringSeries()
        let listed = Set(series.map { RecurringChoice.key($0.merchant) })
        let ended = series.filter { isEnded($0) && now.timeIntervalSince($0.billings.last!.date) <= $0.cadence.staleAfter * 86_400 }
        return RecurringReview(asOf: now, candidates: recurringCandidates(excluding: listed), maybeStopped: maybeStopped(),
                               ended: ended.map(\.merchant).sorted())
    }

    /// Whether the person said this series stopped and it hasn't charged since.
    func isEnded(_ series: RecurringSeries) -> Bool {
        guard let endedAt = recurringReviews[RecurringChoice.key(series.merchant)]?.endedAt, let last = series.billings.last else { return false }
        return last.date <= endedAt
    }

    /// "Did this stop?": active series on the list whose last charge is past `askStoppedAfter`, unless the person said
    /// it's still active and that answer hasn't run its cycle. Longest overdue first.
    func maybeStopped() -> [Subscription] {
        subscriptions().items.filter { item in
            guard now.timeIntervalSince(item.lastCharged) > item.cadence.askStoppedAfter * 86_400 else { return false }
            if let until = recurringReviews[RecurringChoice.key(item.merchant)]?.snoozedUntil, now < until { return false }
            return true
        }
        .sorted { ($0.lastCharged, $0.merchant) < ($1.lastCharged, $1.merchant) }
    }

    /// "Is this recurring?": a merchant's charges that look like a series that's only begun — fewer than the recurring
    /// search needs (two monthly, three weekly; a yearly or quarterly pair it already takes) — or one a little less
    /// regular than it allows. Each must still be steady (every charge within a fifth of the typical one; from an
    /// everyday category, within 2%, so two dinners a month apart aren't a subscription), and current: its next charge
    /// isn't overdue. Merchants already on the list, and any the person had a say on, aren't asked about.
    func recurringCandidates(excluding listed: Set<String>) -> [Subscription] {
        var found: [Subscription] = []
        for (merchant, billings) in merchantBillings() where billings.count >= 2 {
            let key = RecurringChoice.key(merchant)
            guard !listed.contains(key), recurringChoices[key] == nil else { continue }
            let gaps = Self.gaps(billings)
            guard let cadence = Self.cadence(medianGap: gaps.sorted()[gaps.count / 2]) else { continue }
            let regular = gaps.filter { abs($0 - cadence.days) <= max(cadence.days * 0.2, 4) }.count
            guard Double(regular) >= Double(gaps.count) * 0.5 else { continue }
            let amounts = billings.map(\.amount.minorUnits)
            let typical = amounts.sorted()[amounts.count / 2]
            let group = billings.last!.rows[0].categorization.flatMap { category($0.categoryID) }?.group
            let share = group == .everyday ? 0.02 : 0.2
            guard typical >= 100, amounts.allSatisfy({ Double(abs($0 - typical)) <= Double(typical) * share }) else { continue }
            let series = RecurringSeries(merchant: merchant, cadence: cadence, billings: billings)
            let item = subscription(series, kind: group == .bills ? .bill : .subscription)
            guard item.status == .active, now.timeIntervalSince(item.nextExpected) <= cadence.grace * 86_400 else { continue }
            found.append(item)
        }
        return found.sorted { ($1.monthlyCost.minorUnits, $0.merchant) < ($0.monthlyCost.minorUnits, $1.merchant) }
    }

    // MARK: Answers

    /// What "Did this stop?" changes, worked out once for its preview and for the change itself.
    struct RecurringReviewPlan {
        var key: String
        var merchant: String
        var previous: RecurringReviewMark?
        var next: RecurringReviewMark?
        /// The series as the list shows it now; nil for an undo whose series has gone.
        var item: Subscription?
    }

    func recurringReviewPlan(_ p: ReviewRecurring) throws -> RecurringReviewPlan {
        let key = RecurringChoice.key(p.merchant)
        guard !key.isEmpty else { throw BudgetAPIError.rejected("Choose a merchant.") }
        let previous = recurringReviews[key]
        let series = recurringSeries().first { RecurringChoice.key($0.merchant) == key }
        // An undo puts the mark back exactly, even for a series that has since gone.
        if p.restores == true {
            let item = series.map { subscription($0, kind: recurringKind($0)) }
            return RecurringReviewPlan(key: key, merchant: series?.merchant ?? p.mark?.merchant ?? p.merchant, previous: previous, next: p.mark, item: item)
        }
        guard let answer = p.answer else { throw BudgetAPIError.rejected("Say whether \(p.merchant) stopped.") }
        guard let series, !isEnded(series), now.timeIntervalSince(series.billings.last!.date) <= series.cadence.staleAfter * 86_400 else {
            throw BudgetAPIError.rejected("\(p.merchant.trimmingCharacters(in: .whitespaces)) isn't on your recurring list.")
        }
        let item = subscription(series, kind: recurringKind(series))
        var next = RecurringReviewMark(merchant: series.merchant)
        switch answer {
        case .stopped: next.endedAt = now
        case .stillActive: next.snoozedUntil = now.addingTimeInterval(series.cadence.days * 86_400)
        }
        return RecurringReviewPlan(key: key, merchant: series.merchant, previous: previous, next: next, item: item)
    }

    func reviewRecurringPreview(_ p: ReviewRecurring) throws -> ActionPreview {
        let plan = try recurringReviewPlan(p)
        if p.restores == true {
            return ActionPreview(title: plan.next?.endedAt == nil ? "Put \(plan.merchant) back on recurring" : "Mark \(plan.merchant) as stopped",
                                 detail: nil, effects: [])
        }
        let item = plan.item!
        let kind = item.kind == .bill ? "bills" : "subscriptions"
        if plan.next?.endedAt != nil {
            // The usual month the budget plans for, before and after.
            var after = self
            after.recurringReviews[plan.key] = plan.next
            let (flex, next) = (flexBudget(), after.flexBudget())
            let usual = item.kind == .bill ? (flex.bills, next.bills) : (flex.subscriptions, next.subscriptions)
            return ActionPreview(
                title: "\(plan.merchant) stopped",
                detail: "It comes off your \(kind) now and out of the usual month the budget plans for. Its past charges keep their category. If it charges again, it comes back.",
                effects: [Figure(id: "usual-before", label: "Usual month of \(kind)", detail: "now", value: usual.0),
                          Figure(id: "usual-after", label: "Usual month of \(kind)", detail: "after", value: usual.1),
                          Figure(id: "everyday-after", label: "Everyday budget", detail: "after", value: next.flexNumber)])
        }
        let again = plan.next!.snoozedUntil!.formatted(Self.dayStyle(calendar))
        return ActionPreview(title: "\(plan.merchant) is still active",
                             detail: "It stays on your \(kind). Budget asks again if no charge comes by \(again).", effects: [])
    }

    mutating func performReviewRecurring(_ p: ReviewRecurring) throws -> ActionResult {
        let plan = try recurringReviewPlan(p)
        let undo = AppAction.reviewRecurring(ReviewRecurring(merchant: plan.merchant, answer: nil, restores: true, mark: plan.previous))
        recurringReviews[plan.key] = plan.next
        if p.restores == true {
            return ActionResult(message: plan.next?.endedAt == nil ? "\(plan.merchant) is back on recurring." : "Marked \(plan.merchant) as stopped.",
                                undo: undo)
        }
        if plan.next?.endedAt != nil {
            return ActionResult(message: "Took \(plan.merchant) off recurring. It comes back if it charges again.", undo: undo)
        }
        let again = plan.next!.snoozedUntil!.formatted(Self.dayStyle(calendar))
        return ActionResult(message: "Kept \(plan.merchant). Budget asks again if no charge comes by \(again).", undo: undo)
    }

    /// "Oct 30" in the ledger's time zone.
    static func dayStyle(_ calendar: Calendar) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        return style
    }
}
