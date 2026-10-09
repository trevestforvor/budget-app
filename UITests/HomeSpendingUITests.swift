import XCTest

/// Home, Spending (the budget month), a category's detail, Recurring, Plan's cash flow, the tab bar and the
/// Ask hand-off, on the demo ledger. Screenshots go to $SCREENSHOT_DIR when set (TEST_RUNNER_SCREENSHOT_DIR).
@MainActor
final class HomeSpendingUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + arguments
        app.launch()
        return app
    }

    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Swipes until `element` is on screen.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> XCUIElement {
        for _ in 0..<swipes where !(element.exists && element.isHittable) { app.swipeUp() }
        return element
    }

    private func label(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func labelContaining(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    /// Four places in the bar, and Ask set apart at its end — still called "Ask" for VoiceOver and tests.
    func testTabBarHasFourPlacesAndAsk() {
        let app = launch()
        for name in ["Home", "Spending", "Activity", "Plan", "Ask"] {
            XCTAssertTrue(app.tabBars.buttons[name].waitForExistence(timeout: 10), "\(name) should be in the tab bar")
        }
        app.tabBars.buttons["Ask"].tap()
        XCTAssertTrue(labelContaining("Ask about", in: app).waitForExistence(timeout: 10))
        snapshot("tabs-ask")
        app.tabBars.buttons["Plan"].tap()
        XCTAssertTrue(app.staticTexts["Plan"].waitForExistence(timeout: 10))
    }

    /// "Ask about this" starts its own conversation every time — never continuing the last one.
    func testAskAboutThisStartsFresh() {
        let app = launch()
        let month = app.buttons["Ask about this month"]
        XCTAssertTrue(month.waitForExistence(timeout: 10))
        month.tap()
        let first = app.staticTexts["Am I on track with safe to spend this month?"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), "the question arrives in Ask")
        XCTAssertTrue(app.staticTexts["Answer"].waitForExistence(timeout: 15))

        app.tabBars.buttons["Home"].tap()
        let week = reveal(app.buttons["Ask about the last 7 days"], in: app)
        XCTAssertTrue(week.exists)
        week.tap()
        XCTAssertTrue(app.staticTexts["Where did my everyday spending go in the last 7 days?"].waitForExistence(timeout: 10))
        XCTAssertFalse(first.exists, "a new question from another card starts a fresh conversation")
        snapshot("ask-handoff")
    }

    /// Home: what needs you (the attention pill leads to Accounts), the week day by day, balances.
    func testHomeCards() {
        let app = launch()
        let pill = app.buttons["attentionPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertTrue(pill.label.contains("Tidewater"), pill.label)
        snapshot("home-top")
        XCTAssertTrue(reveal(app.staticTexts["Everyday · last 7 days"], in: app).exists)
        XCTAssertTrue(reveal(app.buttons["openNetWorth"], in: app).exists)
        snapshot("home-balances")

        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        reveal(pill, in: app).tap()
        XCTAssertTrue(app.staticTexts["Tidewater"].waitForExistence(timeout: 10), "Accounts lists the connection that needs a sign-in")
        snapshot("home-accounts")
    }

    /// Net worth from Home's balances: the history with its range, what you own and owe, and a hand-kept item opening to edit.
    func testNetWorth() {
        let app = launch()
        reveal(app.buttons["openNetWorth"], in: app).tap()
        XCTAssertTrue(app.otherElements["netWorthRange"].waitForExistence(timeout: 10) || app.buttons["3M"].waitForExistence(timeout: 2))
        XCTAssertTrue(reveal(app.staticTexts["What you own"], in: app).exists)
        snapshot("net-worth")
        let car = reveal(app.buttons["manualAsset-asset-car"], in: app)
        XCTAssertTrue(car.exists, "the demo's car is kept by hand and opens to edit")
        car.tap()
        XCTAssertTrue(app.buttons["removeManualAsset"].waitForExistence(timeout: 10))
        snapshot("net-worth-edit")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["addManualAsset"].waitForExistence(timeout: 10) || app.buttons["addManualAssetToolbar"].exists)
    }

    /// The weekly recap puts itself away for the week, and the checkup card takes its usual place.
    func testWeeklyRecapDismisses() {
        let app = launch()
        let hide = app.buttons["Hide this week's recap"]
        guard hide.waitForExistence(timeout: 10) else {
            // Already put away this week on this simulator: the standing card is there instead.
            XCTAssertTrue(reveal(app.buttons["runCheckup"], in: app).exists)
            return
        }
        hide.tap()
        XCTAssertTrue(reveal(app.buttons["runCheckup"], in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["openCheckup"].exists)
        app.terminate()
        let again = launch()
        XCTAssertTrue(again.staticTexts["Safe to spend"].waitForExistence(timeout: 10))
        XCTAssertFalse(again.buttons["Hide this week's recap"].exists, "it stays away for the rest of the week")
    }

    /// A category with no target joins "Everything else", and "+ Target" opens the target editor.
    func testTargetChipOpensEditor() {
        let app = launch(["-ask", "Remove the dining target"])
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        apply.tap()
        XCTAssertTrue(app.staticTexts["Applied"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Spending"].tap()
        XCTAssertTrue(app.staticTexts["Safe to spend"].waitForExistence(timeout: 10))
        let chip = reveal(app.buttons["Set a target for Dining"], in: app)
        XCTAssertTrue(chip.exists)
        chip.tap()
        XCTAssertTrue(app.buttons["Save target"].waitForExistence(timeout: 5))
        snapshot("target-editor")
    }

    /// Spending is the budget month: the gauge, how it's figured, the budget types, and earlier months.
    func testSpendingBudgetMonth() {
        let app = launch(["-tab", "spending"])
        XCTAssertTrue(app.staticTexts["Safe to spend"].waitForExistence(timeout: 10))
        snapshot("spending-month")
        XCTAssertTrue(reveal(app.staticTexts["How it's figured"], in: app).exists)
        XCTAssertTrue(reveal(app.staticTexts["Everything else"], in: app).exists)
        snapshot("spending-everyday")
        XCTAssertTrue(reveal(app.staticTexts["Coming up"], in: app).exists)
        snapshot("spending-coming-up")

        for _ in 0..<10 { app.swipeDown() }
        app.buttons["Previous month"].tap()
        XCTAssertTrue(app.staticTexts["Left over"].waitForExistence(timeout: 10), "a finished month says what was left over")
        XCTAssertFalse(app.staticTexts["Coming up"].exists, "what's due soon belongs to this month only")
        snapshot("spending-last-month")
    }

    /// The ledger's first months had no three full months before them to budget from: they show what was spent,
    /// never an invented overspend.
    func testEarlyMonthsShowNoInventedBudget() {
        let app = launch(["-tab", "spending"])
        XCTAssertTrue(app.staticTexts["Safe to spend"].waitForExistence(timeout: 10))
        let back = app.buttons["Previous month"]
        for _ in 0..<12 where back.isEnabled {
            back.tap()
            _ = app.staticTexts["Left over"].waitForExistence(timeout: 2)
        }
        XCTAssertTrue(labelContaining("Not enough history to budget", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(labelContaining("Went over by", in: app).exists, "no overspend against a budget built from empty months")
        snapshot("spending-first-month")
    }

    /// A category's detail follows the month it was opened on, and its transactions are that month's only.
    func testCategoryDetailIsMonthScoped() {
        let app = launch(["-open", "category/dining"])
        XCTAssertTrue(app.buttons["Edit target"].waitForExistence(timeout: 10))
        XCTAssertTrue(labelContaining("average", in: app).exists)
        XCTAssertTrue(app.buttons["Ask about Dining"].exists)
        snapshot("category-dining")
        let header = reveal(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Transactions in'")).firstMatch, in: app)
        XCTAssertTrue(header.exists)
        snapshot("category-dining-transactions")
    }

    /// A money-in category's detail says what it received, never what it spent, and lists its credits.
    func testMoneyInCategoryDetail() {
        let app = launch(["-open", "category/card-rewards"])
        let received = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'categoryReceived' AND value BEGINSWITH '$'")).firstMatch
        XCTAssertTrue(received.waitForExistence(timeout: 10), "the month's receipts load, not just a placeholder")
        XCTAssertTrue(received.label.hasPrefix("Received in"))
        XCTAssertFalse(labelContaining("Spent in", in: app).exists)
        XCTAssertFalse(app.buttons["Edit target"].exists, "money in has no target")
        XCTAssertTrue(labelContaining("Dining credit", in: app).waitForExistence(timeout: 10))
        snapshot("category-card-rewards")
    }

    /// Recurring: what's due in the next 30 days by week, and every charge by kind.
    func testRecurringUpcomingAndAll() {
        let app = launch(["-open", "recurring"])
        XCTAssertTrue(app.staticTexts["Due in the next 30 days"].waitForExistence(timeout: 10))
        // The "To review" card (0.5.0) sits above the list, so the list starts below the fold.
        let all = reveal(app.buttons["All"], in: app)
        XCTAssertTrue(app.staticTexts["Netflix"].waitForExistence(timeout: 5))
        snapshot("recurring-upcoming")
        all.tap()
        XCTAssertTrue(app.staticTexts["Bills"].waitForExistence(timeout: 5))
        snapshot("recurring-all")
    }

    /// Ask's navigate proposals reach Recurring, and a month route opens that budget month.
    func testNavigateToRecurringAndMonth() {
        let app = launch(["-ask", "Open my recurring charges"])
        let open = app.buttons["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.staticTexts["Due in the next 30 days"].waitForExistence(timeout: 10))
        app.terminate()

        let calendar = Calendar.current
        let last = calendar.date(byAdding: .month, value: -1, to: DemoLaunch.now)!
        let key = String(format: "%04d-%02d", calendar.component(.year, from: last), calendar.component(.month, from: last))
        let monthApp = launch(["-open", "spending/\(key)"])
        XCTAssertTrue(monthApp.staticTexts["Left over"].waitForExistence(timeout: 10))
        let name = last.formatted(.dateTime.month(.wide))
        XCTAssertTrue(monthApp.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists)
    }

    /// Plan: cash flow month by month, squared with Can save.
    func testPlanCashFlow() {
        let app = launch(["-tab", "plan"])
        let card = reveal(labelContaining("Cash flow", in: app), in: app, swipes: 4)
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.staticTexts["Average net"], in: app).exists)
        snapshot("plan-cash-flow")
    }

    /// A day in Home's week strip opens Activity with just that day, said by a chip that shows every day again.
    func testWeekStripDayOpensActivity() {
        let app = launch()
        let day = reveal(app.buttons.matching(identifier: "weekStripDay").element(boundBy: 4), in: app)
        XCTAssertTrue(day.exists)
        day.tap()
        let chip = app.buttons["dayChip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected)
        snapshot("activity-one-day")
        chip.tap()
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5))
    }
}

/// A paced walk through every screen this area owns, a screen and a half at a time, for design review.
/// Skipped unless `TEST_RUNNER_SHOTS=1`; writes to $SCREENSHOT_DIR with an optional `SHOTS_PREFIX`.
@MainActor
final class HomeSpendingScreenshotWalk: XCTestCase {
    private var prefix: String { ProcessInfo.processInfo.environment["SHOTS_PREFIX"] ?? "" }

    override func setUp() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SHOTS"] != "1", "Set TEST_RUNNER_SHOTS=1 to capture the walk.")
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(name).png"))
        }
    }

    /// Scrolls about half a screen, so consecutive shots overlap.
    private func step(_ app: XCUIApplication) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        from.press(forDuration: 0.05, thenDragTo: to)
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func walk(_ name: String, arguments: [String], steps: Int, wait: String? = nil) {
        let app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + arguments
        app.launch()
        if let wait { _ = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", wait)).firstMatch.waitForExistence(timeout: 10) }
        Thread.sleep(forTimeInterval: 1.5)
        shot("\(name)-0")
        for index in 1...max(steps, 1) {
            step(app)
            shot("\(name)-\(index)")
        }
    }

    func testWalk() {
        walk("home", arguments: [], steps: 6, wait: "Safe to spend")
        walk("spending", arguments: ["-tab", "spending"], steps: 7, wait: "Safe to spend")
        walk("august", arguments: ["-open", "spending/2026-08"], steps: 2, wait: "Left over")
        walk("category", arguments: ["-open", "category/dining"], steps: 3, wait: "average")
        walk("recurring", arguments: ["-open", "recurring"], steps: 1, wait: "Due in the next")
        walk("plan", arguments: ["-tab", "plan"], steps: 4, wait: "Projected")
    }

    /// Without a dining target, dining joins "Everything else" and offers "+ Target".
    func testWalkUntargeted() {
        let app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + ["-ask", "Remove the dining target"]
        app.launch()
        let apply = app.buttons["Apply"]
        guard apply.waitForExistence(timeout: 10) else { return }
        apply.tap()
        _ = app.staticTexts["Applied"].waitForExistence(timeout: 10)
        app.tabBars.buttons["Spending"].tap()
        _ = app.staticTexts["Safe to spend"].waitForExistence(timeout: 10)
        for index in 0..<5 {
            if index > 0 { step(app) }
            shot("untargeted-\(index)")
        }
    }
}
