import Foundation
import Testing
@testable import BudgetKit

/// The recurring review: "Is this recurring?" for a series that's only begun, "Did this stop?" for one gone quiet.
@Suite("Recurring review")
struct RecurringReviewTests {
    /// Now is 25 Sep 2026.
    static func rows() -> [LedgerTransaction] {
        [
            // Two monthly charges of the same size: too few for the list, so a question.
            Rows.row("yoga-1", "card", 41, -12.99, "POCKET YOGA", "subscriptions"),
            Rows.row("yoga-2", "card", 11, -12.99, "POCKET YOGA", "subscriptions"),
            // Two dinners a month apart at different prices: everyday, not a question.
            Rows.row("dinner-1", "card", 40, -64.10, "HARVEST TABLE", "dining"),
            Rows.row("dinner-2", "card", 10, -88.40, "HARVEST TABLE", "dining"),
            // A pair that's already overdue: no longer current, not a question.
            Rows.row("old-1", "card", 120, -30, "OLD CLUB", "subscriptions"),
            Rows.row("old-2", "card", 90, -30, "OLD CLUB", "subscriptions"),
            // On the list: monthly, last charged 48 days ago — a "Did this stop?".
            Rows.row("stream-1", "card", 140, -9.99, "STREAMBOX", "subscriptions"),
            Rows.row("stream-2", "card", 109, -9.99, "STREAMBOX", "subscriptions"),
            Rows.row("stream-3", "card", 79, -9.99, "STREAMBOX", "subscriptions"),
            Rows.row("stream-4", "card", 48, -9.99, "STREAMBOX", "subscriptions"),
            // On the list and current.
            Rows.row("spotify-1", "card", 72, -12, "SPOTIFY USA", "subscriptions"),
            Rows.row("spotify-2", "card", 41, -12, "SPOTIFY USA", "subscriptions"),
            Rows.row("spotify-3", "card", 10, -12, "SPOTIFY USA", "subscriptions"),
        ]
    }

    static func stopped(_ answer: ReviewRecurring.Answer) -> AppAction {
        .reviewRecurring(ReviewRecurring(merchant: "Streambox", answer: answer))
    }

    @Test("A series that's only begun is asked about; dinners, overdue pairs and listed series aren't")
    func candidates() {
        let review = Rows.ledger(Self.rows()).recurringReview()
        #expect(review.candidates.map(\.merchant) == ["Pocket Yoga"])
        let yoga = review.candidates[0]
        #expect(yoga.cadence == .monthly && yoga.kind == .subscription && yoga.amount == Money(12.99) && yoga.charges == 2)
        #expect(review.maybeStopped.map(\.merchant) == ["Streambox"])
        #expect(review.count == 2)
        #expect(review.ended == [])
    }

    @Test("Yes puts it on the list at its cadence; no takes it off for good; either way the question goes")
    func answerCandidate() throws {
        var ledger = Rows.ledger(Self.rows())
        var no = ledger
        try ledger.perform(.setRecurring(SetRecurring(merchant: "Pocket Yoga", isRecurring: true, cadence: .monthly, amount: DecimalAmount(string: "12.99"))))
        #expect(ledger.recurringReview().candidates.isEmpty)
        #expect(ledger.subscriptions().items.contains { $0.merchant == "Pocket Yoga" && $0.setByPerson == true })

        try no.perform(.setRecurring(SetRecurring(merchant: "Pocket Yoga", isRecurring: false)))
        #expect(no.recurringReview().candidates.isEmpty)
        #expect(no.subscriptions().notRecurring == ["Pocket Yoga"])
    }

    @Test("\"Yes, I canceled it\" takes it off the list and out of the usual month at once; its charges keep their bucket")
    func stoppedEndsTheSeries() throws {
        var ledger = Rows.ledger(Self.rows())
        let before = ledger.subscriptions()
        let usualBefore = ledger.capacity().subscriptions
        let preview = try ledger.preview(Self.stopped(.stopped))
        #expect(preview.title == "Streambox stopped")
        #expect(preview.effects.map(\.id) == ["usual-before", "usual-after", "everyday-after"])

        let result = try ledger.perform(Self.stopped(.stopped))
        let after = ledger.subscriptions()
        #expect(before.items.contains { $0.merchant == "Streambox" && $0.status == .missed })
        #expect(!after.items.contains { $0.merchant == "Streambox" })
        // Missed already, it wasn't in the list's month of subscriptions.
        #expect(before.subscriptionsMonthly == after.subscriptionsMonthly)
        // June, July and August each held one of its charges: the usual month drops by all of it now, not as it ages out.
        #expect(usualBefore - ledger.capacity().subscriptions == Money(9.99))
        #expect(preview.effects[1].value == ledger.capacity().subscriptions)
        // Its charges still count as subscriptions in their own months.
        #expect(ledger.bucket(of: try #require(ledger.row("stream-4"))) == .subscriptions)
        #expect(try ledger.budgetMonth("2026-08").groups.first { $0.group == .subscriptions }?.spent == Money(9.99 + 12 + 12.99))
        let review = ledger.recurringReview()
        #expect(review.maybeStopped.isEmpty && review.ended == ["Streambox"])

        // Undo puts it back as it was.
        try ledger.perform(try #require(result.undo))
        #expect(ledger.subscriptions().items.contains { $0.merchant == "Streambox" })
        #expect(ledger.capacity().subscriptions == usualBefore)
        #expect(ledger.recurringReview().maybeStopped.map(\.merchant) == ["Streambox"])
    }

    @Test("The answer counts from when it was given: past months, and a recap of them, stay as they were")
    func stoppedIsntRetroactive() throws {
        var ledger = Rows.ledger(Self.rows())
        let august = try ledger.budgetMonth("2026-08")
        let recap = try ledger.monthlyRecap("2026-08")
        let usualBefore = ledger.capacity().subscriptions
        try ledger.perform(Self.stopped(.stopped))
        // August's budget was worked out at its own end, before the answer: Streambox was still in its usual month.
        #expect(try ledger.budgetMonth("2026-08").groups.map(\.planned) == august.groups.map(\.planned))
        #expect(try ledger.monthlyRecap("2026-08").buckets == recap.buckets)
        // This month's usual month drops it at once.
        #expect(usualBefore - ledger.capacity().subscriptions == Money(9.99))
        // Seen from before the answer, the series is still on the list.
        var then = ledger
        then.now = EngineFixture.now.addingTimeInterval(-86_400)
        #expect(then.subscriptions().items.contains { $0.merchant == "Streambox" })
    }

    @Test("A charge after the answer brings an ended series back")
    func chargesAgain() throws {
        var ledger = Rows.ledger(Self.rows())
        try ledger.perform(Self.stopped(.stopped))
        ledger.now = EngineFixture.now.addingTimeInterval(3 * 86_400)
        ledger.transactions.insert(Rows.row("stream-5", "card", -2, -9.99, "STREAMBOX", "subscriptions"), at: 0)
        #expect(ledger.subscriptions().items.contains { $0.merchant == "Streambox" && $0.status == .active })
        #expect(ledger.recurringReview().ended == [])
    }

    @Test("\"No, still active\" asks again a cycle later; the silent drop still comes about three charges in")
    func stillActiveSnoozes() throws {
        var ledger = Rows.ledger(Self.rows())
        let result = try ledger.perform(Self.stopped(.stillActive))
        #expect(result.message.hasPrefix("Kept Streambox."))
        #expect(ledger.recurringReview().maybeStopped.isEmpty)
        #expect(ledger.subscriptions().items.contains { $0.merchant == "Streambox" })
        let mark = try #require(ledger.recurringReviews["streambox"])
        #expect(mark.snoozedUntil == EngineFixture.now.addingTimeInterval(30.4 * 86_400) && mark.endedAt == nil)

        ledger.now = EngineFixture.now.addingTimeInterval(31 * 86_400)
        #expect(ledger.recurringReview().maybeStopped.map(\.merchant) == ["Streambox"])
        // 92 days past its last charge it leaves the list on its own.
        ledger.now = EngineFixture.now.addingTimeInterval(45 * 86_400)
        #expect(!ledger.subscriptions().items.contains { $0.merchant == "Streambox" })
        #expect(!ledger.recurringReview().maybeStopped.contains { $0.merchant == "Streambox" })
    }

    @Test("Only a series on the list can be answered; one that's ended can't be ended twice")
    func validation() throws {
        var ledger = Rows.ledger(Self.rows())
        #expect(throws: BudgetAPIError.rejected("Pocket Yoga isn't on your recurring list.")) {
            try ledger.preview(.reviewRecurring(ReviewRecurring(merchant: "Pocket Yoga", answer: .stopped)))
        }
        #expect(throws: BudgetAPIError.rejected("Say whether Spotify Usa stopped.")) {
            try ledger.preview(.reviewRecurring(ReviewRecurring(merchant: "Spotify Usa", answer: nil)))
        }
        try ledger.perform(Self.stopped(.stopped))
        #expect(throws: BudgetAPIError.self) { try ledger.perform(Self.stopped(.stopped)) }
        // Putting it back is an undo with no mark.
        try ledger.perform(.reviewRecurring(ReviewRecurring(merchant: "Streambox", answer: nil, restores: true, mark: nil)))
        #expect(ledger.recurringReviews.isEmpty)
    }

    @Test("Answers persist with the ledger, and a ledger saved before them still loads")
    func persistence() throws {
        var ledger = Rows.ledger(Self.rows())
        try ledger.perform(Self.stopped(.stopped))
        let data = try JSONEncoder().encode(ledger.state)
        let decoded = try JSONDecoder().decode(LedgerState.self, from: data)
        #expect(decoded.recurringReviews == ledger.recurringReviews)
        let reloaded = Ledger(state: decoded, now: EngineFixture.now, calendar: Fixture.calendar)
        #expect(!reloaded.subscriptions().items.contains { $0.merchant == "Streambox" })

        guard case var .object(fields) = try JSONValue.parse(data) else { Issue.record("not an object"); return }
        fields["recurringReviews"] = nil
        let old = try JSONDecoder().decode(LedgerState.self, from: JSONValue.object(fields).data())
        #expect(old.recurringReviews.isEmpty)
    }

    @Test("The action round-trips on the wire, and the assistant can't call it")
    func wire() throws {
        let action = AppAction.reviewRecurring(ReviewRecurring(merchant: "StreamBox", answer: nil, restores: true,
                                                               mark: RecurringReviewMark(merchant: "StreamBox", endedAt: EngineFixture.now)))
        #expect(try JSONDecoder().decode(AppAction.self, from: JSONEncoder().encode(action)) == action)
        #expect(action.toolName == "reviewRecurring")
        #expect(!ToolCatalog.specs.contains { $0.name == "reviewRecurring" })
        #expect(throws: ToolArgumentError.self) { try AppAction(toolName: "reviewRecurring", arguments: try action.argumentsJSON()) }
    }

    @Test("The demo asks about Pocket Yoga and StreamBox")
    func demo() async throws {
        let review = try await Fixture.api().recurringReview()
        #expect(review.candidates.map(\.merchant) == ["Pocket Yoga"])
        #expect(review.maybeStopped.map(\.merchant) == ["StreamBox"])
        #expect(review.maybeStopped[0].status == .missed)
    }

    @Test("Ask: what might have stopped is one recurringReview call, grounded in its figures")
    func ask() async throws {
        let reply = try await Fixture.api().ask("Did any of my subscriptions stop?", conversationID: nil)
        #expect(reply.toolCalls.map(\.name) == ["recurringReview"])
        #expect(reply.text.contains("StreamBox") && reply.text.contains("Pocket Yoga"))
        #expect(throws: Never.self) { try ToolCatalog.validateArguments(tool: "recurringReview", json: Data(reply.toolCalls[0].arguments.utf8)) }
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty, "\(reply.text)")
    }
}
