import XCTest

/// Integration screenshots of the 0.5.0 screens on the demo ledger, written to $SCREENSHOT_DIR
/// (TEST_RUNNER_SCREENSHOT_DIR). Each walks to its screen and checks it showed up.
@MainActor
final class FeatureTourUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = true
    }

    private func launch(_ arguments: [String] = [], date: String = DemoLaunch.date) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoDate", date] + arguments
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

    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 10) -> XCUIElement {
        for _ in 0..<swipes where !(element.exists && element.isHittable) { app.swipeUp() }
        return element
    }

    private func any(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func labelContaining(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    func testHomeUpcoming() {
        let app = launch()
        XCTAssertTrue(any("nextPaycheck", in: app).waitForExistence(timeout: 15))
        snapshot("01-home-next-paycheck")
        reveal(labelContaining("Coming up next", in: app), in: app)
        snapshot("02-home-weekly-recap-coming-up")
    }

    func testMonthlyRecap() {
        let app = launch(date: "2026-10-03")
        let card = reveal(any("openMonthlyRecap", in: app), in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        snapshot("03-home-monthly-recap-card")
        card.tap()
        XCTAssertTrue(any("monthlyRecap", in: app).waitForExistence(timeout: 10))
        snapshot("04-monthly-recap-sheet")
        app.swipeUp()
        snapshot("04b-monthly-recap-sheet-lower")
    }

    func testRecurringReviewAndCalendar() {
        var app = launch(["-open", "recurring"])
        XCTAssertTrue(any("recurringLayout", in: app).waitForExistence(timeout: 15))
        snapshot("05-recurring-review")
        app.terminate()
        app = launch(["-open", "recurring", "-recurringCalendar"])
        XCTAssertTrue(any("upcomingCalendar", in: app).waitForExistence(timeout: 15))
        snapshot("06-recurring-calendar")
        reveal(any("cardBills", in: app), in: app)
        snapshot("07-recurring-calendar-lower-card-bills")
    }

    func testSpendingComingUpAndFlow() {
        // Flow through the argument domain, so the choice isn't left on the phone for other tests.
        let app = launch(["-tab", "spending", "-spending.breakdown", "flow"])
        XCTAssertTrue(any("spendingFlow", in: app).waitForExistence(timeout: 15))
        reveal(any("spendingFlow", in: app), in: app, swipes: 3)
        sleep(2)
        snapshot("08-spending-flow")
        reveal(any("subscriptions", in: app), in: app)
        snapshot("09-spending-coming-up")
        // An earlier run may have left Flow saved: put the default back.
        app.terminate()
        let reset = launch(["-tab", "spending"])
        let categories = reset.buttons["Top categories"]
        if categories.waitForExistence(timeout: 10) { categories.tap() }
    }

    func testMerchantPage() {
        let app = launch(["-tab", "activity", "-activity", "detail:DoorDash"])
        let link = reveal(any("merchantLink", in: app), in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.tap()
        XCTAssertTrue(any("merchantName", in: app).waitForExistence(timeout: 10))
        sleep(2)
        snapshot("10-merchant-page")
        let category = reveal(any("merchantCategory", in: app), in: app)
        snapshot("11-merchant-page-lower")
        category.tap()
        let groceries = app.buttons["category-groceries"]
        if groceries.waitForExistence(timeout: 5) { groceries.tap() }
        XCTAssertTrue(app.buttons["fileSimilarButton"].waitForExistence(timeout: 10), "B1 apply-to-similar offered from the merchant page")
        snapshot("12-merchant-apply-to-similar")
    }

    func testTagsAndExport() {
        let app = launch(["-tab", "activity"])
        let export = any("exportCSV", in: app)
        XCTAssertTrue(export.waitForExistence(timeout: 15))
        export.tap()
        sleep(3)
        snapshot("13-export-share-sheet")
        app.terminate()

        let again = launch(["-tab", "activity"])
        let search = again.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("Austin")
        let row = any("activityRow", in: again)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        snapshot("14-activity-search-by-tag")
        row.tap()
        let tags = reveal(any("tagsRow", in: again), in: again)
        XCTAssertTrue(tags.waitForExistence(timeout: 10))
        snapshot("15-transaction-tags")
        let chip = again.buttons["Austin trip"]
        if chip.waitForExistence(timeout: 5) {
            chip.tap()
            sleep(2)
            snapshot("16-tag-detail")
        }
    }

    func testNetWorthAndManualAsset() {
        let app = launch(["-networth"])
        XCTAssertTrue(any("netWorthHero", in: app).waitForExistence(timeout: 15))
        sleep(1)
        snapshot("17-net-worth")
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "manualAsset-")).firstMatch
        reveal(item, in: app)
        snapshot("18-net-worth-lower")
        if item.exists {
            item.tap()
            XCTAssertTrue(any("manualAssetName", in: app).waitForExistence(timeout: 10))
            snapshot("19-manual-asset-sheet")
        }
    }

    func testPlanScenarios() {
        var app = launch(["-tab", "plan", "-plan.scenario", ""])
        let card = reveal(any("scenarioCard", in: app), in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        snapshot("20-plan-scenarios")
        reveal(any("nextThirtyDays", in: app), in: app)
        snapshot("21-plan-next-30-days")
        app.terminate()
        // The picked scenario is remembered on the phone (`plan.scenario`); the argument domain picks the demo's car.
        app = launch(["-tab", "plan", "-plan.scenario", "scn-car"])
        let add = reveal(any("addPlanEvent", in: app), in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 15), "a picked scenario offers Add a change")
        snapshot("21b-plan-scenario-selected")
        add.tap()
        let moneyIn = app.buttons["Money in"]
        if moneyIn.waitForExistence(timeout: 5) { moneyIn.tap() }
        sleep(1)
        snapshot("22-plan-event-income")
    }

    func testAssistantMemoryAndRecents() {
        var app = launch(["-open", "assistantMemory"])
        sleep(3)
        snapshot("23-assistant-memories")
        app.terminate()
        app = launch(["-tab", "ask"])
        sleep(3)
        reveal(any("askConversations", in: app), in: app, swipes: 4)
        snapshot("24-ask-recents")
        app.terminate()
        app = launch(["-open", "conversations"])
        sleep(3)
        snapshot("25-conversations")
    }

    func testNotificationSettings() {
        let app = launch(["-settings", "-pushToken", String(repeating: "ab", count: 32)])
        let pace = reveal(any("settingsPaceAlerts", in: app), in: app)
        XCTAssertTrue(pace.waitForExistence(timeout: 15))
        snapshot("26-settings-notifications")
        pace.tap()
        sleep(2)
        snapshot("27-pace-alerts")
        app.swipeUp()
        snapshot("27b-pace-alerts-lower")
    }
}
