import XCTest

/// Activity on the demo ledger: review groups filed in one answer (and undone), review one group at a time with
/// a scoped rule, filters with a live count, a transaction's details, and bulk edits. Screenshots go to
/// $SCREENSHOT_DIR when set (pass `TEST_RUNNER_SCREENSHOT_DIR=/path`).
@MainActor
final class ActivityUITests: XCTestCase {
    override nonisolated func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = DemoLaunch.arguments + ["-tab", "activity"] + arguments
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

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Taps the switch itself, at the trailing edge of its row.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func scroll(to element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// The Meadow withdrawals are one decision: one tap files all four, the badge counts decisions, and
    /// Undo puts them back.
    func testReviewGroupFilesAllAndUndoes() {
        let app = launch()
        XCTAssertTrue(element(app, containing: "Needs review · 8").waitForExistence(timeout: 10))
        snapshot("activity-review-card")

        let fileAll = app.buttons["File all 4 as Transfer"]
        XCTAssertTrue(fileAll.waitForExistence(timeout: 5))
        fileAll.tap()
        XCTAssertTrue(element(app, containing: "Filed 4 transactions under Transfer").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, containing: "Needs review · 7").waitForExistence(timeout: 10))
        snapshot("activity-group-filed-toast")

        app.buttons["Undo"].tap()
        XCTAssertTrue(element(app, containing: "Needs review · 8").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["File all 4 as Transfer"].waitForExistence(timeout: 5))
    }

    /// Review one group at a time: the withdrawals first (the answer that files the most), an account-scoped rule
    /// for the ones to come, then the next group.
    func testTriageFilesGroupWithRuleAndAdvances() {
        let app = launch(["-review"])
        XCTAssertTrue(element(app, containing: "1 of 8").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Withdrawal"].exists)
        let rule = app.switches["makesRule"]
        scroll(to: rule, in: app)
        XCTAssertTrue(rule.exists)
        flip(rule)
        snapshot("triage-withdrawals")

        let answer = app.buttons["answerButton"]
        XCTAssertEqual(answer.label, "Keep Transfer for all 4")
        answer.tap()
        XCTAssertTrue(element(app, containing: "New ones will be filed the same way").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, containing: "2 of 8").waitForExistence(timeout: 10))
        snapshot("triage-next-group")

        app.buttons["skipButton"].tap()
        XCTAssertTrue(element(app, containing: "3 of 8").waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        XCTAssertTrue(element(app, containing: "Needs review · 7").waitForExistence(timeout: 10))
    }

    /// Filters count what they'll show before you apply them, and the list then says what it's showing.
    func testFiltersShowLiveCountAndSummary() {
        let app = launch()
        app.buttons["filtersButton"].tap()
        let apply = app.buttons["applyFilters"]
        XCTAssertTrue(apply.waitForExistence(timeout: 10))
        let needsReview = app.switches["Needs review"]
        XCTAssertTrue(needsReview.waitForExistence(timeout: 5))
        flip(needsReview)
        let predicate = NSPredicate(format: "label == 'Show 11 transactions'")
        expectation(for: predicate, evaluatedWith: apply)
        waitForExpectations(timeout: 10)
        snapshot("filters-sheet")
        apply.tap()

        XCTAssertTrue(element(app, containing: "Filters · 1").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, containing: "11 transactions").waitForExistence(timeout: 10))
        snapshot("activity-filtered-summary")
    }

    /// A transaction's details: leave it out of the totals (and back), and add a note search can find.
    func testDetailHidesAndNotes() {
        let app = launch(["-activity", "detail:Bluebird Coffee"])
        let counts = app.switches["countsToggle"]
        XCTAssertTrue(counts.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["The model"].exists)
        snapshot("detail-model-filed")
        flip(counts)
        XCTAssertTrue(element(app, containing: "Hidden from your totals").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, containing: "Hidden").exists)

        let note = app.buttons["noteRow"]
        scroll(to: note, in: app)
        note.tap()
        let field = app.textViews["noteField"].exists ? app.textViews["noteField"] : app.textFields["noteField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Coffee with Sam")
        app.buttons["Save"].tap()
        XCTAssertTrue(element(app, containing: "Coffee with Sam").waitForExistence(timeout: 10))
        snapshot("detail-hidden-with-note")
    }

    /// Rename a merchant everywhere it appears, then re-file the row from the category chip and undo it.
    func testRenameAllLikeItAndRecategorize() {
        let app = launch(["-activity", "detail:DoorDash"])
        let merchant = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Merchant'")).firstMatch
        XCTAssertTrue(merchant.waitForExistence(timeout: 10))
        merchant.tap()
        let name = app.textFields["merchantName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Rename all like it"].exists)
        name.tap()
        name.buttons["Clear text"].exists ? name.buttons["Clear text"].tap() : name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        name.typeText("DoorDash Delivery")
        snapshot("detail-rename-sheet")
        app.buttons["Save"].tap()
        XCTAssertTrue(element(app, containing: "to “DoorDash Delivery”").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["DoorDash Delivery"].waitForExistence(timeout: 10))

        app.buttons["categoryChip"].tap()
        let groceries = app.buttons["category-groceries"]
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        snapshot("detail-category-picker")
        groceries.tap()
        XCTAssertTrue(element(app, containing: "Filed under Groceries").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["categoryChip"].value as? String == "Groceries")
        app.buttons["Undo"].tap()
        XCTAssertTrue(element(app, containing: "Put back the way it was").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["categoryChip"].value as? String == "Dining")
    }

    /// Select several rows and hide them together; Undo counts them again.
    func testBulkSelectHidesAndUndoes() {
        let app = launch()
        app.buttons["selectButton"].tap()
        let rows = app.buttons.matching(identifier: "activityRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        rows.element(boundBy: 0).tap()
        rows.element(boundBy: 1).tap()
        XCTAssertTrue(element(app, containing: "2 selected").waitForExistence(timeout: 5))
        snapshot("activity-select")
        app.buttons["bulkHide"].tap()
        XCTAssertTrue(element(app, containing: "Hid 2 transactions from your totals").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["selectButton"].waitForExistence(timeout: 5))
        app.buttons["Undo"].tap()
        XCTAssertTrue(element(app, containing: "Put back the way it was").waitForExistence(timeout: 10))
    }
}
