import XCTest

/// Drives the real app on the demo ledger. Screenshots are written to $SCREENSHOT_DIR when set
/// (pass `TEST_RUNNER_SCREENSHOT_DIR=/path` to xcodebuild) and attached to the result bundle.
@MainActor
final class BudgetUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + arguments
        app.launch()
        return app
    }

    /// Settings is a long list and off-screen rows aren't in the accessibility tree, so swipe until
    /// the element is on screen (or give up after a few swipes and let the assertion speak).
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 10) -> XCUIElement {
        if element.waitForExistence(timeout: 2), element.isHittable { return element }
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
        _ = element.waitForExistence(timeout: timeout)
        return element
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

    /// Ask proposes, nothing changes until Apply, and the change reaches Spending.
    func testProposalAppliesAndReachesSpending() {
        let app = launch(["-ask", "Set the dining budget to $500"])
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Not applied"].exists)
        snapshot("proposal-before")

        apply.tap()
        XCTAssertTrue(app.staticTexts["Applied"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Dining target is now $500 a month."].exists)
        snapshot("proposal-after")

        app.tabBars.buttons["Spending"].tap()
        // The tiles sit below the month's gauge and plan.
        XCTAssertTrue(app.staticTexts["Safe to spend"].waitForExistence(timeout: 10))
        let tile = app.staticTexts["over $500 target"]
        for _ in 0..<4 where !tile.exists { app.swipeUp() }
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "Dining tile should reflect the new target")
        snapshot("spending-after-apply")
    }

    /// Navigation proposals open the focused screen.
    func testNavigateProposalOpensCategory() {
        let app = launch(["-ask", "Show me groceries"])
        let open = app.buttons["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.buttons["Edit target"].waitForExistence(timeout: 10))
        snapshot("navigate-groceries")
    }

    /// Turning on the decision model auto-accepts sure items; Activity shows what it decided.
    func testDecisionModelAutoAccepts() {
        let app = launch(["-ask", "Turn on the decision model at 80%"])
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        snapshot("decision-proposal")
        apply.tap()
        XCTAssertTrue(app.staticTexts["Applied"].waitForExistence(timeout: 10))
        let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Auto-accepted 3 of 11'")).firstMatch
        XCTAssertTrue(message.exists)
        snapshot("decision-applied")

        app.tabBars.buttons["Activity"].tap()
        // Eight rows are left in five decisions (the four Meadow withdrawals are one).
        let waiting = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Needs review · 5'")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 10))
        snapshot("activity-after-decisions")
        // What the model filed on its own is one quick filter away, to check or overrule.
        // The last quick filter sits past the edge of the chip row.
        app.buttons["Money out"].swipeLeft()
        app.buttons["Filed by the model"].tap()
        let taco = app.buttons.matching(identifier: "activityRow").matching(NSPredicate(format: "label BEGINSWITH 'Casa Taco'")).firstMatch
        XCTAssertTrue(taco.waitForExistence(timeout: 10))
        snapshot("activity-filed-by-model")

        app.tabBars.buttons["Home"].tap()
        app.buttons["Settings"].tap()
        reveal(app.buttons["settingsReview"], in: app).tap()
        XCTAssertTrue(app.staticTexts["Sure enough at"].waitForExistence(timeout: 10), "the threshold lives on the Review page")
        snapshot("settings-decision-on")
    }

    /// Like a phone: no demo ledger anywhere — the app opens on Connect until it reaches a server.
    func testDeviceStartsOnConnect() {
        let app = XCUIApplication()
        app.launchArguments = ["-noDemo", "-resetSettings"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Connect to your server"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Connect"].isEnabled, "nothing to connect to yet")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "no tabs, so no demo money, before a server")
        snapshot("connect")
    }

    /// Spending → Coming up → Recurring: found from repeat charges, what's due soon, subscriptions apart from bills.
    func testSubscriptionsList() {
        let app = launch(["-tab", "spending"])
        let link = app.buttons["subscriptions"]
        for _ in 0..<8 where !(link.exists && link.isHittable) { app.swipeUp() }
        XCTAssertTrue(link.exists)
        link.tap()
        XCTAssertTrue(app.staticTexts["Netflix"].waitForExistence(timeout: 10))
        app.buttons["All"].tap()
        XCTAssertTrue(app.staticTexts["Bills"].waitForExistence(timeout: 5))
        snapshot("subscriptions")
    }

    /// Home → Checkup: one tap runs everything, and a finding's question goes to Ask.
    func testCheckupRunsEverything() {
        let app = launch()
        // Once a week the checkup leads Home as a recap; otherwise it has its own card.
        let recap = app.buttons["openCheckup"]
        let card = app.buttons["runCheckup"]
        XCTAssertTrue(recap.waitForExistence(timeout: 10) || card.waitForExistence(timeout: 5))
        if recap.exists { recap.tap() } else { reveal(card, in: app).tap() }
        XCTAssertTrue(app.staticTexts["Categories"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'to act on'")).firstMatch.exists)
        snapshot("checkup")
        let ask = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Why is dining over'")).firstMatch
        for _ in 0..<6 where !(ask.exists && ask.isHittable) { app.swipeUp() }
        XCTAssertTrue(ask.exists)
        ask.tap()
        XCTAssertTrue(app.buttons["Apply"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'dining'")).firstMatch.waitForExistence(timeout: 15))
    }

    /// Checkup findings open what they're about: a category over its target pushes that category (back returns to the
    /// checkup), the review finding opens the review queue, and a merchant in the month's list opens its charges.
    func testCheckupFindingsOpenTheirScreens() {
        let app = launch(["-checkup"])
        XCTAssertTrue(app.staticTexts["Categories"].waitForExistence(timeout: 10))
        let dining = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Act on: Dining is over'")).firstMatch
        XCTAssertTrue(reveal(dining, in: app).exists)
        dining.tap()
        XCTAssertTrue(app.staticTexts["Month by month"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Categories"].waitForExistence(timeout: 5))

        let review = app.buttons["checkupFinding-review"]
        XCTAssertTrue(reveal(review, in: app).exists)
        review.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        snapshot("checkup-review")
        app.buttons["Done"].tap()

        let merchant = app.buttons.matching(identifier: "checkupFigure-merchant").firstMatch
        XCTAssertTrue(reveal(merchant, in: app).exists)
        let name = merchant.label.components(separatedBy: ",").first ?? merchant.label
        merchant.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected)
        XCTAssertEqual(search.value as? String, name)
    }

    /// Escalation to Jev from Settings' decision section flows through the same action path.
    func testEscalationFromAsk() {
        let app = launch(["-ask", "Turn on the decision model at 80% and escalate to Jev"])
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        apply.tap()
        let message = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '(2 by Jev)'")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        snapshot("decision-escalated")
        app.tabBars.buttons["Home"].tap()
        app.buttons["Settings"].tap()
        reveal(app.buttons["settingsAdvanced"], in: app).tap()
        XCTAssertTrue(reveal(app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Ask Jev when unsure'")).firstMatch, in: app).exists)
        let sample = app.buttons["What the model sees"]
        if sample.exists { sample.tap() }
        snapshot("settings-decision-escalation")
    }

    /// Home leads with flex budgeting: safe to spend after savings come off the top.
    func testHomeShowsSafeToSpend() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Safe to spend"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Saved first"].exists)
        snapshot("home")
    }

    /// "Cap DoorDash at $150" → Apply → the cap shows under Spending.
    func testMerchantCapReachesSpending() {
        let app = launch(["-ask", "Cap DoorDash at $150"])
        let apply = app.buttons["Apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        snapshot("merchant-cap-proposal")
        apply.tap()
        XCTAssertTrue(app.staticTexts["Applied"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Spending"].tap()
        let caps = app.staticTexts["Merchant caps"]
        for _ in 0..<5 where !caps.isHittable { app.swipeUp() }
        XCTAssertTrue(caps.exists)
        snapshot("spending-merchant-caps")
    }

    /// Plan answers "how much can I save / should I save".
    func testPlanShowsSavings() {
        let app = launch(["-tab", "plan"])
        let card = app.staticTexts["Can save / mo"]
        for _ in 0..<6 where !card.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(card.exists)
        snapshot("plan-savings")
    }

    /// Live: the real agent loop against a self-hosted Qwen. Run with TEST_RUNNER_LIVE=1 and TEST_RUNNER_LIVE_MODEL=<its URL>.
    func testLiveAskAgainstQwen() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["LIVE"] == "1", "set TEST_RUNNER_LIVE=1 to run against a live model")
        let model = try XCTUnwrap(environment["LIVE_MODEL"], "set TEST_RUNNER_LIVE_MODEL to the model server's URL")
        let app = launch(["-live", "-liveModel", model, "-ask", "What is my DoorDash budget?"])
        XCTAssertTrue(app.staticTexts["Computed by the ledger"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.staticTexts["qwen3.8-27b"].exists)
        snapshot("live-ask-doordash")
    }
}
